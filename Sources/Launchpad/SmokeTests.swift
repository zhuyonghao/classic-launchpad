import AppKit
import Foundation

@MainActor
func runSmokeTests() async {
    var exitCode: Int32 = EXIT_SUCCESS
    do {
        // Never mutate a real layout, even when the binary is invoked by hand.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("classic-launchpad-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("CLASSIC_LAUNCHPAD_DATA_DIR", directory.path, 1)
        defer { try? FileManager.default.removeItem(at: directory) }

        func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
            if !condition() { throw SmokeFailure(message: description) }
            print("PASS \(description)")
        }

        try runFourFingerGestureTests()

        let sample = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: sample)!.cgContext
        graphics.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        graphics.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let wallpaperURL = directory.appendingPathComponent("wallpaper.png")
        try sample.representation(using: .png, properties: [:])!.write(to: wallpaperURL)
        let wallpaper = LauncherWallpaperCache.image(for: wallpaperURL, size: NSSize(width: 128, height: 80))
        try check(wallpaper != nil, "wallpaper is prerendered and blurred")
        try check(wallpaper === LauncherWallpaperCache.image(for: wallpaperURL, size: NSSize(width: 128, height: 80)), "paging reuses cached wallpaper texture")
        try check(wallpaper?.representations.first?.pixelsWide == 128, "wallpaper texture is bounded to display size")

        let store = LauncherStore()
        let deadline = Date().addingTimeInterval(30)
        while store.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(!store.isScanning, "application discovery finishes")
        try check(store.apps.count >= 3, "real installed applications discovered (\(store.apps.count))")
        try check(Set(store.apps.map(\.id)).count == store.apps.count, "catalog paths are unique")
        try check(Set(store.apps.map(\.bundleIdentifier)).count == store.apps.count, "bundle identifiers are deduplicated")
        try check(!store.apps.contains { $0.bundleIdentifier == "com.local.ClassicLaunchpad" }, "launcher excludes itself")
        try check(store.apps[0].icon === store.apps[0].icon, "repeated rendering reuses the same cached icon")
        try check(store.apps[0].icon.representations.first?.pixelsWide == 200, "icons are predecoded Retina bitmaps")
        let appIDs = Set(store.apps.map(\.id))
        func checkLayout(_ label: String) throws {
            let ids = store.items.flatMap(\.appIDs)
            try check(Set(ids) == appIDs && ids.count == appIDs.count, label)
        }
        try checkLayout("default layout preserves every application once")
        if let safari = store.apps.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
            try check(store.search("safari").contains(safari), "English app search")
            try check(store.search("浏览器").contains(safari), "Chinese aliases")
            try check(store.search("liulanqi").contains(safari), "pinyin search")
        }
        try check(store.search("zzzz-no-such-application-987654").isEmpty, "empty search results")
        let keychainURL = URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Keychain Access.app")
        if FileManager.default.fileExists(atPath: keychainURL.path) {
            try check(store.apps.contains { $0.url == keychainURL }, "CoreServices user-facing apps are discovered")
        }
        let nestedRoot = directory.appendingPathComponent("nested-apps")
        let nestedApp = nestedRoot.appendingPathComponent("one/two/three/four/five/Nested.app")
        try FileManager.default.createDirectory(at: nestedApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let nestedInfo: [String: Any] = ["CFBundleIdentifier": "test.nested.app", "CFBundleName": "Nested", "CFBundlePackageType": "APPL", "LSBackgroundOnly": true, "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: nestedInfo, format: .xml, options: 0).write(to: nestedApp.appendingPathComponent("Contents/Info.plist"))
        try check(AppCatalogScanner.scan(roots: [nestedRoot]).apps.contains { $0.bundleIdentifier == "test.nested.app" }, "apps deeper than three directory levels are discovered")
        let betterDisplayURL = URL(fileURLWithPath: "/Applications/BetterDisplay.app")
        if FileManager.default.fileExists(atPath: betterDisplayURL.path) {
            try check(store.apps.contains { $0.url == betterDisplayURL }, "BetterDisplay is retained despite background-only flags")
        }
        let helperApp = nestedApp.appendingPathComponent("Contents/Library/LoginItems/Helper.app/Contents")
        try FileManager.default.createDirectory(at: helperApp, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.embedded.helper", "CFBundlePackageType": "APPL"], format: .xml, options: 0).write(to: helperApp.appendingPathComponent("Info.plist"))
        try check(AppCatalogScanner.scan(roots: [nestedRoot]).apps.count == 1, "embedded helper apps remain excluded")


        let defaults = store.items
        let sessionPreferences = UserDefaults(suiteName: "ClassicLaunchpad.Smoke.\(UUID().uuidString)")!
        let session = LauncherSession(preferences: sessionPreferences)
        let loose = store.items.filter { !$0.isFolder }
        try check(loose.count >= 3, "sufficient standalone applications for layout tests")
        let first = loose[0], second = loose[1], third = loose[2]
        let payload = LauncherDragPayload(itemID: first.id, folderID: nil)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let data = try JSONEncoder().encode(payload)
        pasteboard.setData(data, forType: LauncherIconInteractionView.pasteboardType)
        let decoded = try JSONDecoder().decode(LauncherDragPayload.self, from: pasteboard.data(forType: LauncherIconInteractionView.pasteboardType)!)
        try check(session.draggingID == nil, "drop regression starts without shared drag state")
        try check(LauncherDropActions.onIcon(decoded, target: second, horizontalFraction: 0.5, store: store, session: session), "native pasteboard payload creates folder without shared drag state")
        guard let folder = store.items.first(where: { $0.isFolder && $0.appIDs.contains(first.id) && $0.appIDs.contains(second.id) }) else {
            throw SmokeFailure(message: "folder creation")
        }
        try checkLayout("folder creation preserves catalog membership")
        store.renameFolder(folder.id, name: "测试文件夹")
        try check(store.items.first(where: { $0.id == folder.id })?.name == "测试文件夹", "folder rename")
        store.renameFolder(folder.id, name: "  ")
        try check(store.items.first(where: { $0.id == folder.id })?.name == "测试文件夹", "blank folder names rejected")
        store.moveApp(third.id, toFolder: folder.id)
        try check(store.items.first(where: { $0.id == folder.id })?.appIDs.count == 3, "move app into folder")
        try checkLayout("moving into a folder preserves uniqueness")
        session.folderID = folder.id
        try check(LauncherDropActions.onIcon(LauncherDragPayload(itemID: third.id, folderID: folder.id), target: first, horizontalFraction: 0.5, store: store, session: session), "native drop reorders folder members")
        let members = store.items.first(where: { $0.id == folder.id })!.appIDs
        try check(members.firstIndex(of: third.id)! + 1 == members.firstIndex(of: first.id)!, "folder member ordering matches drop")
        try check(LauncherDropActions.onIcon(LauncherDragPayload(itemID: third.id, folderID: folder.id), target: first, horizontalFraction: 0.9, store: store, session: session), "folder drop accepts placement after target")
        let reorderedMembers = store.items.first(where: { $0.id == folder.id })!.appIDs
        try check(reorderedMembers.firstIndex(of: first.id)! + 1 == reorderedMembers.firstIndex(of: third.id)!, "folder right-side drop places source after target")
        session.folderID = nil
        store.moveAppOutOfFolder(appID: first.id, folderID: folder.id)
        try check(store.items.contains { $0.id == first.id && !$0.isFolder }, "move app out of folder")
        store.moveItem(first.id, before: folder.id)
        let firstIndex = store.items.firstIndex { $0.id == first.id }!
        try check(store.items[firstIndex + 1].id == folder.id, "drag ordering")
        try checkLayout("reordering preserves catalog membership")
        let reload = LauncherStore(automaticallyRefresh: false)
        try check(reload.items == store.items, "layout survives persistence and reload")

        session.columns = 7
        session.rows = 5
        session.turnPage(100, store: store)
        try check(session.page == max(0, (store.items.count - 1) / 35), "pagination clamps to last page")
        session.rememberPage()
        let savedPage = session.page
        session.restorePresentation()
        try check(session.page == savedPage, "reopening preserves the last home page")
        let restartedSession = LauncherSession(preferences: sessionPreferences)
        try check(restartedSession.page == savedPage, "last home page survives application restart")
        session.turnPage(-100, store: store)
        try check(session.page == 0, "pagination clamps to first page")
        session.activate(store.items.first(where: { $0.id == folder.id })!, store: store)
        try check(session.folderID == folder.id && session.allItems(store).count == 2, "folder opens with correct contents")
        let folderHomePage = session.homePage
        session.escape()
        try check(session.folderID == nil, "Escape closes folder first")
        try check(session.page == folderHomePage, "leaving folder restores the originating home page")
        session.query = "safari"
        session.escape()
        try check(session.query.isEmpty, "Escape clears search")
        var dismissed = false
        session.dismiss = { dismissed = true }
        session.escape()
        try check(dismissed, "Escape dismisses launcher")
        store.resetLayout()
        try check(store.items.flatMap(\.appIDs) == defaults.flatMap(\.appIDs), "reset restores default ordering")
        try checkLayout("reset preserves every installed app")
        let slotSource = store.items.first(where: { !$0.isFolder })!
        try check(LauncherDropActions.onSlot(LauncherDragPayload(itemID: slotSource.id, folderID: nil), index: 40, store: store, session: session), "native empty-slot drop accepts cross-page placement")
        try check(store.items[40].id == slotSource.id, "empty-slot drop uses requested global position")
        try check(LauncherDropActions.onSlot(LauncherDragPayload(itemID: slotSource.id, folderID: nil), index: 999, store: store, session: session), "trailing empty-slot drop is accepted")
        try check(store.items.last?.id == slotSource.id, "trailing empty-slot clamps to end without losing apps")
        try checkLayout("slot placement preserves every app exactly once")
        store.resetLayout()
        let last = store.items.last(where: { !$0.isFolder })!
        let dropTarget = store.items.first(where: { !$0.isFolder })!
        try check(LauncherDropActions.onIcon(LauncherDragPayload(itemID: last.id, folderID: nil), target: dropTarget, horizontalFraction: 0.5, store: store, session: session), "any two standalone icons can merge, including across pages")
        try check(store.items.contains { $0.isFolder && Set($0.appIDs) == Set([last.id, dropTarget.id]) }, "merged folder contains exactly both dragged applications")
        try checkLayout("arbitrary icon merge preserves all apps")
        store.resetLayout()
        try check(store.errorMessage == nil, "no catalog or persistence errors")
        print("All smoke tests passed.")
    } catch {
        fputs("FAIL \(error)\n", stderr)
        exitCode = EXIT_FAILURE
    }
    exit(exitCode)
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
