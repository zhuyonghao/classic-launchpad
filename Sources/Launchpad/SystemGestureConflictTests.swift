import Foundation

func runSystemGestureConflictTests(in directory: URL) throws {
    final class Preferences: SystemGesturePreferences {
        var values = Dictionary(uniqueKeysWithValues: SystemGesturePreference.conflicts.map { ($0, $0.isBoolean ? 1 : 2) })
        var writes = 0
        var available = true
        func synchronize(_ domain: String) -> Bool { available }
        func value(for preference: SystemGesturePreference) -> Int? { values[preference] }
        func disable(_ preference: SystemGesturePreference) { values[preference] = 0; writes += 1 }
    }
    struct Failure: Error { let message: String }
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    let preferences = Preferences()
    // Preserve absence as well as explicitly enabled values in the backup.
    preferences.values.removeValue(forKey: SystemGesturePreference.conflicts[0])
    let backup = directory.appendingPathComponent("system-gesture-test.plist")
    var reloads = 0
    let manager = SystemGestureConflictManager(preferences: preferences, backupURL: backup) {
        reloads += 1
    }
    try check(try manager.disableConflicts(), "enabled system gestures must be disabled")
    try check(preferences.values.values.allSatisfy { $0 == 0 } && preferences.writes == 6 && reloads == 1,
              "all conflict keys are disabled with one Dock reload")
    let savedData = try Data(contentsOf: backup)
    let saved = try PropertyListDecoder().decode([SystemGestureConflictManager.OriginalPreference].self, from: savedData)
    try check(saved.first?.value == nil && saved[2].value == 2, "backup preserves absent keys and original values")
    try check(try !manager.disableConflicts(), "reopening is idempotent")
    try check(reloads == 1 && preferences.writes == 6, "unchanged settings must not reload Dock or write preferences")

    preferences.values[SystemGesturePreference.conflicts[2]] = 2
    try check(try manager.disableConflicts(), "re-enabled conflicts are suppressed on the next open")
    try check(reloads == 2 && preferences.writes == 7 && (try Data(contentsOf: backup)) == savedData,
              "reapplying retains the original backup and only writes the changed key")

    let blocked = Preferences()
    let blockedURL = directory.appendingPathComponent("not-a-directory")
    try Data().write(to: blockedURL)
    let blockedManager = SystemGestureConflictManager(preferences: blocked, backupURL: blockedURL.appendingPathComponent("backup.plist")) {
        throw Failure(message: "must not restart Dock before backup succeeds")
    }
    do {
        try blockedManager.disableConflicts()
        throw Failure(message: "an unwritable backup must fail")
    } catch is Failure { throw Failure(message: "backup failure was not handled") }
    catch { try check(blocked.writes == 0, "backup failure must leave system preferences untouched") }

    let unavailable = Preferences()
    unavailable.available = false
    do {
        try SystemGestureConflictManager(preferences: unavailable, backupURL: backup).disableConflicts()
        throw Failure(message: "unavailable preferences must fail")
    } catch is SystemGestureConflictManager.Failure {
        try check(unavailable.writes == 0, "synchronization failure must leave preferences untouched")
    }

    // Exercise the real CFPreferences adapter using only an isolated test domain.
    let domain = "com.local.ClassicLaunchpad.gesture-test.\(UUID().uuidString)"
    let target = SystemGesturePreference(domain: domain, key: "pinch", isBoolean: false)
    let native = NativeSystemGesturePreferences()
    defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
    native.disable(target)
    try check(native.synchronize(domain) && native.value(for: target) == 0, "native adapter persists the disabled value")
    print("PASS: automatic gesture suppression, original backup, repeated opens, failures, and isolated native preferences")
}
