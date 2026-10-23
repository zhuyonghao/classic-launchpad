import AppKit
import SwiftUI

@MainActor
func runNativeSourceDropTests() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-drop-\(UUID().uuidString)")
    let previousDirectory = ProcessInfo.processInfo.environment["CLASSIC_LAUNCHPAD_DATA_DIR"]
    setenv("CLASSIC_LAUNCHPAD_DATA_DIR", directory.path, 1)
    let suite = "ClassicLaunchpad.SourceDrop.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        if let previousDirectory { setenv("CLASSIC_LAUNCHPAD_DATA_DIR", previousDirectory, 1) }
        else { unsetenv("CLASSIC_LAUNCHPAD_DATA_DIR") }
    }
    let store = LauncherStore(automaticallyRefresh: false)
    store.apps = (0..<55).map {
        LauncherApp(id: "source-\($0)", name: "App \($0)", url: URL(fileURLWithPath: "/source-fixtures/\($0).app"),
                    bundleIdentifier: "test.source.\($0)")
    }
    let loose = store.apps.map { LauncherItem(id: $0.id, name: $0.name, appIDs: [$0.id], isFolder: false) }
    let folder = LauncherItem(id: "source-folder", name: "Folder", appIDs: Array(loose.prefix(12)).map(\.id), isFolder: true)
    let original = [folder] + Array(loose.dropFirst(12))
    store.items = original
    store.moveItem("source-20", before: "source-21")
    let session = LauncherSession(preferences: preferences)
    session.isPresented = true
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1020, height: 710),
                          styleMask: .borderless, backing: .buffered, defer: false)
    let host = NSHostingView(rootView: LauncherView(store: store, session: session))
    window.contentView = host
    defer { session.endDrag(); session.isPresented = false; window.contentView = nil }
    func surfaces(in view: NSView) -> [LauncherIconInteractionView] {
        (view as? LauncherIconInteractionView).map { [$0] } ?? view.subviews.flatMap { surfaces(in: $0) }
    }
    func receiver(in view: NSView) -> LauncherDragDestinationView? {
        (view as? LauncherDragDestinationView) ?? view.subviews.lazy.compactMap { receiver(in: $0) }.first
    }
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
    }
    host.layoutSubtreeIfNeeded()
    try await settle()
    guard let destination = receiver(in: host) else { throw Failure(description: "native receiver is mounted") }

    // Cover an app, a whole folder, and a folder member. The source cell must
    // consume its own drop instead of falling through to page-end insertion.
    for (id, folderID) in [("source-20", Optional<String>.none), ("source-50", nil), (folder.id, nil), ("source-5", folder.id)] {
        session.page = id == "source-50" ? 1 : 0
        try await settle()
        session.rootPaging.viewport?.completeTracking(at: session.page)
        try await settle()
        if folderID != nil { session.activate(folder, store: store); try await settle() }
        guard let source = surfaces(in: host).first(where: { $0.itemID == id && $0.sourceFolderID == folderID }) else {
            throw Failure(description: "source surface is mounted for \(id)")
        }
        let payload = LauncherDragPayload(itemID: id, folderID: folderID)
        source.onDragStarted(payload)
        try await settle()
        let drag = try LauncherTestDraggingInfo(source: source, payload: payload, window: window)
        let revision = store.layoutRevision
        guard let neighbor = surfaces(in: host).first(where: {
            !$0.itemID.isEmpty && $0.itemID != id && $0.sourceFolderID == folderID && $0.isInteractionEnabled
        }) else { throw Failure(description: "a neighboring destination is mounted") }
        // Stay clear of the folder panel's paging edge when targeting its
        // first member; the left half still previews insertion before it.
        let neighborFraction: CGFloat = folderID == nil ? 0.1 : 0.4
        drag.draggingLocation = neighbor.convert(NSPoint(x: neighbor.bounds.width * neighborFraction, y: 40), to: nil)
        try check(destination.draggingEntered(drag) == .move && session.dropTarget == .item(neighbor.itemID, .before),
                  "\(id) previews insertion at \(neighbor.itemID): target \(String(describing: session.dropTarget)), page \(session.page), point \(drag.draggingLocation)")
        let points = [NSPoint(x: source.bounds.midX + 6, y: 40),
                      NSPoint(x: 2, y: source.bounds.midY),
                      NSPoint(x: source.bounds.maxX - 2, y: source.bounds.midY),
                      NSPoint(x: source.bounds.midX, y: source.bounds.maxY - 2)]
        for point in points {
            drag.draggingLocation = source.convert(point, to: nil)
            session.dropTarget = .item("stale-target", .merge)
            try check(destination.draggingUpdated(drag) == .move && destination.prepareForDragOperation(drag),
                      "the original cell accepts a drop at \(point)")
            try check(destination.performDragOperation(drag) && store.items == original && store.layoutRevision == revision,
                      "dropping \(id) at \(point) in its original cell preserves order without saving")
            try check(session.dropTarget == nil && session.dragPageDirection == nil,
                      "a source-cell drop clears stale insertion and merge feedback")
        }
        try check(source.canDrop(payload) && source.draggingEntered(drag) == .move &&
                  source.prepareForDragOperation(drag) && source.performDragOperation(drag),
                  "the tile's native fallback also consumes its own drop")
        try check(store.items == original && store.layoutRevision == revision && session.dropTarget == nil,
                  "the tile fallback preserves order and never previews merging with itself")
        source.onDragEnded()
        try await settle()
    }
    try check(LauncherStore(automaticallyRefresh: false).items == original,
              "source-cell drops preserve the saved layout")
    print("PASS: native source-cell drops preserve app, folder, and member positions without layout writes or self-merge feedback")
}

/// Supplies the same public AppKit destination contract as a native session;
/// unlike calling tile closures this exercises payload decoding and routing.
final class LauncherTestDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation = NSPoint.zero
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(source: LauncherIconInteractionView, payload: LauncherDragPayload, window: NSWindow) throws {
        super.init()
        draggingSource = source
        draggingDestinationWindow = window
        draggingPasteboard.setData(try JSONEncoder().encode(payload), forType: LauncherIconInteractionView.pasteboardType)
    }

    deinit { draggingPasteboard.releaseGlobally() }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
