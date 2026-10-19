import AppKit

@MainActor
func runPagingContentCacheTests() throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    let suite = "ClassicLaunchpad.PagingCache.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let session = LauncherSession(preferences: preferences)
    let store = LauncherStore(automaticallyRefresh: false)
    let apps = (0..<96).map { index in
        LauncherApp(id: "fixture-\(index)", name: "Fixture \(index)",
                    url: URL(fileURLWithPath: "/paging-fixtures/\(index).app"),
                    bundleIdentifier: "test.paging.\(index)")
    }
    store.apps = apps
    store.items = [LauncherItem(id: "folder", name: "Folder", appIDs: apps.map(\.id), isFolder: true)]
    session.folderID = "folder"
    let original = session.allItems(store)
    let builds = session.derivedItemBuildCount
    var checksum = 0
    for sample in 0..<10_000 {
        let items = session.allItems(store)
        checksum += items[sample % items.count].name.count
    }
    try check(original.count == 96 && checksum > 0 && session.derivedItemBuildCount == builds,
              "ten thousand scroll-path reads reuse the full folder without rebuilding its items")

    store.items[0].appIDs.reverse()
    try check(session.allItems(store).map(\.id) == apps.reversed().map(\.id),
              "an in-place folder reorder invalidates cached paging contents")
    let renamed = LauncherApp(id: apps[95].id, name: "Renamed App", url: apps[95].url,
                              bundleIdentifier: apps[95].bundleIdentifier)
    store.apps[95] = renamed
    try check(session.allItems(store).first?.name == "Renamed App",
              "a catalog name change invalidates the derived folder names")
    store.apps.removeLast()
    try check(session.allItems(store).count == 95 && session.allItems(store).first?.id == apps[94].id,
              "an application removal cannot leave a stale folder entry")
    store.items[0].appIDs = [apps[1].id, apps[2].id]
    try check(session.allItems(store).map(\.id) == [apps[1].id, apps[2].id],
              "folder membership changes invalidate the cached page list")

    session.folderID = nil
    session.query = "Fixture 94"
    try check(session.allItems(store).map(\.id) == [apps[94].id], "search uses its own cache context")
    let searchBuilds = session.derivedItemBuildCount
    _ = session.allItems(store)
    try check(session.derivedItemBuildCount == searchBuilds, "unchanged search reads reuse their result")
    session.query = "Fixture 93"
    try check(session.allItems(store).map(\.id) == [apps[93].id], "changing the query invalidates search results")
    store.apps.removeLast()
    try check(session.allItems(store).map(\.id) == [apps[93].id], "a catalog update refreshes active search results")
    store.apps.removeLast()
    try check(session.allItems(store).isEmpty, "removed apps disappear from cached searches")
    session.query = ""
    try check(session.allItems(store) == store.items, "returning home uses the current stored layout")
    session.folderID = "folder"
    _ = session.allItems(store)
    let replacement = LauncherStore(automaticallyRefresh: false)
    replacement.apps = [apps[5]]
    replacement.items = [LauncherItem(id: "folder", name: "Other folder", appIDs: [apps[5].id], isFolder: true)]
    try check(session.allItems(replacement).map(\.id) == [apps[5].id],
              "switching stores never reuses a folder result from another store")
    store.items = []
    try check(session.allItems(store).isEmpty, "deleting an open folder invalidates its cached contents")
    print("PASS: scroll-path folder/search reuse and invalidation after reorder, rename, removal, query, and store changes")
}
