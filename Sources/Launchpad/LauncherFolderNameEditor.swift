import AppKit
import SwiftUI

/// Edits a folder title in place; the parent owns and commits the draft name.
struct LauncherFolderNameEditor: View {
    @Binding private var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    @State private var fieldFocused = false

    init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _text = text
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        FolderNameField(text: $text, isFocused: $fieldFocused, onCommit: onCommit, onCancel: onCancel)
            .frame(height: 34)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.white.opacity(fieldFocused ? 0.09 : 0.05),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(fieldFocused ? .white.opacity(0.48) : .white.opacity(0.18), lineWidth: 1)
            }
    }
}

/// Native editing preserves selection, input methods, and standard text shortcuts.
private struct FolderNameField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RenameTextField {
        let field = RenameTextField(string: text)
        field.identifier = NSUserInterfaceItemIdentifier("folderName")
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 28, weight: .regular)
        field.alignment = .center
        field.textColor = .white
        field.backgroundColor = .clear
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.placeholderString = "文件夹"
        field.setAccessibilityLabel("文件夹名称")
        field.setAccessibilityPlaceholderValue("输入文件夹名称")
        field.didAttach = { [weak field, weak coordinator = context.coordinator] in
            DispatchQueue.main.async {
                guard let field, field.window != nil, let coordinator,
                      !coordinator.hasFocusedInitially, !coordinator.hasFinished else { return }
                coordinator.hasFocusedInitially = true
                // selectText both installs the field editor and selects its text.
                // Making the field first responder separately can restart editing.
                field.selectText(nil)
            }
        }
        return field
    }

    func updateNSView(_ field: RenameTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ field: RenameTextField, coordinator: Coordinator) {
        coordinator.hasFinished = true
        field.delegate = nil
        field.didAttach = nil
    }

    final class RenameTextField: NSTextField {
        var didAttach: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { didAttach?() }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FolderNameField
        var hasFocusedInitially = false
        var hasFinished = false

        init(_ parent: FolderNameField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.isFocused = true }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
            // The parent commits on outside clicks or launcher focus changes.
            // Native field-editor setup can also send this notification, so it
            // must not close the inline editor by itself.
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Escape first belongs to the input method while composing.
                if textView.hasMarkedText() { return false }
                finish(cancelled: true)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if textView.hasMarkedText() { return false }
                if let field = control as? NSTextField { parent.text = field.stringValue }
                finish(cancelled: false)
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) ||
                commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                if textView.hasMarkedText() { return false }
                if let field = control as? NSTextField { parent.text = field.stringValue }
                finish(cancelled: false)
                return true
            }
            return false
        }

        private func finish(cancelled: Bool) {
            guard !hasFinished else { return }
            hasFinished = true
            if cancelled { parent.onCancel() } else { parent.onCommit() }
        }
    }
}
