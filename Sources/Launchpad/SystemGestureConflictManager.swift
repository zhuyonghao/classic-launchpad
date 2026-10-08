import Foundation
import CoreFoundation

struct SystemGesturePreference: Codable, Hashable {
    let domain: String
    let key: String
    let isBoolean: Bool

    static let conflicts: [Self] = [
        .init(domain: "com.apple.dock", key: "showLaunchpadGestureEnabled", isBoolean: true),
        .init(domain: "com.apple.dock", key: "showDesktopGestureEnabled", isBoolean: true),
        .init(domain: "com.apple.AppleMultitouchTrackpad", key: "TrackpadFourFingerPinchGesture", isBoolean: false),
        .init(domain: "com.apple.AppleMultitouchTrackpad", key: "TrackpadFiveFingerPinchGesture", isBoolean: false),
        .init(domain: "com.apple.driver.AppleBluetoothMultitouch.trackpad", key: "TrackpadFourFingerPinchGesture", isBoolean: false),
        .init(domain: "com.apple.driver.AppleBluetoothMultitouch.trackpad", key: "TrackpadFiveFingerPinchGesture", isBoolean: false)
    ]
}

protocol SystemGesturePreferences {
    func synchronize(_ domain: String) -> Bool
    func value(for preference: SystemGesturePreference) -> Int?
    func disable(_ preference: SystemGesturePreference)
}

struct NativeSystemGesturePreferences: SystemGesturePreferences {
    func synchronize(_ domain: String) -> Bool { CFPreferencesAppSynchronize(domain as CFString) }

    func value(for preference: SystemGesturePreference) -> Int? {
        (CFPreferencesCopyAppValue(preference.key as CFString, preference.domain as CFString) as? NSNumber)?.intValue
    }

    func disable(_ preference: SystemGesturePreference) {
        let value: NSNumber = preference.isBoolean ? NSNumber(value: false) : NSNumber(value: 0)
        CFPreferencesSetAppValue(preference.key as CFString, value, preference.domain as CFString)
    }
}

/// Run on the serial conflict-check worker, never in UI or smoke-test setup.
final class SystemGestureConflictManager {
    struct OriginalPreference: Codable, Equatable {
        let preference: SystemGesturePreference
        // nil means the key was absent and the system used its default.
        let value: Int?
    }

    private let preferences: SystemGesturePreferences
    let backupURL: URL
    private let reloadDock: () throws -> Void

    init(preferences: SystemGesturePreferences = NativeSystemGesturePreferences(),
         backupURL: URL? = nil, reloadDock: @escaping () throws -> Void = SystemGestureConflictManager.reloadDock) {
        self.preferences = preferences
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.backupURL = backupURL ?? support.appendingPathComponent("com.local.ClassicLaunchpad/system-gestures-before-disable.plist")
        self.reloadDock = reloadDock
    }

    @discardableResult
    func disableConflicts() throws -> Bool {
        let targets = SystemGesturePreference.conflicts
        let domains = Set(targets.map(\.domain))
        for domain in domains {
            guard preferences.synchronize(domain) else { throw Failure.preferencesUnavailable }
        }
        let originals = targets.map { OriginalPreference(preference: $0, value: preferences.value(for: $0)) }
        let changed = originals.filter { $0.value != 0 }.map(\.preference)
        guard !changed.isEmpty else { return false }

        // Save before mutation; subsequent launches never overwrite the original values.
        if FileManager.default.fileExists(atPath: backupURL.path) {
            let saved = try PropertyListDecoder().decode([OriginalPreference].self, from: Data(contentsOf: backupURL))
            guard Set(saved.map(\.preference)) == Set(targets) else { throw Failure.invalidBackup }
        } else {
            try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListEncoder().encode(originals).write(to: backupURL, options: .atomic)
        }

        for target in changed { preferences.disable(target) }
        for domain in Set(changed.map(\.domain)) {
            guard preferences.synchronize(domain) else { throw Failure.preferencesUnavailable }
        }
        guard targets.allSatisfy({ preferences.value(for: $0) == 0 }) else { throw Failure.preferencesUnavailable }
        try reloadDock()
        return true
    }

    private static func reloadDock() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.dockReloadFailed }
    }

    enum Failure: LocalizedError {
        case preferencesUnavailable, invalidBackup, dockReloadFailed
        var errorDescription: String? {
            switch self {
            case .preferencesUnavailable: return "无法关闭系统的重复手势，请在系统设置的触控板手势中检查。"
            case .invalidBackup: return "系统手势备份无法验证，未修改系统设置。"
            case .dockReloadFailed: return "系统重复手势已关闭，但 Dock 未能重载；下次登录后生效。"
            }
        }
    }
}
