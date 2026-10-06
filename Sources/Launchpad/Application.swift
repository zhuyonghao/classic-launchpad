import AppKit
import SwiftUI
import Carbon

@main
enum ClassicLaunchpad {
    @MainActor static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--smoke-test") {
            application.setActivationPolicy(.prohibited)
            Task { @MainActor in await runSmokeTests() }
            application.run()
            return
        }
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LauncherSession: ObservableObject {
    @Published var query = ""
    @Published var page = 0
    @Published var folderID: String?
    @Published var selectedID: String?
    @Published var draggingID: String?
    @Published var dragFolderID: String?
    @Published var wallpaper: NSImage?
    @Published var activationID = UUID()
    @Published var showsHint = true
    var columns = 7
    var rows = 5
    var dismiss: () -> Void = {}
    var pageSize: Int { columns * rows }

    func allItems(_ store: LauncherStore) -> [LauncherItem] {
        if let folderID, let folder = store.items.first(where: { $0.id == folderID }) {
            return folder.appIDs.compactMap { id in
                guard let app = store.app(for: id) else { return nil }
                return LauncherItem(id: app.id, name: app.name, appIDs: [app.id], isFolder: false)
            }
        }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return store.items }
        return store.search(query).map { LauncherItem(id: $0.id, name: $0.name, appIDs: [$0.id], isFolder: false) }
    }

    func turnPage(_ delta: Int, store: LauncherStore) {
        let count = max(1, Int(ceil(Double(allItems(store).count) / Double(pageSize))))
        page = max(0, min(count - 1, page + delta))
        selectedID = nil
    }

    func activate(_ item: LauncherItem, store: LauncherStore) {
        if item.isFolder {
            folderID = item.id
            page = 0
            selectedID = nil
        } else if let app = store.app(for: item.appIDs.first ?? item.id) {
            store.launch(app)
        }
    }

    func escape() {
        draggingID = nil
        dragFolderID = nil
        if folderID != nil {
            folderID = nil
            page = 0
            selectedID = nil
        } else if !query.isEmpty {
            query = ""
            selectedID = nil
        } else {
            dismiss()
        }
    }

    func handleKey(_ event: NSEvent, store: LauncherStore) -> Bool {
        // Let the input method finish composing Chinese/Japanese text first.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { escape(); return true }
        if flags.contains(.command) && (event.keyCode == 123 || event.keyCode == 124) {
            turnPage(event.keyCode == 123 ? -1 : 1, store: store)
            return true
        }
        if flags.contains(.command) { return false }
        let items = allItems(store)
        if event.keyCode == 36 || event.keyCode == 76 {
            if let item = items.first(where: { $0.id == selectedID }) ?? items.dropFirst(page * pageSize).first {
                activate(item, store: store)
            }
            return true
        }
        guard [123, 124, 125, 126].contains(event.keyCode), !items.isEmpty else { return false }
        // Left/right remain normal cursor controls while editing a search term.
        if !query.isEmpty && (event.keyCode == 123 || event.keyCode == 124),
           NSApp.keyWindow?.firstResponder is NSTextView { return false }
        let step = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? columns : -columns
        let index: Int
        if let current = items.firstIndex(where: { $0.id == selectedID }) {
            index = max(0, min(items.count - 1, current + step))
        } else {
            index = min(items.count - 1, page * pageSize)
        }
        selectedID = items[index].id
        page = index / pageSize
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let isUITest = ProcessInfo.processInfo.environment["CLASSIC_LAUNCHPAD_UI_TEST"] == "1"
    let store = LauncherStore()
    let session = LauncherSession()
    var window: LauncherWindow!
    var statusItem: NSStatusItem?
    var keyMonitor: Any?
    var scrollMonitor: Any?
    var mouseMonitor: Any?
    var hotKey: GlobalHotKey?
    private var gestureMonitor: TrackpadGestureMonitor?
    private var gestureMenuItems: [NSMenuItem] = []
    private var gestureStatusItems: [NSMenuItem] = []
    private var scrollDistance: CGFloat = 0
    private var lastPageTurn = Date.distantPast
    private var previousPresentation: NSApplication.PresentationOptions?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenus()
        window = LauncherWindow(contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800),
                                styleMask: isUITest ? [.titled, .closable, .resizable] : [.borderless], backing: .buffered, defer: false)
        window.title = isUITest ? "启动台（界面测试）" : "启动台"
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        session.dismiss = { [weak self] in self?.hideLauncher() }
        window.contentView = NSHostingView(rootView: LauncherView(store: store, session: session))
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isKeyWindow, NSApp.modalWindow == nil else { return event }
            if self.session.draggingID != nil { return event }
            // Folder title editing uses standard text-field commands.
            if let field = self.window.firstResponder as? NSTextView,
               (field.delegate as? NSTextField)?.identifier?.rawValue == "folderName" { return event }
            return self.session.handleKey(event, store: self.store) ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // A cancelled AppKit drag may finish outside this window. Clear its state
            // before the next gesture; onDrag sets the state for a fresh session.
            self?.session.draggingID = nil
            self?.session.dragFolderID = nil
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.window.isKeyWindow, NSApp.modalWindow == nil,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            if event.phase == .began { self.scrollDistance = 0 }
            if event.momentumPhase != [] { return nil }
            self.scrollDistance += event.scrollingDeltaX
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 55 : 5
            if abs(self.scrollDistance) > threshold && Date().timeIntervalSince(self.lastPageTurn) > 0.42 {
                self.session.turnPage(self.scrollDistance < 0 ? 1 : -1, store: self.store)
                self.scrollDistance = 0
                self.lastPageTurn = Date()
            }
            return nil
        }
        if !isUITest {
            hotKey = GlobalHotKey { [weak self] in self?.toggleLauncher() }
            if hotKey?.registered != true {
                store.errorMessage = "⌥⌘L 已被其他应用占用。你仍可从程序坞或菜单栏打开启动台。"
            }
            configureTrackpadGestures()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        showLauncher()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            showLauncher()
        }
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        if isUITest { return }
        guard NSApp.modalWindow == nil else { return }
        hideLauncher()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        gestureMonitor?.invalidate()
        restorePresentation()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    @objc func showLauncher() {
        guard window != nil else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
        if let screen {
            let frame = isUITest ? NSRect(x: screen.visibleFrame.midX - 510, y: screen.visibleFrame.midY - 355, width: 1020, height: 710) : screen.frame
            window.setFrame(frame, display: true)
            if let url = NSWorkspace.shared.desktopImageURL(for: screen),
               let wallpaper = NSImage(contentsOf: url) { session.wallpaper = wallpaper }
        }
        session.query = ""
        session.folderID = nil
        session.selectedID = nil
        session.draggingID = nil
        session.page = 0
        session.activationID = UUID()
        if !isUITest {
            if previousPresentation == nil { previousPresentation = NSApp.presentationOptions }
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        store.refresh()
    }

    func hideLauncher() {
        window?.orderOut(nil)
        restorePresentation()
        if NSApp.isActive { NSApp.hide(nil) }
    }

    private func restorePresentation() {
        if let previousPresentation {
            NSApp.presentationOptions = previousPresentation
            self.previousPresentation = nil
        }
    }

    @objc func toggleLauncher() {
        if window?.isVisible == true && NSApp.isActive { hideLauncher() } else { showLauncher() }
    }

    private func configureTrackpadGestures() {
        UserDefaults.standard.register(defaults: ["fourFingerGesturesEnabled": true])
        let monitor = TrackpadGestureMonitor()
        monitor.isSuspended = { [weak self] in
            NSApp.modalWindow != nil || self?.session.draggingID != nil || NSEvent.pressedMouseButtons != 0
        }
        monitor.onGesture = { [weak self] gesture in
            guard let self else { return }
            switch gesture {
            case .pinchIn:
                if self.window?.isVisible != true || !NSApp.isActive { self.showLauncher() }
            case .spreadOut:
                if self.window?.isVisible == true { self.hideLauncher() }
            }
        }
        monitor.onStatusChanged = { [weak self] status in
            for item in self?.gestureStatusItems ?? [] { item.title = status.title }
        }
        gestureMonitor = monitor
        monitor.setEnabled(UserDefaults.standard.bool(forKey: "fourFingerGesturesEnabled"))
        updateGestureMenuState()
    }

    @objc private func toggleTrackpadGestures() {
        guard let gestureMonitor else { return }
        let enabled = !gestureMonitor.isEnabled
        UserDefaults.standard.set(enabled, forKey: "fourFingerGesturesEnabled")
        gestureMonitor.setEnabled(enabled)
        updateGestureMenuState()
    }

    private func updateGestureMenuState() {
        for item in gestureMenuItems { item.state = gestureMonitor?.isEnabled == true ? .on : .off }
    }

    @objc private func showGestureHelp() {
        let alert = NSAlert()
        alert.messageText = "四指触控板手势"
        alert.informativeText = "四指捏合打开启动台，四指张开收起启动台。收起后程序会继续运行，下次仍可用手势打开。\n\n如果同时触发系统界面，请在“系统设置 → 触控板 → 更多手势”中关闭同样使用四指的“启动台/应用”和“显示桌面”（名称因系统版本而异）。\n\n需要内建触控板或 Magic Trackpad。菜单中的状态可查看是否检测到触控板。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func addGestureMenu(to menu: NSMenu) {
        let toggle = menu.addItem(withTitle: "启用四指手势", action: #selector(toggleTrackpadGestures), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !isUITest
        gestureMenuItems.append(toggle)
        let status = menu.addItem(withTitle: isUITest ? "四指手势：测试窗口不监听" : "四指手势：正在连接", action: nil, keyEquivalent: "")
        status.isEnabled = false
        gestureStatusItems.append(status)
        menu.addItem(withTitle: "四指手势使用说明…", action: #selector(showGestureHelp), keyEquivalent: "").target = self
    }

    @objc func screenChanged() {
        if window?.isVisible == true { showLauncher() }
    }

    @objc func refreshApps() { store.refresh() }

    @objc func resetLayout() {
        let alert = NSAlert()
        alert.messageText = "还原启动台布局？"
        alert.informativeText = "自建文件夹和图标排列将被还原。Mac 上的应用不会被修改。"
        alert.addButton(withTitle: "还原布局")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            session.folderID = nil
            session.page = 0
            store.resetLayout()
        }
    }

    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "启动台", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0",
            .credits: NSAttributedString(string: "经典 macOS 15 启动台体验\n\n四指捏合打开 · 四指张开收起\n⌥⌘L 显示 / 隐藏\n方向键选择 · 回车打开 · Esc 返回\n⌘← / ⌘→ 或双指横滑翻页\n拖叠图标创建文件夹，拖至图标两侧重新排列\n\n独立原生应用，与 Apple 无关联。"),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Swift · AppKit · SwiftUI"
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMenus() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于启动台", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "刷新应用", action: #selector(refreshApps), keyEquivalent: "r")
        appMenu.addItem(withTitle: "还原布局…", action: #selector(resetLayout), keyEquivalent: "")
        appMenu.addItem(.separator())
        addGestureMenu(to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏启动台", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出启动台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        for item in appMenu.items where item.action == #selector(showAbout) || item.action == #selector(refreshApps) || item.action == #selector(resetLayout) { item.target = self }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "启动台")
        statusItem?.button?.toolTip = "启动台 · 四指捏合 / ⌥⌘L"
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "显示启动台", action: #selector(showLauncher), keyEquivalent: "l")
        show.keyEquivalentModifierMask = [.option, .command]
        show.target = self
        menu.addItem(.separator())
        addGestureMenu(to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "刷新应用", action: #selector(refreshApps), keyEquivalent: "").target = self
        menu.addItem(withTitle: "还原布局…", action: #selector(resetLayout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "关于启动台", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出启动台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }
}

final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var registered = false

    init(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &eventType, context, &handler)
        guard handlerStatus == noErr else { return }
        let identifier = EventHotKeyID(signature: 0x4C504144, id: 1)
        registered = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | optionKey), identifier,
                                        GetApplicationEventTarget(), 0, &reference) == noErr
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
