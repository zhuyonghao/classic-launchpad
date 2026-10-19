import AppKit
import SwiftUI

@MainActor
func runFolderOrganizationTests() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folder-organization-\(UUID().uuidString)")
    let previousDirectory = ProcessInfo.processInfo.environment["CLASSIC_LAUNCHPAD_DATA_DIR"]
    setenv("CLASSIC_LAUNCHPAD_DATA_DIR", directory.path, 1)
    let suite = "ClassicLaunchpad.FolderOrganization.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        if let previousDirectory { setenv("CLASSIC_LAUNCHPAD_DATA_DIR", previousDirectory, 1) }
        else { unsetenv("CLASSIC_LAUNCHPAD_DATA_DIR") }
    }
    let store = LauncherStore(automaticallyRefresh: false)
    store.apps = (0..<80).map {
        LauncherApp(id: "app-\($0)", name: "App \($0)", url: URL(fileURLWithPath: "/organization-fixtures/\($0).app"),
                    bundleIdentifier: "test.organization.\($0)")
    }
    let loose = store.apps.map { LauncherItem(id: $0.id, name: $0.name, appIDs: [$0.id], isFolder: false) }
    store.items = loose
    let session = LauncherSession(preferences: preferences)
    let original = store.items
    session.beginAppSelection(store: store, including: "app-40")
    session.activate(loose[40], store: store)
    try check(session.selectedAppIDs.isEmpty, "clicking an already selected app deselects it without launching")
    session.activate(loose[40], store: store)
    session.turnPage(1, store: store)
    session.activate(loose[75], store: store)
    session.turnPage(-1, store: store)
    session.activate(loose[2], store: store)
    try check(session.selectedAppIDs == ["app-2", "app-40", "app-75"] && store.items == original,
              "selection survives paging and does not change the layout before merging")
    guard let folderID = session.mergeSelectedApps(store: store),
          let merged = store.items.first(where: { $0.id == folderID }) else {
        throw Failure(description: "multiple selected apps merge into a folder")
    }
    try check(store.items[2] == merged && merged.appIDs == ["app-2", "app-40", "app-75"] &&
              session.page == 0 && session.selectedID == folderID && !session.isSelectingApps && session.selectedAppIDs.isEmpty,
              "batch merge follows layout order, replaces the first selected app, and reveals the result")
    try check(LauncherStore(automaticallyRefresh: false).items == store.items, "batch merge persists")
    let afterMerge = store.items
    for ids: Set<String> in [[], ["app-0"], ["app-0", "missing"], ["app-0", folderID], ["app-0", "app-40"]] {
        try check(store.createFolder(appIDs: ids) == nil && store.items == afterMerge,
                  "empty, singleton, stale, folder, and already grouped selections cannot partially merge")
    }
    session.beginAppSelection(store: store, including: "app-1")
    session.activate(merged, store: store)
    try check(session.folderID == nil && session.selectedAppIDs == ["app-1"], "existing folders are excluded from app selection")
    session.escape()
    try check(!session.isSelectingApps && session.selectedAppIDs.isEmpty && store.items == afterMerge, "Escape cancels selection without layout changes")
    session.beginAppSelection(store: store, including: "app-1")
    session.restorePresentation()
    try check(!session.isSelectingApps && session.selectedAppIDs.isEmpty, "reopening the launcher clears selection mode")
    try check(!store.dissolveFolder("missing") && !store.dissolveFolder("app-0") && store.items == afterMerge,
              "dissolving an invalid or standalone item is a no-op")
    try check(store.dissolveFolder(folderID), "one-click dissolve succeeds")
    try check(Array(store.items[2...4]).map(\.id) == merged.appIDs && store.items.count == 80 &&
              Set(store.items.flatMap(\.appIDs)).count == 80,
              "dissolve expands members at the folder position in their saved order without losing apps")
    try check(LauncherStore(automaticallyRefresh: false).items == store.items, "dissolved layout persists")

    let folder = LauncherItem(id: "large-folder", name: "Large Folder", appIDs: loose.prefix(45).map(\.id), isFolder: true)
    let layout = [folder] + Array(loose.dropFirst(45))
    store.items = layout
    session.isPresented = true
    session.activate(folder, store: store)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1020, height: 710),
                          styleMask: .borderless, backing: .buffered, defer: false)
    let host = NSHostingView(rootView: LauncherView(store: store, session: session))
    window.contentView = host
    defer { session.isPresented = false; window.contentView = nil }
    func surfaces(in view: NSView) -> [LauncherIconInteractionView] {
        (view as? LauncherIconInteractionView).map { [$0] } ?? view.subviews.flatMap { surfaces(in: $0) }
    }
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
    }
    func waitForPage(_ page: Int) async throws {
        let deadline = Date().addingTimeInterval(2)
        while session.page != page && Date() < deadline { try await settle() }
        try check(session.page == page, "holding an app at the folder edge turns to page \(page + 1)")
        // An offscreen test window has no display callbacks to finish movement.
        session.folderPaging.viewport?.completeTracking(at: page)
        try await settle()
    }
    host.layoutSubtreeIfNeeded()
    try await settle()
    guard let source = surfaces(in: host).first(where: { $0.itemID == "app-0" }) else {
        throw Failure(description: "large folder mounts its first-page drag source")
    }
    let payload = LauncherDragPayload(itemID: "app-0", folderID: folder.id)
    source.onDragStarted(payload)
    let frame = session.folderPanelFrame
    try check(!frame.isEmpty, "the multi-page folder reports its panel geometry")
    session.moveDrag(to: NSPoint(x: frame.maxX - 8, y: frame.midY))
    try check(session.folderID == folder.id && session.dragPageDirection == 1, "the right panel edge selects folder paging before any drag-out")
    try await waitForPage(1)
    session.moveDrag(to: NSPoint(x: frame.midX, y: frame.midY))
    try check(session.dragPageDirection == nil && surfaces(in: host).contains(where: { $0 === source }),
              "leaving the edge cancels repeat paging and retains the original native drag source")
    guard let destination = surfaces(in: host).first(where: { $0.itemID == "app-40" }) else {
        throw Failure(description: "the second folder page mounts native destinations")
    }
    try check(destination.canDrop(payload) && !source.canDrop(LauncherDragPayload(itemID: "app-40", folderID: folder.id)),
              "only the current folder page accepts drops")
    try check(destination.onDrop(payload, 0.1), "the first-page app can be dropped before a second-page app")
    try check(store.items[0].appIDs[39] == "app-0" && session.folderID == folder.id && store.items.count == layout.count,
              "cross-page folder placement reorders membership without extracting an app")
    source.onDragEnded()
    try await settle()
    guard let reverseSource = surfaces(in: host).first(where: { $0.itemID == "app-0" && $0.sourceFolderID == folder.id && $0.canDrop(LauncherDragPayload(itemID: "app-44", folderID: folder.id)) }) else {
        throw Failure(description: "the moved app becomes an active second-page source")
    }
    reverseSource.onDragStarted(payload)
    session.moveDrag(to: NSPoint(x: frame.minX + 8, y: frame.midY))
    try await waitForPage(0)
    session.moveDrag(to: NSPoint(x: frame.midX, y: frame.midY))
    guard let firstTarget = surfaces(in: host).first(where: { $0.itemID == "app-1" }) else {
        throw Failure(description: "the first page remains available for a reverse drop")
    }
    try check(firstTarget.canDrop(payload) && firstTarget.onDrop(payload, 0.9) && Array(store.items[0].appIDs.prefix(2)) == ["app-1", "app-0"],
              "the second-page app can move back after a first-page app")
    reverseSource.onDragEnded()
    try await settle()
    let beforeCancel = store.items
    session.beginDrag(payload, exportsApplication: true, sourceFolder: store.items[0])
    session.moveDrag(to: NSPoint(x: frame.maxX - 8, y: frame.midY))
    session.moveDrag(to: NSPoint(x: frame.midX, y: frame.midY))
    try await Task.sleep(for: .milliseconds(650))
    try check(session.page == 0 && session.dragPageDirection == nil, "leaving a folder edge before the dwell time cancels its pending turn")
    session.moveDrag(to: NSPoint(x: frame.maxX - 8, y: frame.midY))
    try await waitForPage(1)
    session.endDrag()
    try check(store.items == beforeCancel && session.dragPageDirection == nil && session.folderID == folder.id,
              "cancelling after a page turn preserves membership and clears edge feedback")
    session.beginDrag(payload, exportsApplication: true, sourceFolder: store.items[0])
    try check(LauncherDropActions.onPageBackground(payload, folderID: folder.id, store: store, session: session) &&
              store.items[0].appIDs.last == "app-0" && session.folderID == folder.id,
              "dropping in the second page margin moves to its end without dissolving or exiting the folder")
    try check(store.items.flatMap(\.appIDs).count == 80 && Set(store.items.flatMap(\.appIDs)).count == 80,
              "folder paging and margin drops preserve every application exactly once")
    try check(LauncherStore(automaticallyRefresh: false).items == store.items, "cross-page folder placement persists")
    session.endDrag()
    store.dissolveFolder(folder.id)
    try await settle()
    try check(session.folderID == nil && store.items.count == 80, "dissolving an open multi-page folder returns to the root grid")

    session.beginAppSelection(store: store)
    try await settle()
    guard let selectable = surfaces(in: host).first(where: { $0.itemID == "app-1" }) else {
        throw Failure(description: "selection mode mounts native click surfaces")
    }
    selectable.onActivate()
    try check(session.selectedAppIDs == ["app-1"] && !selectable.allowsDragging,
              "the real selection-mode tile toggles immediately and disables native drags")
    session.cancelAppSelection()
    print("PASS: batch selection across pages, merge/dissolve order and persistence, live folder edge dwell in both directions, native source retention, cancellation, margin drops, and selection surfaces")
}
