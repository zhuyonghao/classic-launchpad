import Foundation

private struct FourFingerGestureTestFailure: Error, CustomStringConvertible {
    let description: String
}

/// Synthetic regression checks only; safe to run without trackpad hardware.
func runFourFingerGestureTests() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FourFingerGestureTestFailure(description: "Four-finger gesture: \(message)") }
    }

    func contacts(scale: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5,
                  angle: Double = 0, count: Int = 4) -> [TrackpadContact] {
        let offsets = [(-0.18, -0.13), (0.18, -0.13), (0.18, 0.13), (-0.18, 0.13), (0.0, 0.0)]
        return Array(offsets.prefix(count).enumerated()).map { index, offset in
            TrackpadContact(id: Int32(index + 1),
                            x: centerX + (offset.0 * cos(angle) - offset.1 * sin(angle)) * scale,
                            y: centerY + (offset.0 * sin(angle) + offset.1 * cos(angle)) * scale)
        }
    }

    let pinchScales = [1.0, 0.98, 0.92, 0.84, 0.75, 0.68, 0.65]
    let spreadScales = [1.0, 1.03, 1.10, 1.20, 1.32, 1.40, 1.42]
    func run(_ recognizer: inout FourFingerGestureRecognizer, scales: [Double], start: TimeInterval = 0,
             step: TimeInterval = 0.04, transform: (Int, [TrackpadContact]) -> [TrackpadContact] = { _, points in points }) -> [FourFingerGesture] {
        scales.enumerated().compactMap { index, scale in
            recognizer.process(contacts: transform(index, contacts(scale: scale)), timestamp: start + Double(index) * step)
        }
    }

    var recognizer = FourFingerGestureRecognizer()
    try require(run(&recognizer, scales: pinchScales) == [.pinchIn], "four-finger pinch did not trigger exactly once")
    recognizer.reset()
    try require(run(&recognizer, scales: spreadScales) == [.spreadOut], "four-finger spread did not trigger exactly once")

    // Dictionary/callback ordering may change while the actual contact IDs stay stable.
    recognizer.reset()
    let reordered = run(&recognizer, scales: pinchScales) { index, points in index.isMultiple(of: 2) ? points : Array(points.reversed()) }
    try require(reordered == [.pinchIn], "contact array reordering changed identity tracking")

    recognizer.reset()
    var assembled: [FourFingerGesture] = []
    for count in 1...3 {
        if let result = recognizer.process(contacts: contacts(count: count), timestamp: Double(count - 1) * 0.02) { assembled.append(result) }
    }
    assembled += run(&recognizer, scales: pinchScales, start: 0.06)
    try require(assembled == [.pinchIn], "normal sequential finger touchdown was rejected")

    for count in [2, 3, 5] {
        recognizer.reset()
        let results = pinchScales.enumerated().compactMap { index, scale in
            recognizer.process(contacts: contacts(scale: scale, count: count), timestamp: Double(index) * 0.04)
        }
        try require(results.isEmpty, "\(count)-finger input triggered")
    }

    recognizer.reset()
    let translation = (0..<9).compactMap { index in
        recognizer.process(contacts: contacts(centerX: 0.5 + Double(index) * 0.015), timestamp: Double(index) * 0.04)
    }
    try require(translation.isEmpty, "four-finger translation triggered")

    recognizer.reset()
    let rotation = (0..<9).compactMap { index in
        recognizer.process(contacts: contacts(angle: Double(index) * 0.08), timestamp: Double(index) * 0.04)
    }
    try require(rotation.isEmpty, "rotation triggered")
    recognizer.reset()
    let rotatingPinch = pinchScales.enumerated().compactMap { index, scale in
        recognizer.process(contacts: contacts(scale: scale, angle: Double(index) * 0.14), timestamp: Double(index) * 0.04)
    }
    try require(rotatingPinch.isEmpty, "strong rotation was mistaken for a pinch")

    recognizer.reset()
    let naturalPinch = pinchScales.enumerated().compactMap { index, scale in
        recognizer.process(contacts: contacts(scale: scale, centerX: 0.5 + Double(index) * 0.004, angle: Double(index) * 0.025), timestamp: Double(index) * 0.04)
    }
    try require(naturalPinch == [.pinchIn], "small natural center/angle drift rejected a pinch")

    // Common Launchpad gesture: keep the thumb stationary and move the other
    // three fingers towards it. Its centroid legitimately travels over 6.5%.
    func thumbAnchoredContacts(scale: Double) -> [TrackpadContact] {
        let points = [(0.12, 0.17), (0.57, 0.69), (0.73, 0.73), (0.87, 0.68)]
        let thumb = points[0]
        return points.enumerated().map { index, point in
            TrackpadContact(id: Int32(index + 1),
                            x: thumb.0 + (point.0 - thumb.0) * scale,
                            y: thumb.1 + (point.1 - thumb.1) * scale)
        }
    }
    recognizer.reset()
    let anchoredPinch = pinchScales.enumerated().compactMap { index, scale in
        recognizer.process(contacts: thumbAnchoredContacts(scale: scale), timestamp: Double(index) * 0.04)
    }
    try require(anchoredPinch == [.pinchIn], "stationary-thumb pinch rejected legitimate center motion")
    recognizer.reset()
    let anchoredSpread = spreadScales.enumerated().compactMap { index, scale in
        recognizer.process(contacts: thumbAnchoredContacts(scale: scale * 0.6), timestamp: Double(index) * 0.04)
    }
    try require(anchoredSpread == [.spreadOut], "stationary-thumb spread rejected legitimate center motion")
    recognizer.reset()
    try require(run(&recognizer, scales: pinchScales, step: 0.02) == [.pinchIn], "normal fast pinch was rejected")
    recognizer.reset()
    try require(run(&recognizer, scales: spreadScales, step: 0.02) == [.spreadOut], "normal fast spread was rejected")

    recognizer.reset()
    let changedIdentity = run(&recognizer, scales: pinchScales) { index, points in
        guard index >= 2 else { return points }
        return points.enumerated().map { offset, point in
            TrackpadContact(id: offset == 0 ? 99 : point.id, x: point.x, y: point.y)
        }
    }
    try require(changedIdentity.isEmpty, "replacement contact continued an old gesture")

    for interruptedCount in [3, 5] {
        recognizer.reset()
        let results = run(&recognizer, scales: pinchScales) { index, points in
            index == 2 ? contacts(scale: 0.92, count: interruptedCount) : points
        }
        try require(results.isEmpty, "temporary \(interruptedCount)-finger interruption rearmed without lift")
    }

    recognizer.reset()
    var sequence = run(&recognizer, scales: pinchScales)
    sequence += run(&recognizer, scales: spreadScales, start: 0.28)
    try require(sequence == [.pinchIn], "one touch sequence fired more than once")
    _ = recognizer.process(contacts: [], timestamp: 0.60)
    try require(run(&recognizer, scales: spreadScales, start: 0.64) == [.spreadOut], "all-fingers-up did not rearm")

    recognizer.reset()
    try require(run(&recognizer, scales: [1, 0.98, 0.96, 0.95, 0.97, 0.96, 0.99]).isEmpty, "small scale jitter triggered")
    recognizer.reset()
    try require(run(&recognizer, scales: [1, 0.98, 0.94, 0.9, 0.65, 0.95, 1]).isEmpty, "one-frame scale spike triggered")
    recognizer.reset()
    try require(run(&recognizer, scales: pinchScales, step: 0.01).isEmpty, "gesture shorter than minimum duration triggered")

    // Invalid coordinates and duplicate identities must poison the current sequence.
    let invalidContacts: [[TrackpadContact]] = [
        contacts().enumerated().map { index, point in TrackpadContact(id: point.id, x: index == 0 ? .nan : point.x, y: point.y) },
        contacts().enumerated().map { index, point in TrackpadContact(id: point.id, x: point.x, y: index == 0 ? .infinity : point.y) },
        contacts().enumerated().map { index, point in TrackpadContact(id: point.id, x: index == 0 ? -0.01 : point.x, y: point.y) },
        contacts().enumerated().map { index, point in TrackpadContact(id: point.id, x: point.x, y: index == 0 ? 1.01 : point.y) },
        contacts().map { TrackpadContact(id: 1, x: $0.x, y: $0.y) }
    ]
    for invalid in invalidContacts {
        recognizer.reset()
        let results = run(&recognizer, scales: pinchScales) { index, points in index == 2 ? invalid : points }
        try require(results.isEmpty, "invalid coordinates/IDs did not invalidate the gesture")
    }
    for invalidTime in [TimeInterval.nan, .infinity, -1, 0.02, 0.04] {
        recognizer.reset()
        var results: [FourFingerGesture] = []
        for (index, scale) in pinchScales.enumerated() {
            let timestamp = index == 2 ? invalidTime : Double(index) * 0.04
            if let result = recognizer.process(contacts: contacts(scale: scale), timestamp: timestamp) { results.append(result) }
        }
        try require(results.isEmpty, "invalid or non-increasing timestamp did not invalidate gesture")
    }

    recognizer.reset()
    _ = recognizer.process(contacts: contacts(), timestamp: 0)
    try require(run(&recognizer, scales: pinchScales, start: 0.5).isEmpty, "long frame gap retained an old baseline")
    _ = recognizer.process(contacts: [], timestamp: 1)
    try require(run(&recognizer, scales: pinchScales, start: 1.04) == [.pinchIn], "recognizer did not recover after gap and lift")

    recognizer.reset()
    for index in 0...45 { _ = recognizer.process(contacts: contacts(), timestamp: Double(index) * 0.04) }
    try require(run(&recognizer, scales: pinchScales, start: 1.84).isEmpty, "old stationary touches started a late gesture")

    recognizer.reset()
    let deformation = run(&recognizer, scales: [1, 0.9, 0.8, 0.65, 0.5, 0.4, 0.35]) { index, points in
        var result = points
        if index > 0 {
            result[0] = TrackpadContact(id: points[0].id, x: points[0].x + 0.24, y: points[0].y)
        }
        return result
    }
    try require(deformation.isEmpty, "incoherent finger deformation triggered")

    print("PASS: four-finger pinch/spread, identity, timing, geometry, invalid input, and rearming")
}
