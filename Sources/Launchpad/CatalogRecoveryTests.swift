import AppKit

@MainActor
func runCatalogRecoveryTests() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("launchpad-catalog-recovery-\(UUID().uuidString)")
    let previousDirectory = getenv("CLASSIC_LAUNCHPAD_DATA_DIR").map { String(cString: $0) }
    let healthy = directory.appendingPathComponent("apps")
    let unavailable = directory.appendingPathComponent("offline")
    let sibling = directory.appendingPathComponent("offline-other")
    let held = directory.appendingPathComponent("held")
    let roots = [healthy, unavailable, sibling]
    for root in roots { try manager.createDirectory(at: root, withIntermediateDirectories: true) }
    setenv("CLASSIC_LAUNCHPAD_DATA_DIR", directory.appendingPathComponent("data").path, 1)
    var stores: [LauncherStore] = []
    defer {
        if let previousDirectory { setenv("CLASSIC_LAUNCHPAD_DATA_DIR", previousDirectory, 1) }
        else { unsetenv("CLASSIC_LAUNCHPAD_DATA_DIR") }
        try? manager.removeItem(at: directory)
    }
    func fixture(_ name: String, in root: URL) throws -> String {
        let url = root.appendingPathComponent(name + ".app")
        try manager.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.recovery.\(name)", "CFBundleName": name,
                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url.path
    }
    func wait(_ store: LauncherStore) async throws {
        let deadline = Date().addingTimeInterval(10)
        while store.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(!store.isScanning, "isolated catalog scan finishes")
    }
    func drain() async {
        while stores.contains(where: \.isScanning) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    do {
        let a = try fixture("A", in: healthy)
        let b = try fixture("B", in: unavailable)
        let c = try fixture("C", in: sibling)
        let scan = { AppCatalogScanner.scan(roots: roots) }
        let store = LauncherStore(automaticallyRefresh: false, scanApplications: scan)
        stores.append(store)
        store.refresh()
        try await wait(store)
        store.createFolder(sourceID: a, targetID: b)
        let folderID = store.items.first(where: \.isFolder)!.id
        store.renameFolder(folderID, name: "Favorites")
        let originalFolder = store.items.first(where: \.isFolder)!
        let folderPosition = store.items.firstIndex(where: \.isFolder)!

        // A file at a configured root deterministically fails directory reads,
        // even when tests run as root and chmod cannot simulate permission denial.
        try manager.moveItem(at: unavailable, to: held)
        try Data("temporarily unreadable".utf8).write(to: unavailable)
        try manager.removeItem(atPath: c)
        let d = try fixture("D", in: healthy)
        let partial = scan()
        try check(partial.issue != nil && partial.unavailablePaths.contains(unavailable),
                  "a partial scan reports its failed root even while other roots succeed")
        store.refresh()
        try await wait(store)
        try check(store.items.first(where: \.isFolder) == originalFolder &&
                  store.items.firstIndex(where: \.isFolder) == folderPosition,
                  "partial scans preserve the folder ID, name, membership, ordering, and position")
        try check(store.app(for: b) != nil && store.app(for: c) == nil && store.app(for: d) != nil,
                  "failed paths retain apps while readable sibling roots still reconcile removals and additions")
        try check(store.search("B").contains(where: { $0.id == b }), "preserved apps retain searchable metadata")

        let restarted = LauncherStore(scanApplications: scan)
        stores.append(restarted)
        try check(restarted.items.first(where: \.isFolder) == originalFolder && restarted.app(for: b) != nil,
                  "loading the cached catalog does not erase a missing path before discovery")
        try await wait(restarted)
        try check(restarted.items.first(where: \.isFolder) == originalFolder,
                  "the original folder survives restarting during the directory outage")

        try manager.removeItem(at: unavailable)
        try manager.moveItem(at: held, to: unavailable)
        restarted.refresh()
        try await wait(restarted)
        try check(restarted.items.first(where: \.isFolder) == originalFolder,
                  "directory recovery restores the application in its original folder")
        try check(restarted.errorMessage == nil, "directory recovery clears its previous scan warning")
        try check(Set(restarted.items.flatMap(\.appIDs)) == Set([a, b, d]) &&
                  restarted.items.flatMap(\.appIDs).count == 3,
                  "partial scans and recovery preserve each application exactly once")

        try manager.removeItem(atPath: b)
        restarted.refresh()
        try await wait(restarted)
        try check(restarted.app(for: b) == nil && !restarted.items.contains(where: \.isFolder) &&
                  restarted.items.contains(where: { $0.id == a }),
                  "a successful directory read still removes an uninstalled app and collapses its folder")
        await drain()
        print("PASS: partial catalog failures, cached restart during outage, layout recovery, path boundaries, and confirmed removals")
    } catch {
        await drain()
        throw error
    }
}
