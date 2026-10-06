import AppKit
import SwiftUI

struct LauncherDragPayload: Codable {
    let itemID: String
    let folderID: String?
}

/// A stable native event surface for a SwiftUI tile. AppKit owns the entire mouse
/// gesture, so rebuilding the surrounding SwiftUI grid cannot restart the drag.
struct LauncherIconInteraction: NSViewRepresentable {
    let id: String
    let name: String
    let image: NSImage
    let sourceFolderID: String?
    let onActivate: () -> Void
    let onDragStarted: (LauncherDragPayload) -> Void
    let onDragEnded: () -> Void
    let canDrop: (LauncherDragPayload) -> Bool
    let onDrop: (LauncherDragPayload, CGFloat) -> Bool
    let onTargetChanged: (Bool) -> Void

    func makeNSView(context: Context) -> LauncherIconInteractionView {
        let view = LauncherIconInteractionView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: LauncherIconInteractionView, context: Context) {
        view.itemID = id
        view.itemName = name
        view.dragImage = image
        view.sourceFolderID = sourceFolderID
        view.onActivate = onActivate
        view.onDragStarted = onDragStarted
        view.onDragEnded = onDragEnded
        view.canDrop = canDrop
        view.onDrop = onDrop
        view.onTargetChanged = onTargetChanged
        // Mouse-down state and active drag payload deliberately survive updates.
    }
}

final class LauncherIconInteractionView: NSView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("com.local.ClassicLaunchpad.item")

    var itemID = ""
    var itemName = ""
    var dragImage = NSImage()
    var sourceFolderID: String?
    var onActivate: () -> Void = {}
    var onDragStarted: (LauncherDragPayload) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var canDrop: (LauncherDragPayload) -> Bool = { _ in false }
    var onDrop: (LauncherDragPayload, CGFloat) -> Bool = { _, _ in false }
    var onTargetChanged: (Bool) -> Void = { _ in }

    private var mouseDownEvent: NSEvent?
    private var didDrag = false
    private var activePayload: LauncherDragPayload?
    private var isDropTarget = false
    private static let debugEnabled = ["1", "true", "yes"].contains(
        ProcessInfo.processInfo.environment["CLASSIC_LAUNCHPAD_DRAG_DEBUG"]?.lowercased() ?? ""
    )

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.pasteboardType])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([Self.pasteboardType])
        setAccessibilityElement(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !itemID.isEmpty else { return }
        if event.modifierFlags.contains(.control) {
            mouseDownEvent = nil
            super.rightMouseDown(with: event)
            return
        }
        mouseDownEvent = event
        didDrag = false
        activePayload = nil
        debug("mouseDown (key window \(window?.isKeyWindow ?? false))")
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let mouseDownEvent else { return }
        let distance = hypot(event.locationInWindow.x - mouseDownEvent.locationInWindow.x,
                             event.locationInWindow.y - mouseDownEvent.locationInWindow.y)
        guard distance >= 5 else { return }
        // Mark the gesture before invoking AppKit, which can call back synchronously.
        // Even a failed or cancelled drag must not turn into an application launch.
        didDrag = true
        let payload = LauncherDragPayload(itemID: itemID, folderID: sourceFolderID)
        guard let data = try? JSONEncoder().encode(payload) else {
            debug("payload encoding failed")
            return
        }
        let pasteboardItem = NSPasteboardItem()
        guard pasteboardItem.setData(data, forType: Self.pasteboardType) else {
            debug("pasteboard write failed")
            return
        }
        activePayload = payload
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let point = convert(mouseDownEvent.locationInWindow, from: nil)
        let side: CGFloat = 80
        draggingItem.setDraggingFrame(
            NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
            contents: dragImage
        )
        debug("begin native drag")
        let session = beginDraggingSession(with: [draggingItem], event: mouseDownEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        let shouldActivate = mouseDownEvent != nil && !didDrag && bounds.contains(convert(event.locationInWindow, from: nil))
        debug("mouseUp (has down \(mouseDownEvent != nil), dragged \(didDrag), activate \(shouldActivate))")
        mouseDownEvent = nil
        if shouldActivate {
            debug("activate")
            onActivate()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Let the enclosing SwiftUI tile provide its existing context menu.
        super.rightMouseDown(with: event)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        let operation: NSDragOperation = context == .withinApplication ? .move : []
        debug("source operation (within app \(context == .withinApplication), mask \(operation.rawValue))")
        return operation
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        debug("native drag started")
        if let activePayload { onDragStarted(activePayload) }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        debug("native drag ended (operation \(operation.rawValue))")
        mouseDownEvent = nil
        activePayload = nil
        // Keep didDrag true until the next mouseDown, in case a final mouseUp arrives.
        setDropTarget(false)
        onDragEnded()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = acceptedPayload(from: sender) != nil
        debug("destination entered (accepted \(accepted))")
        setDropTarget(accepted)
        return accepted ? .move : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = acceptedPayload(from: sender) != nil
        setDropTarget(accepted)
        return accepted ? .move : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        debug("destination exited")
        setDropTarget(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptedPayload(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = acceptedPayload(from: sender) else {
            setDropTarget(false)
            return false
        }
        let point = convert(sender.draggingLocation, from: nil)
        let fraction = min(1, max(0, point.x / max(bounds.width, 1)))
        setDropTarget(false)
        let accepted = onDrop(payload, fraction)
        debug("perform drop (fraction \(fraction), accepted \(accepted))")
        return accepted
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setDropTarget(false)
    }

    private func acceptedPayload(from sender: NSDraggingInfo) -> LauncherDragPayload? {
        guard sender.draggingSource is LauncherIconInteractionView,
              sender.draggingSourceOperationMask.contains(.move),
              let data = sender.draggingPasteboard.data(forType: Self.pasteboardType),
              let payload = try? JSONDecoder().decode(LauncherDragPayload.self, from: data),
              payload.itemID != itemID, canDrop(payload) else { return nil }
        return payload
    }

    private func setDropTarget(_ targeted: Bool) {
        guard isDropTarget != targeted else { return }
        isDropTarget = targeted
        onTargetChanged(targeted)
    }

    private func debug(_ message: String) {
        guard Self.debugEnabled else { return }
        if let data = "[Launchpad drag] \(itemName): \(message)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
            if let path = ProcessInfo.processInfo.environment["CLASSIC_LAUNCHPAD_DRAG_LOG"], !path.isEmpty {
                if !FileManager.default.fileExists(atPath: path) {
                    FileManager.default.createFile(atPath: path, contents: nil)
                }
                if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                    defer { try? handle.close() }
                    do {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                    } catch {
                        // Diagnostic output must never interfere with a mouse gesture.
                    }
                }
            }
        }
    }
}
