import Foundation

/// A time-based critically damped trajectory. Sampling at 60 or 120 Hz gives
/// the same position at the same time; only the final display position is rounded.
struct LauncherPagingMotion {
    let from: CGFloat
    let target: CGFloat
    let initialVelocity: CGFloat
    let startedAt: TimeInterval
    private let frequency: CGFloat = 30

    init(from: CGFloat, target: CGFloat, velocity: CGFloat, startedAt: TimeInterval) {
        self.from = from
        self.target = target
        self.startedAt = startedAt
        let distance = target - from
        initialVelocity = abs(distance) > 0.000001
            ? max(-6, min(22, velocity / distance)) * distance : 0
    }

    func sample(at timestamp: TimeInterval) -> (position: CGFloat, velocity: CGFloat) {
        let time = CGFloat(max(0, timestamp - startedAt))
        let displacement = from - target
        let coefficient = initialVelocity + frequency * displacement
        let decay = exp(-frequency * time)
        return (target + (displacement + coefficient * time) * decay,
                (initialVelocity - frequency * coefficient * time) * decay)
    }
}
