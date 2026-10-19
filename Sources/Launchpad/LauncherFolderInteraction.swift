import AppKit
import SwiftUI

/// Reports the visible panel in AppKit screen coordinates used by native drags.
struct LauncherFolderFrameReader: NSViewRepresentable {
    let onFrame: (NSRect) -> Void

    func makeNSView(context: Context) -> FrameView {
        FrameView()
    }

    func updateNSView(_ view: FrameView, context: Context) {
        view.onFrame = onFrame
        view.reportFrame()
    }

    final class FrameView: NSView {
        var onFrame: (NSRect) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); reportFrame() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reportFrame() }

        func reportFrame() {
            guard let window, !bounds.isEmpty else { return }
            onFrame(window.convertToScreen(convert(bounds, to: nil)))
        }
    }
}
