import Foundation

/// Measures display-link delivery, not rendered/presented frame throughput.
struct LauncherPagingFrameMetrics {
    private var previousTimestamp: TimeInterval?
    private var previousBudget: TimeInterval = 0
    private var intervals: [TimeInterval] = []
    private var lateCallbacks = 0

    mutating func record(timestamp: TimeInterval, targetTimestamp: TimeInterval) {
        let budget = targetTimestamp - timestamp
        guard timestamp.isFinite, budget.isFinite, budget > 0 else { return }
        if let previousTimestamp, timestamp <= previousTimestamp { return }
        defer { previousTimestamp = timestamp; previousBudget = budget }
        guard let previousTimestamp, timestamp > previousTimestamp, intervals.count < 4096 else { return }
        let interval = timestamp - previousTimestamp
        intervals.append(interval)
        if interval > max(previousBudget, budget) * 1.5 { lateCallbacks += 1 }
    }

    func report(requestedHz: Double) -> LauncherPagingFrameReport? {
        guard !intervals.isEmpty else { return nil }
        let sorted = intervals.sorted()
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        return LauncherPagingFrameReport(measurement: "display_link_callback_cadence",
            intervals: intervals.count, requestedHz: requestedHz, observedCallbackHz: 1 / mean,
            meanIntervalMS: mean * 1000, p95IntervalMS: sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1] * 1000,
            maxIntervalMS: sorted.last! * 1000, lateCallbacks: lateCallbacks)
    }
}

struct LauncherPagingFrameReport: Codable {
    let measurement: String
    let intervals: Int
    let requestedHz: Double
    let observedCallbackHz: Double
    let meanIntervalMS: Double
    let p95IntervalMS: Double
    let maxIntervalMS: Double
    let lateCallbacks: Int

    func append(to path: String) {
        // Logging is opt-in and stays off the UI thread. It contains timing only.
        LauncherPagingFrameLog.queue.async {
            guard var data = try? JSONEncoder().encode(self) else { return }
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: path) {
                _ = FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let file = FileHandle(forWritingAtPath: path) else { return }
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: data)
        }
    }
}

private enum LauncherPagingFrameLog {
    static let queue = DispatchQueue(label: "com.local.ClassicLaunchpad.paging-metrics", qos: .utility)
}
