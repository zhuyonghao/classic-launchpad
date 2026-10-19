import AppKit
import Carbon

struct LauncherShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let `default` = LauncherShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey | cmdKey))
    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    private static let functionKeys: Set<UInt32> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ].reduce(into: []) { $0.insert(UInt32($1)) }

    var isValid: Bool {
        guard Self.keyNames[keyCode] != nil, modifiers & ~Self.modifierMask == 0 else { return false }
        return modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 || Self.functionKeys.contains(keyCode)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags
        modifiers = (flags.contains(.control) ? UInt32(controlKey) : 0)
            | (flags.contains(.option) ? UInt32(optionKey) : 0)
            | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
            | (flags.contains(.command) ? UInt32(cmdKey) : 0)
    }

    var displayName: String {
        var name = ""
        if modifiers & UInt32(controlKey) != 0 { name += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { name += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { name += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { name += "⌘" }
        return name + (Self.keyNames[keyCode] ?? "?")
    }

    // Store physical key codes so switching input methods cannot break the key.
    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "−", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "空格", 50: "`", 51: "⌫",
        65: "数字键盘 .", 67: "数字键盘 *", 69: "数字键盘 +", 71: "Clear", 75: "数字键盘 /",
        76: "数字键盘 ↩", 78: "数字键盘 −", 81: "数字键盘 =", 82: "数字键盘 0",
        83: "数字键盘 1", 84: "数字键盘 2", 85: "数字键盘 3", 86: "数字键盘 4", 87: "数字键盘 5",
        88: "数字键盘 6", 89: "数字键盘 7", 91: "数字键盘 8", 92: "数字键盘 9",
        93: "¥", 94: "_", 95: "数字键盘 ,", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up", 117: "⌦",
        118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
}

final class LauncherShortcutPreferences {
    static let storageKey = "openingShortcut"
    private let preferences: UserDefaults
    private(set) var shortcut: LauncherShortcut

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(LauncherShortcut.self, from: data), saved.isValid {
            shortcut = saved
        } else {
            shortcut = .default
        }
    }

    @discardableResult
    func save(_ candidate: LauncherShortcut, register: () -> Bool) -> Bool {
        guard candidate.isValid, let data = try? JSONEncoder().encode(candidate), register() else { return false }
        preferences.set(data, forKey: Self.storageKey)
        shortcut = candidate
        return true
    }
}
