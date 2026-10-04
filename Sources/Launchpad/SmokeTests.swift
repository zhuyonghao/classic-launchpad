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

        let store = LauncherStore()
        let deadline = Date().addingTimeInterval(30)
        while store.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(!store.isScanning, "application discovery finishes")
        try check(store.apps.count >= 3, "real installed applications discovered (\(store.apps.count))")
        try check(Set(store.apps.map(\.id)).count == store.apps.count, "catalog paths are unique")
        try check(Set(store.apps.map(\.bundleIdentifier)).count == store.apps.count, "bundle identifiers are deduplicated")
        try check(!store.apps.contains { $0.bundleIdentifier == "com.local.ClassicLaunchpad" }, "launcher excludes itself")
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
        let defaults = store.items
        let loose = store.items.filter { !$0.isFolder }
        try check(loose.count >= 3, "sufficient standalone applications for layout tests")
        let first = loose[0], second = loose[1], third = loose[2]
        store.createFolder(sourceID: first.id, targetID: second.id)
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
        store.moveAppOutOfFolder(appID: first.id, folderID: folder.id)
        try check(store.items.contains { $0.id == first.id && !$0.isFolder }, "move app out of folder")
        store.moveItem(first.id, before: folder.id)
        let firstIndex = store.items.firstIndex { $0.id == first.id }!
        try check(store.items[firstIndex + 1].id == folder.id, "drag ordering")
        try checkLayout("reordering preserves catalog membership")
        let reload = LauncherStore(automaticallyRefresh: false)
        try check(reload.items == store.items, "layout survives persistence and reload")

        let session = LauncherSession()
        session.columns = 7
        session.rows = 5
        session.turnPage(100, store: store)
        try check(session.page == max(0, (store.items.count - 1) / 35), "pagination clamps to last page")
        session.turnPage(-100, store: store)
        try check(session.page == 0, "pagination clamps to first page")
        session.activate(store.items.first(where: { $0.id == folder.id })!, store: store)
        try check(session.folderID == folder.id && session.allItems(store).count == 2, "folder opens with correct contents")
        session.escape()
        try check(session.folderID == nil, "Escape closes folder first")
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
