import Foundation

/// Trackpad coordinates are normalized to the closed range 0...1 on each axis.
struct TrackpadContact {
    let id: Int32
    let x: Double
    let y: Double
}

enum FourFingerGesture: Equatable {
    case pinchIn
    case spreadOut
}

/// Pure geometry/state recognition; this type never reads a device or launches an app.
///
/// 四指可在 0.30 秒内依次落下；之后必须保持同一组四个触点。收拢需半径缩小
/// 22%，张开需增大 25%，并至少改变触控板归一化尺寸的 2.5%。手势至少持续
/// 0.12 秒、跨越四帧，越过阈值后还需保持 0.035 秒，过滤短暂抖动。
/// 中心漂移容差随收缩/扩张幅度增加，允许以基本固定的拇指为中心捏合。
/// 旋转超过约 26° 或明显不一致的手指运动会中止识别。
/// 断帧超过 0.22 秒、身份改变、异常输入或触发后都等待全部抬指才重新开始，
/// 防止半次手势、四指平移以及同一次触摸序列重复触发。
struct FourFingerGestureRecognizer {
    enum Diagnostic: String {
        case idle, assembling, tracking, candidate, recognized
        case invalidInput, wrongFingerCount, frameGap, changedIdentity, timedOut
        case centerDrift, shapeOrRotation, contactsTooClose
    }

    private(set) var diagnostic: Diagnostic = .idle
    private struct Point {
        let x: Double
        let y: Double
        var squaredLength: Double { x * x + y * y }
        var length: Double { sqrt(squaredLength) }
    }

    private struct Baseline {
        let ids: [Int32]
        let center: Point
        let vectors: [Point]
        let radius: Double
        let timestamp: TimeInterval
    }

    private struct Candidate {
        let gesture: FourFingerGesture
        let timestamp: TimeInterval
    }

    private var sequenceStart: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var baseline: Baseline?
    private var candidate: Candidate?
    private var sampleCount = 0
    private var lockedUntilLift = false

    mutating func reset() {
        sequenceStart = nil
        lastTimestamp = nil
        baseline = nil
        candidate = nil
        sampleCount = 0
        lockedUntilLift = false
        diagnostic = .idle
    }

    mutating func process(contacts: [TrackpadContact], timestamp: TimeInterval) -> FourFingerGesture? {
        // An explicit all-fingers-up frame always ends the touch sequence.
        if contacts.isEmpty {
            reset()
            return nil
        }
        guard !lockedUntilLift else { return nil }
        guard timestamp.isFinite, timestamp >= 0,
              contacts.count <= 4,
              Set(contacts.map(\.id)).count == contacts.count,
              contacts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            invalidateSequence(.invalidInput)
            return nil
        }
        if let lastTimestamp, timestamp <= lastTimestamp || timestamp - lastTimestamp > 0.22 {
            invalidateSequence(.frameGap)
            return nil
        }
        lastTimestamp = timestamp
        if sequenceStart == nil { sequenceStart = timestamp }

        guard contacts.count == 4 else {
            if baseline != nil || timestamp - (sequenceStart ?? timestamp) > 0.30 {
                invalidateSequence(.wrongFingerCount)
            } else { diagnostic = .assembling }
            return nil
        }

        let sorted = contacts.sorted { $0.id < $1.id }
        let center = Point(x: sorted.reduce(0) { $0 + $1.x } / 4,
                           y: sorted.reduce(0) { $0 + $1.y } / 4)
        let vectors = sorted.map { Point(x: $0.x - center.x, y: $0.y - center.y) }
        let radius = sqrt(vectors.reduce(0) { $0 + $1.squaredLength } / 4)

        // Coincident/near-coincident contacts cannot describe a reliable scale.
        guard radius >= 0.015, Self.areSeparated(sorted) else {
            invalidateSequence(.contactsTooClose)
            return nil
        }
        guard let baseline else {
            guard timestamp - (sequenceStart ?? timestamp) <= 0.30, radius >= 0.04 else {
                invalidateSequence(.timedOut)
                return nil
            }
            self.baseline = Baseline(ids: sorted.map(\.id), center: center, vectors: vectors, radius: radius, timestamp: timestamp)
            sampleCount = 1
            diagnostic = .tracking
            return nil
        }
        let elapsed = timestamp - baseline.timestamp
        guard sorted.map(\.id) == baseline.ids else {
            invalidateSequence(.changedIdentity)
            return nil
        }
        guard elapsed <= 1.6 else {
            invalidateSequence(.timedOut)
            return nil
        }
        sampleCount += 1
        let centerMovement = hypot(center.x - baseline.center.x, center.y - baseline.center.y)
        // A pinch around a stationary thumb translates the centroid as it
        // changes radius. Translation alone still has only the small allowance.
        let radiusChange = abs(radius - baseline.radius)
        let centerAllowance = min(0.25, 0.045 + 2 * radiusChange)
        guard centerMovement <= centerAllowance else {
            invalidateSequence(.centerDrift)
            return nil
        }

        // Fit a uniform scale and rotation to all four vectors. A rotation alone
        // does not change radius; large rotation or shape distortion is rejected.
        let squaredBaseline = baseline.vectors.reduce(0) { $0 + $1.squaredLength }
        var dot = 0.0
        var cross = 0.0
        for index in 0..<4 {
            let old = baseline.vectors[index]
            let current = vectors[index]
            dot += old.x * current.x + old.y * current.y
            cross += old.x * current.y - old.y * current.x
        }
        let angle = atan2(cross, dot)
        let fitScale = hypot(dot, cross) / squaredBaseline
        let cosine = cos(angle)
        let sine = sin(angle)
        var squaredError = 0.0
        for index in 0..<4 {
            let old = baseline.vectors[index]
            let fitted = Point(x: (old.x * cosine - old.y * sine) * fitScale,
                               y: (old.x * sine + old.y * cosine) * fitScale)
            squaredError += pow(vectors[index].x - fitted.x, 2) + pow(vectors[index].y - fitted.y, 2)
        }
        let shapeError = sqrt(squaredError / 4) / baseline.radius
        guard abs(angle) <= 0.45, shapeError <= 0.22 else {
            invalidateSequence(.shapeOrRotation)
            return nil
        }

        let scale = radius / baseline.radius
        let delta = radius - baseline.radius
        let gesture: FourFingerGesture?
        if scale <= 0.78 && delta <= -0.025 {
            gesture = .pinchIn
        } else if scale >= 1.25 && delta >= 0.025 {
            gesture = .spreadOut
        } else {
            gesture = nil
        }
        guard let gesture else {
            candidate = nil
            diagnostic = .tracking
            return nil
        }
        let consistentFingers = zip(baseline.vectors, vectors).filter { old, current in
            if gesture == .pinchIn { return current.length <= old.length * 0.96 }
            return current.length >= old.length * 1.04
        }.count
        guard consistentFingers >= 3 else {
            candidate = nil
            diagnostic = .tracking
            return nil
        }
        if candidate?.gesture != gesture {
            candidate = Candidate(gesture: gesture, timestamp: timestamp)
        }
        diagnostic = .candidate
        guard elapsed >= 0.12, sampleCount >= 4,
              timestamp - (candidate?.timestamp ?? timestamp) >= 0.035 else { return nil }
        invalidateSequence(.recognized)
        return gesture
    }

    private mutating func invalidateSequence(_ reason: Diagnostic) {
        baseline = nil
        candidate = nil
        sampleCount = 0
        lockedUntilLift = true
        diagnostic = reason
    }

    private static func areSeparated(_ contacts: [TrackpadContact]) -> Bool {
        for left in 0..<contacts.count {
            for right in (left + 1)..<contacts.count {
                if hypot(contacts[left].x - contacts[right].x, contacts[left].y - contacts[right].y) < 0.006 {
                    return false
                }
            }
        }
        return true
    }
}
