import AppKit
import SwiftUI

@MainActor
func runFolderInteractionTests() throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folder-tests-\(UUID().uuidString)")
    let previousDirectory = ProcessInfo.processInfo.environment["CLASSIC_LAUNCHPAD_DATA_DIR"]
    setenv("CLASSIC_LAUNCHPAD_DATA_DIR", directory.path, 1)
    let suite = "ClassicLaunchpad.FolderInteraction.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        if let previousDirectory { setenv("CLASSIC_LAUNCHPAD_DATA_DIR", previousDirectory, 1) }
        else { unsetenv("CLASSIC_LAUNCHPAD_DATA_DIR") }
    }
    let store = LauncherStore(automaticallyRefresh: false)
    store.apps = (0..<80).map {
        LauncherApp(id: "app-\($0)", name: "App \($0)", url: URL(fileURLWithPath: "/folder-fixtures/\($0).app"),
                    bundleIdentifier: "test.folder.\($0)")
    }
    let loose = store.apps.map { LauncherItem(id: $0.id, name: $0.name, appIDs: [$0.id], isFolder: false) }
    let folder = LauncherItem(id: "folder", name: "Folder", appIDs: ["app-0", "app-1"], isFolder: true)
    let layout = [folder] + Array(loose.dropFirst(2))
    store.items = layout
    let session = LauncherSession(preferences: preferences)
    session.page = 1
    session.rememberPage()
    session.activate(folder, store: store)
    let payload = LauncherDragPayload(itemID: "app-0", folderID: folder.id)
    session.beginDrag(payload, exportsApplication: true, sourceFolder: folder)
    session.folderPanelFrame = NSRect(x: 100, y: 100, width: 600, height: 400)
    session.moveDrag(to: NSPoint(x: 90, y: 300))
    try check(session.folderID == folder.id, "panel exit tolerance prevents boundary flicker")
    session.moveDrag(to: NSPoint(x: 75, y: 300))
    try check(session.folderID == nil && session.page == 1 && session.draggingID == payload.itemID,
              "exiting a folder reveals the remembered root page without ending the native drag")
    try check(session.dragSourceFolder == folder && session.dragSourcePage == 0,
              "the native source retains its folder and source page while choosing a root destination")
    try check(store.items == layout, "dragging outside does not commit a layout change")
    session.endDrag()
    try check(store.items == layout && session.dragSourceFolder == nil,
              "cancelling or exporting a folder member leaves membership unchanged and releases its source")

    session.activate(folder, store: store)
    session.beginDrag(payload, exportsApplication: true, sourceFolder: folder)
    session.moveDrag(to: NSPoint(x: 750, y: 300))
    session.turnPage(1, store: store)
    try check(session.page == 2, "a drag out can continue to another root page")
    try check(LauncherDropActions.onSlot(payload, index: 72, store: store, session: session), "cross-page member extraction is accepted")
    try check(store.items[72].id == "app-0" && store.items[0] == loose[1],
              "the dragged member takes the chosen slot and the remaining app replaces its folder in place")
    let reloaded = LauncherStore(automaticallyRefresh: false)
    try check(reloaded.items == store.items, "collapsed folders and chosen positions persist")
    session.endDrag()

    for fraction: CGFloat in [0.1, 0.5, 0.9] {
        store.items = layout
        try check(LauncherDropActions.onIcon(payload, target: folder, horizontalFraction: fraction, store: store, session: session),
                  "dragging back onto the source folder is accepted")
        if fraction == 0.5 {
            try check(store.items == layout, "dropping into the source folder preserves its identity and contents")
        } else {
            let expected = fraction < 0.5 ? ["app-0", "app-1"] : ["app-1", "app-0"]
            try check(Array(store.items.prefix(2)).map(\.id) == expected && !store.items[0].isFolder,
                      "side insertion resolves the surviving icon when its folder collapses")
        }
    }
    for fraction: CGFloat in [0.1, 0.5, 0.9] {
        store.items = layout
        try check(LauncherDropActions.onIcon(payload, target: loose[10], horizontalFraction: fraction, store: store, session: session),
                  "an extracted application can be placed before, after, or merged with a root target")
        if fraction == 0.5 {
            try check(store.items.contains { $0.isFolder && $0.appIDs == ["app-10", "app-0"] },
                      "merging an extracted member creates the requested folder")
        } else {
            let targetIndex = store.items.firstIndex { $0.id == "app-10" }!
            try check(store.items[targetIndex + (fraction < 0.5 ? -1 : 1)].id == "app-0", "root placement follows the insertion side")
        }
        let members = store.items.flatMap(\.appIDs)
        try check(members.count == 80 && Set(members).count == 80 && !store.items.contains { $0.isFolder && $0.appIDs.count < 2 },
                  "extraction preserves every app once and leaves no singleton folders")
    }
    let otherFolder = LauncherItem(id: "other-folder", name: "Other", appIDs: ["app-2", "app-3"], isFolder: true)
    store.items = [folder, otherFolder] + Array(loose.dropFirst(4))
    store.moveApp("app-0", toFolder: otherFolder.id)
    try check(store.items[0] == loose[1] && store.items[1].appIDs == ["app-2", "app-3", "app-0"],
              "moving through the context menu also collapses the source folder in place")
    store.items = layout
    let absentTarget = LauncherItem(id: "missing", name: "Missing", appIDs: ["missing"], isFolder: false)
    try check(!LauncherDropActions.onIcon(payload, target: absentTarget, horizontalFraction: 0.5, store: store, session: session) && store.items == layout,
              "an invalid target cannot partially extract a folder member")
    session.activate(folder, store: store)
    try check(!LauncherDropActions.onIcon(LauncherDragPayload(itemID: "app-5", folderID: nil), target: loose[0], horizontalFraction: 0.5, store: store, session: session) && store.items == layout,
              "a hidden root surface cannot mutate an open folder")
    print("PASS: continuous folder drag-out, cancellation/export, cross-page placement, source-folder drops, singleton collapse, persistence, and app uniqueness")
}

@MainActor
func runFolderPresentationTests() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folder-presentation-\(UUID().uuidString)")
    let previousDirectory = ProcessInfo.processInfo.environment["CLASSIC_LAUNCHPAD_DATA_DIR"]
    setenv("CLASSIC_LAUNCHPAD_DATA_DIR", directory.path, 1)
    defer {
        try? FileManager.default.removeItem(at: directory)
        if let previousDirectory { setenv("CLASSIC_LAUNCHPAD_DATA_DIR", previousDirectory, 1) }
        else { unsetenv("CLASSIC_LAUNCHPAD_DATA_DIR") }
    }
    let suite = "ClassicLaunchpad.FolderPresentation.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let store = LauncherStore(automaticallyRefresh: false)
    store.apps = (0..<45).map {
        LauncherApp(id: "presentation-\($0)", name: "App \($0)", url: URL(fileURLWithPath: "/folder-fixtures/\($0).app"),
                    bundleIdentifier: "test.folder.presentation.\($0)")
    }
    let folder = LauncherItem(id: "presentation-folder", name: "Folder", appIDs: ["presentation-0", "presentation-1"], isFolder: true)
    store.items = [folder] + store.apps.dropFirst(2).map { LauncherItem(id: $0.id, name: $0.name, appIDs: [$0.id], isFolder: false) }
    let session = LauncherSession(preferences: preferences)
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
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    guard let source = surfaces(in: host).first(where: { $0.itemID == "presentation-0" }) else {
        throw Failure(description: "the open folder mounts a native drag source")
    }
    try check(!session.folderPanelFrame.isEmpty, "the actual panel publishes its screen bounds for native drag exit detection")
    let payload = LauncherDragPayload(itemID: source.itemID, folderID: folder.id)
    source.onDragStarted(payload)
    session.moveDrag(to: NSPoint(x: session.folderPanelFrame.midX, y: session.folderPanelFrame.maxY + 50))
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    let afterExit = surfaces(in: host)
    try check(session.folderID == nil && afterExit.contains(where: { $0 === source }),
              "revealing the root grid retains the same native source view for AppKit callbacks")
    guard let destination = afterExit.first(where: { $0.itemID == "presentation-5" }) else {
        throw Failure(description: "the root grid mounts native drop targets after folder exit")
    }
    try check(destination.canDrop(payload) && !source.canDrop(LauncherDragPayload(itemID: "presentation-1", folderID: folder.id)),
              "root destinations accept the in-flight drag while retained folder surfaces reject hidden drops")
    try check(destination.onDrop(payload, 0.1), "the revealed native target commits the requested insertion")
    try await Task.sleep(for: .milliseconds(50))
    host.layoutSubtreeIfNeeded()
    try check(surfaces(in: host).contains(where: { $0 === source }),
              "collapsing the source folder on drop preserves its source until native drag completion")
    source.onDragEnded()
    try check(session.draggingID == nil && session.dragSourceFolder == nil,
              "the retained source can deliver native completion after the folder disappears")
    print("PASS: real SwiftUI/AppKit panel geometry, native source identity across drag-out and collapse, and root drop targeting")
}
