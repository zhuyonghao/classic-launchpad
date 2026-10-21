import AppKit
import SwiftUI

@MainActor
func runFolderHoverTests() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folder-hover-\(UUID().uuidString)")
    let previousDirectory = ProcessInfo.processInfo.environment["CLASSIC_LAUNCHPAD_DATA_DIR"]
    setenv("CLASSIC_LAUNCHPAD_DATA_DIR", directory.path, 1)
    let suite = "ClassicLaunchpad.FolderHover.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        if let previousDirectory { setenv("CLASSIC_LAUNCHPAD_DATA_DIR", previousDirectory, 1) }
        else { unsetenv("CLASSIC_LAUNCHPAD_DATA_DIR") }
    }
    let store = LauncherStore(automaticallyRefresh: false)
    store.apps = (0..<80).map {
        LauncherApp(id: "hover-\($0)", name: "App \($0)", url: URL(fileURLWithPath: "/hover-fixtures/\($0).app"),
                    bundleIdentifier: "test.hover.\($0)")
    }
    let loose = store.apps.map { LauncherItem(id: $0.id, name: $0.name, appIDs: [$0.id], isFolder: false) }
    let first = LauncherItem(id: "first-folder", name: "First", appIDs: ["hover-0", "hover-1"], isFolder: true)
    let second = LauncherItem(id: "second-folder", name: "Second", appIDs: Array(loose[2..<40]).map(\.id), isFolder: true)
    let original = [first, second] + Array(loose.dropFirst(40))
    store.items = original
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
    func settle(_ milliseconds: Int = 100) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
        host.layoutSubtreeIfNeeded()
    }
    func surface(_ id: String, folder: String? = nil) throws -> LauncherIconInteractionView {
        guard let view = surfaces(in: host).first(where: { $0.itemID == id && $0.sourceFolderID == folder }) else {
            throw Failure(description: "missing native surface \(id) in \(folder ?? "root")")
        }
        return view
    }
    func waitForFolder(_ id: String) async throws {
        let deadline = Date().addingTimeInterval(2)
        while session.folderID != id && Date() < deadline { try await settle() }
        try await settle()
        try check(session.folderID == id && session.page == 0, "hover opens the intended folder on its first page")
    }
    host.layoutSubtreeIfNeeded()
    try await settle()
    let rootSource = try surface("hover-40")
    let rootPayload = LauncherDragPayload(itemID: "hover-40", folderID: nil)
    rootSource.onDragStarted(rootPayload)
    try surface(first.id).onDropLocationChanged(0.1)
    try await settle(650)
    try check(session.folderID == nil, "insertion beside a folder never spring-opens it")
    try surface(first.id).onDropLocationChanged(0.5)
    try await settle(200)
    try check(session.folderID == nil, "a short hover does not open a folder")
    try surface(first.id).onDropLocationChanged(nil)
    try await settle(450)
    try check(session.folderID == nil, "leaving before the dwell time cancels opening")
    try surface(first.id).onDropLocationChanged(0.5)
    try await settle(300)
    try surface(second.id).onDropLocationChanged(0.5)
    try await settle(300)
    try check(session.folderID == nil, "changing hover targets starts a fresh dwell")
    try await waitForFolder(second.id)
    try check(store.items == original && surfaces(in: host).contains(where: { $0 === rootSource }),
              "spring-opening preserves layout and the actual root native drag source")
    try check(!rootSource.canDrop(LauncherDragPayload(itemID: "hover-41", folderID: nil)),
              "the hidden root grid rejects destinations while a folder is open")
    let panel = session.folderPanelFrame
    session.moveDrag(to: NSPoint(x: panel.midX, y: panel.maxY + 60))
    try check(session.folderID == second.id, "a pointer outside the newly opened panel can travel into it")
    session.moveDrag(to: NSPoint(x: panel.midX, y: panel.midY))
    session.moveDrag(to: NSPoint(x: panel.midX, y: panel.maxY + 60))
    try await settle()
    try check(session.folderID == nil && session.draggingID == rootPayload.itemID && store.items == original,
              "leaving after entering a spring-open panel returns to root without committing membership")
    try surface(first.id).onDropLocationChanged(0.5)
    try await settle(200)
    rootSource.onDragEnded()
    try await settle(450)
    try check(session.folderID == nil && store.items == original, "ending a drag cancels its pending folder opening")

    let folderSource = try surface(first.id)
    folderSource.onDragStarted(LauncherDragPayload(itemID: first.id, folderID: nil))
    try surface(second.id).onDropLocationChanged(0.5)
    try await settle(650)
    try check(session.folderID == nil, "dragging a whole folder preserves the existing merge interaction")
    folderSource.onDragEnded()

    // Place incoming applications before/after members, in an empty slot, and
    // at the current page's end. Each move is committed only at the final drop.
    for (offset, fraction) in [CGFloat(0.1), 0.9].enumerated() {
        let id = "hover-\(40 + offset)"
        let source = try surface(id)
        let payload = LauncherDragPayload(itemID: id, folderID: nil)
        source.onDragStarted(payload)
        try surface(second.id).onDropLocationChanged(0.5)
        try await waitForFolder(second.id)
        let target = try surface("hover-3", folder: second.id)
        let revision = store.layoutRevision
        try check(target.canDrop(payload) && target.onDrop(payload, fraction), "an incoming app drops on a folder member")
        let members = store.items.first(where: { $0.id == second.id })!.appIDs
        let targetIndex = members.firstIndex(of: "hover-3")!
        try check(members[targetIndex + (fraction < 0.5 ? -1 : 1)] == id && store.layoutRevision == revision + 1,
                  "incoming placement follows the indicated side and updates the layout atomically")
        source.onDragEnded()
        session.escape()
        try await settle()
    }
    let slotSource = try surface("hover-42")
    let slotPayload = LauncherDragPayload(itemID: "hover-42", folderID: nil)
    slotSource.onDragStarted(slotPayload)
    try surface(second.id).onDropLocationChanged(0.5)
    try await waitForFolder(second.id)
    session.page = 1
    try await settle()
    session.folderPaging.viewport?.completeTracking(at: 1)
    guard let slot = surfaces(in: host).first(where: { $0.itemID.isEmpty && $0.sourceFolderID == second.id && $0.canDrop(slotPayload) }) else {
        throw Failure(description: "the second page exposes native empty-slot destinations for incoming apps")
    }
    try check(slot.onDrop(slotPayload, 0.5) && store.items.first(where: { $0.id == second.id })!.appIDs.last == slotPayload.itemID,
              "an incoming app can be placed in a later page's empty slot")
    slotSource.onDragEnded()
    session.escape()
    try await settle()

    session.activate(first, store: store)
    try await settle()
    let memberSource = try surface("hover-0", folder: first.id)
    let memberPayload = LauncherDragPayload(itemID: "hover-0", folderID: first.id)
    memberSource.onDragStarted(memberPayload)
    session.moveDrag(to: NSPoint(x: session.folderPanelFrame.midX, y: session.folderPanelFrame.maxY + 60))
    try await settle()
    try surface(second.id).onDropLocationChanged(0.5)
    try await waitForFolder(second.id)
    try check(surfaces(in: host).contains(where: { $0 === memberSource }) &&
              !memberSource.canDrop(LauncherDragPayload(itemID: "hover-1", folderID: first.id)),
              "opening another folder retains the original native source and disables its hidden destinations")
    let destinationPanel = session.folderPanelFrame
    session.moveDrag(to: NSPoint(x: destinationPanel.maxX - 8, y: destinationPanel.midY))
    let deadline = Date().addingTimeInterval(2)
    while session.page != 1 && Date() < deadline { try await settle() }
    try check(session.page == 1, "the original native source still drives edge paging in the destination folder")
    session.folderPaging.viewport?.completeTracking(at: 1)
    session.moveDrag(to: NSPoint(x: destinationPanel.midX, y: destinationPanel.midY))
    try check(LauncherDropActions.onPageBackground(memberPayload, folderID: second.id, store: store, session: session),
              "a source folder member can drop in the destination page margin")
    try await settle()
    try check(store.items.first == loose[1] && store.items.first(where: { $0.id == second.id })!.appIDs.last == memberPayload.itemID &&
              surfaces(in: host).contains(where: { $0 === memberSource }),
              "transfer collapses the source folder in place while retaining native completion callbacks")
    memberSource.onDragEnded()
    let saved = store.items
    for invalid in [LauncherDragPayload(itemID: first.id, folderID: nil),
                    LauncherDragPayload(itemID: "missing", folderID: nil),
                    LauncherDragPayload(itemID: "hover-43", folderID: first.id)] {
        try check(!LauncherDropActions.onSlot(invalid, index: 0, store: store, session: session) && store.items == saved,
                  "stale or invalid incoming payloads cannot alter folder membership")
    }
    let ids = store.items.flatMap(\.appIDs)
    try check(ids.count == 80 && Set(ids).count == 80 && LauncherStore(automaticallyRefresh: false).items == store.items,
              "hover transfers preserve every app exactly once and persist the selected order")
    print("PASS: folder hover dwell/cancellation, target switching, native root/source retention, incoming side/slot/margin placement, destination paging, atomic persistence, and invalid payloads")
}
