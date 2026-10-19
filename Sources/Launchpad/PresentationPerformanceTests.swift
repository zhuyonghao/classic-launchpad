import AppKit
import Foundation

@MainActor
func runPresentationPerformanceTests() async throws {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("classic-launchpad-presentation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let previousDirectory = getenv("CLASSIC_LAUNCHPAD_DATA_DIR").map { String(cString: $0) }
    let previousUITest = getenv("CLASSIC_LAUNCHPAD_UI_TEST").map { String(cString: $0) }
    setenv("CLASSIC_LAUNCHPAD_DATA_DIR", directory.path, 1)
    var scanningStores: [LauncherStore] = []
    let suiteName = "ClassicLaunchpad.Presentation.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suiteName)!
    defer {
        if let previousDirectory { setenv("CLASSIC_LAUNCHPAD_DATA_DIR", previousDirectory, 1) }
        else { unsetenv("CLASSIC_LAUNCHPAD_DATA_DIR") }
        if let previousUITest { setenv("CLASSIC_LAUNCHPAD_UI_TEST", previousUITest, 1) }
        else { unsetenv("CLASSIC_LAUNCHPAD_UI_TEST") }
        preferences.removePersistentDomain(forName: suiteName)
        LauncherIconCache.removeAll()
        LauncherWallpaperCache.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    func waitForScan(_ store: LauncherStore) async throws {
        let deadline = Date().addingTimeInterval(30)
        while store.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try check(!store.isScanning, "presentation test background catalog scan finishes")
    }
    // Every scan owns a captured cache URL. Drain pending work even on a failed
    // assertion before restoring the surrounding smoke test's data directory.
    func drainScans() async {
        while scanningStores.contains(where: \.isScanning) {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    do {
        let apps = try (0..<17).map { index -> LauncherApp in
            let url = directory.appendingPathComponent("Fixture-\(index).app", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return LauncherApp(id: url.path, name: "Fixture \(index)", url: url,
                               bundleIdentifier: "test.presentation.\(index)")
        }
        func item(_ app: LauncherApp) -> LauncherItem {
            LauncherItem(id: app.id, name: app.name, appIDs: [app.id], isFolder: false)
        }
        let store = LauncherStore(automaticallyRefresh: false)
        store.apps = apps
        store.items = [item(apps[0]), item(apps[1]),
                       LauncherItem(id: "preview-folder", name: "Preview", appIDs: apps[2...13].map(\.id), isFolder: true),
                       item(apps[14]), item(apps[15]), item(apps[16])]
        preferences.set(1, forKey: "lastLauncherPage")
        let session = LauncherSession(preferences: preferences)
        session.columns = 2
        session.rows = 1
        session.folderID = "preview-folder"
        session.query = "stale search"
        session.page = 0
        session.restorePresentation()
        let visibleApps = session.presentationApps(store)
        let expectedIDs = apps[2...10].map(\.id) + [apps[14].id]
        try check(visibleApps.map(\.id) == expectedIDs,
                  "reopen prepares the remembered home page and only its first nine folder previews")

        LauncherIconCache.removeAll()
        try check(LauncherIconCache.areCached([]), "an empty page is immediately prepared")
        try check(!LauncherIconCache.areCached(visibleApps) &&
                  LauncherIconCache.cachedImage(for: apps[2].url) == nil,
                  "checking page readiness does not decode cold icons")
        let retainedIcons = visibleApps.map(\.icon)
        try check(LauncherIconCache.areCached(visibleApps), "preparing one page enables synchronous reopen")
        let visibleIDs = Set(expectedIDs)
        try check(apps.filter { !visibleIDs.contains($0.id) }.allSatisfy {
            LauncherIconCache.cachedImage(for: $0.url) == nil
        }, "preparing a page leaves other pages and hidden folder members undecoded")
        session.restorePresentation()
        try check(zip(session.presentationApps(store), retainedIcons).allSatisfy {
            LauncherIconCache.cachedImage(for: $0.0.url) === $0.1
        }, "presentation reset reuses the already decoded page icons")
        let updatedApp = LauncherApp(id: apps[2].id, name: apps[2].name, url: apps[2].url,
                                     bundleIdentifier: apps[2].bundleIdentifier, iconRevision: 1)
        try check(!LauncherIconCache.areCached([updatedApp]) &&
                  LauncherIconCache.cachedImage(for: updatedApp.url, revision: 1) == nil,
                  "an updated application cannot reuse its previous icon revision")
        let updatedIcon = updatedApp.icon
        try check(updatedIcon !== retainedIcons[0] && LauncherIconCache.areCached([updatedApp]) &&
                  LauncherIconCache.cachedImage(for: apps[2].url) === retainedIcons[0],
                  "an application update prepares a fresh icon while preserving other warm revisions")

        store.items[3] = item(apps[2])
        try check(session.presentationApps(store).map(\.id) == apps[2...10].map(\.id),
                  "duplicated visible application references are prepared only once")
        session.page = Int.max
        try check(session.presentationApps(store).map(\.id) == apps[15...16].map(\.id),
                  "a remembered page beyond the current layout prepares the last page")
        session.page = -1
        try check(session.presentationApps(store).map(\.id) == apps[0...1].map(\.id),
                  "a negative page prepares the first page")
        store.apps = []
        store.items = []
        try check(session.presentationApps(store).isEmpty, "an empty catalog requires no icon preparation")

        let homeContext = LauncherPageContext(folderID: nil, query: "")
        let searchContext = LauncherPageContext(folderID: nil, query: "fixture")
        let folderContext = LauncherPageContext(folderID: "preview-folder", query: "")
        var mounted = LauncherPageMountState()
        try check(mounted.contains(0, currentPage: 0, in: homeContext, isDragging: false) &&
                  !mounted.contains(1, currentPage: 0, in: homeContext, isDragging: false),
                  "initial rendering mounts the current page without constructing other pages")
        mounted.visit(0, in: homeContext, isDragging: false)
        try check(mounted.animatesTransition(to: 1, in: homeContext) &&
                  !mounted.animatesTransition(to: 4, in: homeContext),
                  "adjacent paging animates while distant jumps avoid traversing unmounted pages")
        mounted.visit(1, in: homeContext, isDragging: false)
        mounted.visit(4, in: homeContext, isDragging: false)
        try check(mounted.contains(0, currentPage: 4, in: homeContext, isDragging: false) &&
                  mounted.contains(1, currentPage: 4, in: homeContext, isDragging: false) &&
                  !mounted.contains(2, currentPage: 4, in: homeContext, isDragging: false),
                  "paging retains visited native drag surfaces without building skipped pages")
        mounted.visit(0, in: searchContext, isDragging: true)
        try check(mounted.contains(4, currentPage: 0, in: searchContext, isDragging: true),
                  "changing context during a native drag retains its mounted source surface")
        mounted.visit(0, in: searchContext, isDragging: false)
        try check(!mounted.contains(4, currentPage: 0, in: searchContext, isDragging: false),
                  "ending a drag applies the deferred context reset")
        mounted.visit(1, in: folderContext, isDragging: false)
        try check(!mounted.contains(0, currentPage: 1, in: folderContext, isDragging: false),
                  "opening a folder starts with its current page rather than prior search pages")
        mounted.clear()
        try check(mounted.pages.isEmpty && mounted.context == nil && mounted.lastPage == nil,
                  "hiding the launcher releases visited page surfaces")

        let catalogURL = directory.appendingPathComponent("catalog.json")
        func saveCatalog(_ entries: [[String: String]], version: Int = 1) throws {
            try JSONSerialization.data(withJSONObject: ["version": version, "apps": entries])
                .write(to: catalogURL, options: .atomic)
        }
        func entry(_ app: LauncherApp) -> [String: String] {
            ["name": app.name, "path": app.url.path, "bundleIdentifier": app.bundleIdentifier,
             "searchIndex": "fixture warmcatalog"]
        }
        // The assertions run before yielding the main actor: background discovery
        // cannot be responsible for the visible catalog or its search results.
        try saveCatalog([entry(apps[0]), entry(apps[1])])
        let cached = LauncherStore()
        scanningStores.append(cached)
        try check(cached.apps.map(\.id) == apps[0...1].map(\.id) && cached.isScanning,
                  "a process restart restores cached applications before discovery completes")
        try check(cached.items.flatMap(\.appIDs) == apps[0...1].map(\.id) &&
                  cached.search("warmcatalog").count == 2,
                  "the restored catalog immediately supplies layout and prepared search metadata")
        try await waitForScan(cached)
        try check(!cached.apps.isEmpty, "background discovery reconciles a cached catalog")
        try check(cached.apps.allSatisfy {
            LauncherIconCache.cachedImage(for: $0.url, revision: $0.iconRevision) == nil
        }, "catalog discovery leaves icon decoding to the pages that become visible")
        let discoveredIDs = cached.apps.map(\.id)
        let restarted = LauncherStore()
        scanningStores.append(restarted)
        try check(restarted.apps.map(\.id) == discoveredIDs,
                  "a successful discovery saves the next process's immediate catalog")
        try await waitForScan(restarted)
        restarted.refreshIfNeeded()
        try check(!restarted.isScanning, "rapid reopening skips a recent catalog scan")
        restarted.refresh()
        try check(restarted.isScanning, "explicit refresh bypasses the reopening scan throttle")
        try await waitForScan(restarted)

        let missing = LauncherApp(id: directory.appendingPathComponent("Removed.app").path,
                                  name: "Removed", url: directory.appendingPathComponent("Removed.app"),
                                  bundleIdentifier: "test.presentation.removed")
        try saveCatalog([entry(apps[0]), entry(missing), entry(apps[0])])
        let partiallyValid = LauncherStore()
        scanningStores.append(partiallyValid)
        try check(partiallyValid.apps.map(\.id) == [apps[0].id, missing.id] &&
                  partiallyValid.items.flatMap(\.appIDs) == [apps[0].id, missing.id],
                  "cached catalog deduplicates apps but leaves removal confirmation to discovery")
        try await waitForScan(partiallyValid)

        try Data("invalid catalog JSON".utf8).write(to: catalogURL, options: .atomic)
        let corrupt = LauncherStore()
        scanningStores.append(corrupt)
        try check(corrupt.apps.isEmpty && corrupt.isScanning,
                  "corrupt catalog cache falls back to background discovery")
        try await waitForScan(corrupt)
        try check(!corrupt.apps.isEmpty && corrupt.errorMessage == nil,
                  "discovery recovers from a corrupt optional cache without an error")
        try check((try? JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))) != nil,
                  "successful discovery replaces the corrupt cache")

        setenv("CLASSIC_LAUNCHPAD_UI_TEST", "1", 1)
        let delegate = AppDelegate()
        scanningStores.append(delegate.store)
        try await waitForScan(delegate.store)
        guard let sample = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let pixels = sample.bitmapData else {
            throw Failure(description: "wallpaper retention fixture can be created")
        }
        pixels.initialize(repeating: 255, count: sample.bytesPerRow * sample.pixelsHigh)
        let wallpaperURL = directory.appendingPathComponent("retained-wallpaper.png")
        guard let wallpaperData = sample.representation(using: .png, properties: [:]) else {
            throw Failure(description: "wallpaper retention fixture can be encoded")
        }
        try wallpaperData.write(to: wallpaperURL)
        let wallpaperSize = NSSize(width: 128, height: 80)
        let retainedWallpaper = LauncherWallpaperCache.image(for: wallpaperURL, size: wallpaperSize)
        try check(retainedWallpaper != nil, "wallpaper retention fixture is rendered")
        delegate.session.wallpaper = retainedWallpaper
        delegate.session.isPresented = true
        // Prevent this integration check from saving a page in standard user
        // preferences; the standalone session checks use an isolated suite.
        delegate.session.query = "retention test"
        delegate.hideLauncher()
        try await Task.sleep(for: .milliseconds(400))
        try check(!delegate.session.isPresented && zip(visibleApps, retainedIcons).allSatisfy {
            LauncherIconCache.cachedImage(for: $0.0.url) === $0.1
        }, "hiding beyond the former eviction delay retains decoded icons for the next reopen")
        try check(LauncherWallpaperCache.cachedImage(for: wallpaperURL, size: wallpaperSize) === retainedWallpaper,
                  "hiding retains the prepared wallpaper texture for the next reopen")
        await drainScans()
        print("PASS: page-only preparation, lazy native surfaces, retained reopen caches, immediate catalog restore, cache recovery, and scan throttling")
    } catch {
        await drainScans()
        throw error
    }
}
