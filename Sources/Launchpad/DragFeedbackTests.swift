import AppKit

@MainActor
func runDragFeedbackTests() throws {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    let rootPlacements: [(CGFloat, LauncherDropPlacement)] = [
        (0, .before), (0.2499, .before), (0.25, .merge),
        (0.5, .merge), (0.75, .merge), (0.7501, .after), (1, .after)
    ]
    for (fraction, expected) in rootPlacements {
        try check(LauncherDropPlacement.resolve(horizontalFraction: fraction, inFolder: false) == expected,
                  "root drop placement at \(fraction) matches its preview")
    }
    let folderPlacements: [(CGFloat, LauncherDropPlacement)] = [
        (0, .before), (0.25, .before), (0.5, .before),
        (0.5001, .after), (0.75, .after), (1, .after)
    ]
    for (fraction, expected) in folderPlacements {
        try check(LauncherDropPlacement.resolve(horizontalFraction: fraction, inFolder: true) == expected,
                  "folder drop placement at \(fraction) only reorders members")
    }
    for placement in [LauncherDropPlacement.before, .after, .merge] {
        let target = LauncherDropTarget.item("intended-target", placement)
        try check(target.placement(for: "intended-target") == placement && target.placement(for: "other-target") == nil,
                  "item drop feedback is limited to its intended target")
    }
    try check(LauncherDropTarget.slot(3).placement(for: "intended-target") == nil,
              "empty-slot feedback cannot highlight an application")

    let suiteName = "ClassicLaunchpad.DragFeedback.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suiteName)!
    defer { preferences.removePersistentDomain(forName: suiteName) }
    preferences.set(2, forKey: "lastLauncherPage")
    let session = LauncherSession(preferences: preferences)
    var beginExports: [Bool] = []
    var endCount = 0
    var dismissCount = 0
    session.dragDidBegin = { beginExports.append($0) }
    session.dragDidEnd = { endCount += 1 }
    session.dismiss = { dismissCount += 1 }

    session.dropTarget = .item("stale-target", .merge)
    session.dragPageDirection = 1
    session.endDrag()
    try check(session.dropTarget == nil && session.dragPageDirection == nil && endCount == 0,
              "clearing stale feedback does not invent a native drag-end callback")

    session.selectedID = "selected-app"
    session.dropTarget = .slot(4)
    session.dragPageDirection = -1
    let payload = LauncherDragPayload(itemID: "dragged-app", folderID: "source-folder")
    session.beginDrag(payload, exportsApplication: true)
    try check(session.draggingID == payload.itemID && session.dragFolderID == payload.folderID &&
              session.selectedID == nil && session.dropTarget == nil && session.dragPageDirection == nil,
              "beginning a native drag captures its source and clears old feedback")
    try check(beginExports == [true] && endCount == 0,
              "an application drag begins its lifecycle exactly once")

    session.dropTarget = .item("target-app", .after)
    session.dragPageDirection = 1
    session.endDrag()
    session.endDrag()
    try check(session.draggingID == nil && session.dragFolderID == nil &&
              session.dropTarget == nil && session.dragPageDirection == nil && endCount == 1,
              "ending a native drag clears feedback and invokes its callback only once")

    session.beginDrag(LauncherDragPayload(itemID: "dragged-folder", folderID: nil), exportsApplication: false)
    session.dropTarget = .slot(7)
    session.dragPageDirection = -1
    session.editingFolderID = "edited-folder"
    session.folderID = "opened-folder"
    session.query = "search draft"
    session.selectedID = "selected-app"
    session.page = 7
    session.restorePresentation()
    session.restorePresentation()
    try check(beginExports == [true, false] && endCount == 2,
              "restoring presentation ends an active folder drag exactly once")
    try check(session.draggingID == nil && session.dragFolderID == nil && session.dropTarget == nil &&
              session.dragPageDirection == nil && session.editingFolderID == nil && session.folderID == nil &&
              session.query.isEmpty && session.selectedID == nil && session.page == 2,
              "restoring presentation clears editing and dragging while restoring the remembered page")

    session.folderID = "opened-folder"
    session.editingFolderID = "opened-folder"
    session.selectedID = "folder-member"
    session.page = 1
    session.escape()
    try check(session.editingFolderID == nil && session.folderID == "opened-folder" &&
              session.selectedID == "folder-member" && session.page == 1 && dismissCount == 0,
              "Escape first cancels renaming while preserving the open folder")
    session.escape()
    try check(session.folderID == nil && session.page == 2 && session.selectedID == nil && dismissCount == 0,
              "a subsequent Escape closes the folder and restores its home page")

    print("PASS: drop placement boundaries, target isolation, native drag lifecycle, rename reset, and Escape ordering")
}
