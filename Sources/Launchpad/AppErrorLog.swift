import Foundation
import os

enum AppPaths {
    static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLASSIC_LAUNCHPAD_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("com.local.ClassicLaunchpad", isDirectory: true)
    }

    static var errorLogURL: URL {
        dataDirectory.appendingPathComponent("error.log")
    }
}

/// Append-only error journal for troubleshooting. Each line carries a category,
/// a message, and the underlying NSError when one is available. Logging must
/// never change app behavior, so all file failures are ignored.
enum AppErrorLog {
    private static let logger = Logger(subsystem: "com.local.ClassicLaunchpad", category: "error")
    private static let lock = NSLock()
    private static let fileLimit = 512 * 1024

    static func error(_ message: String, category: String, error: Error? = nil) {
        var fields = "level=error category=\(sanitize(category)) message=\(sanitize(message))"
        if let error {
            let nsError = error as NSError
            fields += " error=\(nsError.domain):\(nsError.code):\(sanitize(nsError.localizedDescription))"
        }
        let line = "\(timestamp()) \(fields)\n"
        logger.error("\(line, privacy: .public)")
        append(line)
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let url = AppPaths.errorLogURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > fileLimit {
                try Data().write(to: url, options: .atomic)
            }
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch { }
    }
}
