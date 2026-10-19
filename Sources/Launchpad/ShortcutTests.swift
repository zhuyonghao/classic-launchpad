import AppKit
import Carbon

@MainActor
func runShortcutTests() throws {
    struct Failure: Error { let message: String }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: "Opening shortcut: \(message)") }
    }
    func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], repeat repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: 0, windowNumber: 0, context: nil, characters: "",
                         charactersIgnoringModifiers: "", isARepeat: repeated, keyCode: code)!
    }

    let suite = "ClassicLaunchpad.ShortcutTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = LauncherShortcutPreferences(preferences: defaults)
    try check(preferences.shortcut == .default && preferences.shortcut.displayName == "⌥⌘L", "default remains compatible")

    let custom = LauncherShortcut(event: event(UInt16(kVK_Space), [.control, .option, .shift, .capsLock, .function]))
    try check(custom.isValid && custom.displayName == "⌃⌥⇧空格", "normalizes Fn / Caps Lock without changing shortcut")
    try check(preferences.save(custom, register: { true }), "accepts an available combination")
    try check(LauncherShortcutPreferences(preferences: defaults).shortcut == custom, "custom key survives restart")

    let savedData = defaults.data(forKey: LauncherShortcutPreferences.storageKey)
    try check(!preferences.save(.default, register: { false }), "reports registration conflicts")
    try check(preferences.shortcut == custom && defaults.data(forKey: LauncherShortcutPreferences.storageKey) == savedData,
              "registration failure preserves both active choice and saved preference")

    var registrationAttempted = false
    let plainLetter = LauncherShortcut(event: event(UInt16(kVK_ANSI_A)))
    try check(!preferences.save(plainLetter, register: { registrationAttempted = true; return true }) && !registrationAttempted,
              "plain typing cannot become a global shortcut")
    try check(!LauncherShortcut(event: event(UInt16(kVK_ANSI_A), [.shift])).isValid, "Shift alone cannot capture typing")
    try check(!LauncherShortcut(keyCode: 999, modifiers: UInt32(cmdKey)).isValid, "rejects unsupported key codes")
    try check(!LauncherShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey) | 0x80000000).isValid,
              "rejects unknown modifier bits")
    try check(LauncherShortcut(event: event(UInt16(kVK_F6), [.function])).isValid, "accepts standalone function keys")
    try check(!LauncherShortcut(event: event(UInt16(kVK_Escape), [.command])).isValid, "Escape stays available for cancellation")

    try check(preferences.save(.default, register: { true }) && LauncherShortcutPreferences(preferences: defaults).shortcut == .default,
              "restoring default persists")
    defaults.set(Data("invalid JSON".utf8), forKey: LauncherShortcutPreferences.storageKey)
    try check(LauncherShortcutPreferences(preferences: defaults).shortcut == .default, "damaged preference falls back to default")
    defaults.set(try JSONEncoder().encode(plainLetter), forKey: LauncherShortcutPreferences.storageKey)
    try check(LauncherShortcutPreferences(preferences: defaults).shortcut == .default, "invalid saved shortcut falls back to default")

    let recorder = LauncherShortcutRecorder(shortcut: .default)
    var error: String?
    recorder.onMessage = { error = $0 }
    recorder.startRecording()
    try check(recorder.handle(event(UInt16(kVK_ANSI_A))) && error != nil && recorder.isRecording,
              "invalid input shows guidance and keeps recording")
    try check(recorder.handle(event(UInt16(kVK_Escape))) && !recorder.isRecording && recorder.shortcut == .default,
              "Escape cancels recording without changing choice")
    recorder.startRecording()
    try check(!recorder.handle(event(UInt16(kVK_Tab))) && !recorder.isRecording, "Tab preserves focus navigation")
    recorder.startRecording()
    try check(recorder.handle(event(UInt16(kVK_ANSI_K), [.command, .option], repeat: true)) && recorder.isRecording,
              "key repeats do not commit a shortcut")
    try check(recorder.handle(event(UInt16(kVK_ANSI_K), [.command, .option])) && !recorder.isRecording
              && recorder.shortcut.displayName == "⌥⌘K" && error == nil, "records Command combinations before menu handling")
    recorder.startRecording()
    recorder.record(.default)
    try check(!recorder.isRecording && recorder.shortcut == .default, "currently registered shortcut can be recorded through its hotkey callback")

    // Briefly reserve uncommon keys without synthesizing any input. Use a
    // second registration to verify real Carbon conflicts and replacement.
    let firstKey = LauncherShortcut(keyCode: UInt32(kVK_F19), modifiers: LauncherShortcut.modifierMask)
    let secondKey = LauncherShortcut(keyCode: UInt32(kVK_F20), modifiers: LauncherShortcut.modifierMask)
    let hotKey = GlobalHotKey(shortcut: firstKey, action: {})
    let blocker = GlobalHotKey(shortcut: secondKey, action: {})
    if hotKey.registered && blocker.registered {
        try check(hotKey.replace(with: firstKey), "saving the current registration is a no-op")
        try check(!hotKey.replace(with: secondKey) && hotKey.registered, "real Carbon conflict preserves registration")
        let duplicate = GlobalHotKey(shortcut: firstKey, action: {})
        try check(!duplicate.registered, "original combination remains reserved after a failed change")
        try check(blocker.replace(with: plainLetter) == false, "invalid replacement leaves existing registration intact")
    } else {
        print("SKIP: native hotkey conflict check (test combinations already reserved or unavailable)")
    }
    print("PASS: opening shortcut recording, validation, persistence, conflict rollback, cancellation, and default reset")
}
