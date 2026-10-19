import AppKit

@MainActor
final class LauncherShortcutRecorder: NSButton {
    private(set) var shortcut: LauncherShortcut
    private(set) var isRecording = false
    var onMessage: (String?) -> Void = { _ in }
    override var acceptsFirstResponder: Bool { true }

    init(shortcut: LauncherShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        target = self
        action = #selector(startRecording)
        setAccessibilityLabel("打开启动台的快捷键")
        setAccessibilityHelp("点击后按下新的组合键。按 Esc 取消录入。")
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9)
        let focused = window?.firstResponder === self
        if isRecording || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        } else {
            NSColor.windowBackgroundColor.setFill()
        }
        shape.fill()
        (isRecording ? NSColor.controlAccentColor : focused ? NSColor.controlAccentColor.withAlphaComponent(0.55) : NSColor.separatorColor).setStroke()
        shape.lineWidth = isRecording ? 2 : 1
        shape.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        var textFont = isRecording ? NSFont.systemFont(ofSize: 13, weight: .medium) : (font ?? .monospacedSystemFont(ofSize: 18, weight: .medium))
        let textWidth = (title as NSString).size(withAttributes: [.font: textFont]).width
        let availableWidth = max(1, bounds.width - 20)
        if !isRecording, textWidth > availableWidth {
            textFont = .monospacedSystemFont(ofSize: max(10, textFont.pointSize * availableWidth / textWidth), weight: .medium)
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: textFont,
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        let height = text.size().height
        text.draw(in: NSRect(x: 8, y: (bounds.height - height) / 2, width: bounds.width - 16, height: height))
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    @objc func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        onMessage(nil)
        updateTitle()
    }

    func record(_ shortcut: LauncherShortcut) {
        guard shortcut.isValid else {
            onMessage("请加上 ⌘、⌥ 或 ⌃，也可以单独使用 F1–F20。")
            return
        }
        self.shortcut = shortcut
        isRecording = false
        onMessage(nil)
        updateTitle()
    }

    /// A local event monitor sees Command combinations before menu equivalents.
    func handle(_ event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return false }
        if event.keyCode == 53 {
            isRecording = false
            onMessage(nil)
            updateTitle()
            return true
        }
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            isRecording = false
            onMessage(nil)
            updateTitle()
            return false // Preserve normal Tab / Shift-Tab focus navigation.
        }
        if !event.isARepeat { record(LauncherShortcut(event: event)) }
        return true
    }

    private func updateTitle() {
        title = isRecording ? "按下新的组合键" : shortcut.displayName
        setAccessibilityValue(isRecording ? "正在录入快捷键" : shortcut.displayName)
        needsDisplay = true
    }
}

/// Keep the content opaque even when macOS uses translucent system alerts.
private final class ShortcutPanelBackground: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

@MainActor
final class LauncherShortcutEditor: NSObject, NSWindowDelegate {
    let recorder: LauncherShortcutRecorder
    private let message = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复默认", target: nil, action: nil)
    private let fieldTitle = NSTextField(labelWithString: "当前快捷键")
    private let fieldHint = NSTextField(labelWithString: "点击右侧按键修改")
    private var saveAction: ((LauncherShortcut) -> Bool)?
    private let originalShortcut: LauncherShortcut

    init(shortcut: LauncherShortcut) {
        originalShortcut = shortcut
        recorder = LauncherShortcutRecorder(shortcut: shortcut)
        super.init()
    }

    func run(save: @escaping (LauncherShortcut) -> Bool) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 298),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "启动台"
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.delegate = self
        panel.contentView = makeContent()
        panel.initialFirstResponder = recorder
        saveAction = save
        recorder.onMessage = { [weak self] error in self?.updateState(error: error) }
        updateState()

        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel, panel.isKeyWindow else { return event }
            return self.recorder.handle(event) ? nil : event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            recorder.onMessage = { _ in }
            saveAction = nil
            panel.orderOut(nil)
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
    }

    private func makeContent() -> NSView {
        let content = ShortcutPanelBackground(frame: NSRect(x: 0, y: 0, width: 460, height: 298))
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "打开快捷键")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "随时显示或收起启动台")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let card = NSBox()
        card.boxType = .custom
        card.titlePosition = .noTitle
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.cornerRadius = 12
        card.contentViewMargins = .zero
        let cardContent = card.contentView!
        fieldTitle.font = .systemFont(ofSize: 13, weight: .medium)
        fieldHint.font = .systemFont(ofSize: 11)
        fieldHint.textColor = .secondaryLabelColor
        for view in [fieldTitle, fieldHint, recorder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cardContent.addSubview(view)
        }
        let help = NSTextField(wrappingLabelWithString: "支持 ⌘、⌥、⌃ 组合键或 F1–F20。\n部分键盘使用功能键时需要同时按 Fn。")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 11)
        message.maximumNumberOfLines = 2

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEditing))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveShortcut)
        restoreButton.bezelStyle = .rounded
        restoreButton.isBordered = false
        restoreButton.contentTintColor = .controlAccentColor
        restoreButton.font = .systemFont(ofSize: 12)
        restoreButton.target = self
        restoreButton.action = #selector(restoreDefault)
        restoreButton.toolTip = "恢复为 ⌥⌘L，保存后生效"

        for view in [icon, title, subtitle, card, help, message, restoreButton, cancel, saveButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            icon.widthAnchor.constraint(equalToConstant: 40), icon.heightAnchor.constraint(equalToConstant: 40),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: icon.topAnchor, constant: -1),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            card.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 20),
            card.heightAnchor.constraint(equalToConstant: 76),
            fieldTitle.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor, constant: 16),
            fieldTitle.topAnchor.constraint(equalTo: cardContent.topAnchor, constant: 18),
            fieldHint.leadingAnchor.constraint(equalTo: fieldTitle.leadingAnchor),
            fieldHint.topAnchor.constraint(equalTo: fieldTitle.bottomAnchor, constant: 4),
            recorder.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor, constant: -14),
            recorder.centerYAnchor.constraint(equalTo: cardContent.centerYAnchor),
            recorder.leadingAnchor.constraint(greaterThanOrEqualTo: fieldTitle.trailingAnchor, constant: 16),
            recorder.widthAnchor.constraint(equalToConstant: 164),
            recorder.heightAnchor.constraint(equalToConstant: 44),
            help.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 2),
            help.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -2),
            help.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 10),
            help.heightAnchor.constraint(equalToConstant: 30),
            message.leadingAnchor.constraint(equalTo: help.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            message.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 4),
            message.heightAnchor.constraint(equalToConstant: 28),
            restoreButton.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            restoreButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            saveButton.widthAnchor.constraint(equalToConstant: 76),
            saveButton.heightAnchor.constraint(equalToConstant: 32),
            cancel.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            cancel.widthAnchor.constraint(equalToConstant: 76),
            cancel.heightAnchor.constraint(equalTo: saveButton.heightAnchor)
        ])
        return content
    }

    private func updateState(error: String? = nil) {
        fieldTitle.stringValue = recorder.isRecording ? "正在录入" : "当前快捷键"
        fieldHint.stringValue = recorder.isRecording ? "按 Esc 取消录入" : "点击右侧按键修改"
        fieldTitle.textColor = recorder.isRecording ? .controlAccentColor : .labelColor
        saveButton.isEnabled = !recorder.isRecording
        restoreButton.isEnabled = recorder.shortcut != .default || recorder.isRecording
        if let error {
            message.stringValue = error
            message.textColor = .systemRed
        } else {
            message.stringValue = recorder.isRecording ? "按下组合键，或按 Esc 取消录入。" : recorder.shortcut != originalShortcut ? "保存后立即生效，并在下次启动时保留。" : ""
            message.textColor = .secondaryLabelColor
        }
    }

    @objc private func saveShortcut() {
        guard !recorder.isRecording else { return }
        if saveAction?(recorder.shortcut) == true {
            NSApp.stopModal(withCode: .OK)
        } else {
            updateState(error: "此快捷键已被系统或其他应用占用，请换一个组合。原设置未更改。")
        }
    }

    @objc private func cancelEditing() { NSApp.stopModal(withCode: .cancel) }
    @objc private func restoreDefault() { recorder.record(.default) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelEditing()
        return false
    }
}
