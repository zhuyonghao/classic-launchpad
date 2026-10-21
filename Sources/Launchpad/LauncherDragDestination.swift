import AppKit
import SwiftUI

/// One native destination survives the entire drag. AppKit must not have to
/// rediscover newly revealed sibling destinations when a folder closes.
struct LauncherDragDestination: NSViewRepresentable {
    let store: LauncherStore
    let session: LauncherSession

    func makeNSView(context: Context) -> LauncherDragDestinationView {
        let view = LauncherDragDestinationView()
        view.store = store
        view.session = session
        return view
    }

    func updateNSView(_ view: LauncherDragDestinationView, context: Context) {
        if session.draggingID == nil { view.clearTarget() }
    }
}

final class LauncherDragDestinationView: NSView {
    weak var store: LauncherStore?
    weak var session: LauncherSession?
    private weak var target: LauncherIconInteractionView?

    init() {
        super.init(frame: .zero)
        registerForDraggedTypes([LauncherIconInteractionView.pasteboardType])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard session?.draggingID != nil else { return nil }
        return super.hitTest(point)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        (sender.draggingSource as? LauncherIconInteractionView)?.debug("persistent destination entered")
        return updateDestination(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDestination(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearTarget()
        session?.dragPageDirection = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !updateDestination(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !updateDestination(sender).isEmpty,
              let payload = LauncherIconInteractionView.internalPayload(from: sender),
              let store, let session else { return false }
        let accepted: Bool
        if let target {
            accepted = target.onDrop(payload, fraction(at: sender.draggingLocation, in: target))
        } else {
            let point = screenPoint(sender)
            let folder = session.folderPanelFrame.contains(point) ? session.folderID : nil
            accepted = LauncherDropActions.onPageBackground(payload, folderID: folder, store: store, session: session)
        }
        (sender.draggingSource as? LauncherIconInteractionView)?.debug("persistent destination drop (accepted \(accepted))")
        clearTarget()
        return accepted
    }

    func clearTarget() {
        target?.setDropFeedback(nil)
        target = nil
    }

    private func updateDestination(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let session, let store,
              let payload = LauncherIconInteractionView.internalPayload(from: sender),
              session.draggingID == payload.itemID, session.dragFolderID == payload.folderID,
              !session.isSelectingApps, session.editingFolderID == nil,
              session.query.isEmpty || session.folderID != nil else {
            clearTarget()
            return []
        }
        let point = screenPoint(sender)
        session.moveDrag(to: point)
        let direction: Int?
        if session.folderID != nil {
            direction = LauncherFolderDragEdge.direction(at: point, in: session.folderPanelFrame)
        } else {
            direction = LauncherFolderDragEdge.direction(at: point, in: window?.convertToScreen(convert(bounds, to: nil)) ?? .zero)
        }
        if let direction {
            clearTarget()
            if session.dropTarget != nil { session.dropTarget = nil }
            if session.dragPageDirection != direction { session.dragPageDirection = direction }
            return .move
        }
        if session.dragPageDirection != nil { session.dragPageDirection = nil }
        let next = window?.contentView.flatMap { findTarget(in: $0, point: sender.draggingLocation, payload: payload) }
        if target !== next {
            clearTarget()
            target = next
            (sender.draggingSource as? LauncherIconInteractionView)?.debug("persistent target: \(next?.itemName ?? "page background")")
        }
        if let target { target.setDropFeedback(fraction(at: sender.draggingLocation, in: target)) }
        // A folder itself can only be sorted/merged on the root grid.
        if session.folderID != nil && !LauncherDropActions.canPlaceApp(payload, store: store) { return [] }
        return .move
    }

    private func screenPoint(_ sender: NSDraggingInfo) -> NSPoint {
        window?.convertPoint(toScreen: sender.draggingLocation) ?? .zero
    }

    private func fraction(at point: NSPoint, in view: LauncherIconInteractionView) -> CGFloat {
        LauncherIconInteractionView.clampedHorizontalFraction(x: view.convert(point, from: nil).x, width: view.bounds.width)
    }

    private func findTarget(in view: NSView, point: NSPoint, payload: LauncherDragPayload) -> LauncherIconInteractionView? {
        if let icon = view as? LauncherIconInteractionView,
           icon.isInteractionEnabled, icon.itemID != payload.itemID, icon.canDrop(payload),
           icon.bounds.contains(icon.convert(point, from: nil)) { return icon }
        for child in view.subviews.reversed() {
            if let icon = findTarget(in: child, point: point, payload: payload) { return icon }
        }
        return nil
    }
}
