import AppKit
import SwiftUI

@MainActor
func runPagingTests() async throws {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    let paging = LauncherPaging()
    paging.resize(to: 1000)
    var page = 1
    var commits = 0
    @discardableResult
    func scroll(_ x: CGFloat = 0, y: CGFloat = 0, phase: NSEvent.Phase = .changed,
                momentum: NSEvent.Phase = [], time: TimeInterval, count: Int = 3,
                precise: Bool = true) -> Bool {
        paging.scroll(deltaX: x, deltaY: y, phase: phase, momentum: momentum,
                      precise: precise, timestamp: time, page: page, pageCount: count) {
            page = $0
            commits += 1
        }
    }

    scroll(phase: .began, time: 0)
    scroll(-12, time: 0.01)
    try check(paging.isTracking && paging.offset == -12 && page == 1 && commits == 0,
              "a small horizontal movement moves the strip immediately without changing the page")
    scroll(-28, time: 0.03)
    try check(paging.offset == -40, "successive deltas track fingers at one point per point")
    scroll(phase: .ended, time: 0.2)
    try check(page == 1 && paging.offset == 0 && !paging.isTracking,
              "a short drag held before release snaps back, including a zero-delta end event")

    scroll(phase: .began, time: 1)
    scroll(-280, time: 1.15)
    scroll(phase: .ended, time: 1.3)
    try check(page == 2 && paging.offset == 0, "a deliberate long drag advances exactly one page")
    let afterRelease = commits
    scroll(-900, phase: [], momentum: .changed, time: 1.31)
    scroll(phase: [], momentum: .ended, time: 1.4)
    try check(page == 2 && commits == afterRelease, "momentum cannot turn a second page")

    // No fixed cooldown: the next distinct gesture can reverse direction immediately.
    scroll(phase: .began, time: 1.41)
    scroll(5, time: 1.42)
    scroll(55, time: 1.43)
    scroll(phase: .ended, time: 1.44)
    try check(page == 1, "a quick short flick uses release velocity and accepts a rapid next gesture")

    scroll(phase: .began, time: 2)
    scroll(-300, time: 2.1)
    scroll(290, time: 2.2)
    scroll(phase: .ended, time: 2.21)
    try check(page == 1, "reversing back before release cancels the outward page turn")

    scroll(phase: .began, time: 3)
    scroll(-400, time: 3.1)
    scroll(phase: .cancelled, time: 3.11)
    try check(page == 1 && paging.offset == 0 && !paging.isTracking,
              "a cancelled gesture always returns to its starting page")

    page = 0
    scroll(phase: .began, time: 4)
    scroll(500, time: 4.1)
    try check(paging.offset > 0 && paging.offset < 180,
              "the first page resists dragging beyond the leading edge")
    scroll(phase: .ended, time: 4.11)
    try check(page == 0 && paging.offset == 0, "leading-edge release stays on the first page")
    page = 2
    scroll(phase: .began, time: 5)
    scroll(-500, time: 5.1)
    try check(paging.offset < 0 && paging.offset > -180,
              "the last page resists dragging beyond the trailing edge")
    scroll(phase: .ended, time: 5.11)
    try check(page == 2, "trailing-edge release stays on the last page")

    page = 0
    scroll(phase: .began, time: 6, count: 1)
    scroll(-400, time: 6.1, count: 1)
    scroll(phase: .ended, time: 6.2, count: 1)
    try check(page == 0 && paging.offset == 0, "a one-page catalog cannot move to a nonexistent page")

    let beforeVertical = commits
    scroll(phase: .began, time: 7)
    try check(!scroll(2, y: 20, time: 7.01), "vertical intent is passed through")
    scroll(-400, y: 1, time: 7.02)
    scroll(phase: .ended, time: 7.03)
    try check(paging.offset == 0 && commits == beforeVertical,
              "a vertical sequence cannot become a page swipe or change selection on release")

    page = 1
    scroll(phase: .began, time: 8)
    scroll(-40, time: 8.01)
    scroll(1, y: 50, time: 8.02)
    try check(paging.offset == -39, "horizontal intent stays locked when later samples drift vertically")
    paging.resize(to: 800)
    try check(!paging.isTracking && paging.offset == 0, "resizing cancels a gesture in the old geometry")
    scroll(-400, time: 8.03)
    scroll(phase: .ended, time: 8.04)
    try check(page == 1 && paging.offset == 0, "cancelled sequences cannot restart from trailing changed events")

    scroll(-6, phase: [], time: 9, precise: false)
    try check(page == 2, "unphased mouse wheel events still turn pages")
    scroll(6, phase: [], time: 9.01, precise: false)
    try check(page == 2, "unphased wheel bursts remain throttled")
    scroll(6, phase: [], time: 9.5, precise: false)
    try check(page == 1, "a later mouse wheel burst starts with fresh distance")

    for (raw, origin, count) in [(CGFloat(500), 0, 3), (-500, 2, 3), (500, 0, 1), (-500, 0, 1), (1100, 1, 3)] {
        let displayed = paging.displayedTranslation(for: raw, page: origin, count: count)
        let restored = paging.rawTranslation(for: displayed, page: origin, count: count)
        try check(abs(restored - raw) < 0.000001, "rubber-band inversion preserves the raw displacement at every boundary")
        let step: CGFloat = 0.001
        let slope = (paging.displayedTranslation(for: raw + step, page: origin, count: count) - displayed) / step
        try check(abs(slope - paging.translationSlope(at: raw, page: origin, count: count)) < 0.00001,
                  "release velocity uses the derivative of the visible rubber-band movement")
    }

    // Exercise the NSEvent entry point used by the actual local monitor. These
    // events stay inside the fixture and are never posted to the system.
    let eventPaging = LauncherPaging()
    eventPaging.resize(to: 1000)
    func event(_ x: Int32, phase: NSEvent.Phase, time: TimeInterval) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                         wheel1: 0, wheel2: x, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let cgPhase: CGScrollPhase
        switch phase {
        case .began: cgPhase = .began
        case .changed: cgPhase = .changed
        case .ended: cgPhase = .ended
        case .cancelled: cgPhase = .cancelled
        default: cgPhase = .mayBegin
        }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(cgPhase.rawValue))
        cg.timestamp = UInt64(time * 1_000_000_000)
        return NSEvent(cgEvent: cg)!
    }
    var eventCommits: [Int] = []
    for (x, phase, time) in [(Int32(-12), NSEvent.Phase.began, 40.0), (-28, .changed, 40.01)] {
        _ = eventPaging.scroll(event: event(x, phase: phase, time: time), page: 1, pageCount: 3) {
            eventCommits.append($0)
        }
    }
    try check(eventPaging.isTracking && eventPaging.offset == -40 && eventCommits.isEmpty,
              "real precise NSEvents use point-for-point deltas from the first sample")
    _ = eventPaging.scroll(event: event(0, phase: .ended, time: 40.3), page: 1, pageCount: 3) {
        eventCommits.append($0)
    }
    try check(eventCommits == [1], "a held short NSEvent swipe returns to its origin exactly once")
    _ = eventPaging.scroll(event: event(12, phase: .began, time: 40.31), page: 1, pageCount: 3) { _ in }
    try check(eventPaging.offset == 12,
              "a consecutive reversed NSEvent swipe has exactly the same input-to-page ratio")
    eventPaging.cancel()

    var cadence = LauncherPagingFrameMetrics()
    for sample in 0...120 {
        let timestamp = Double(sample) / 120
        cadence.record(timestamp: timestamp, targetTimestamp: timestamp + 1 / 120)
    }
    let cadenceReport = cadence.report(requestedHz: 120)!
    try check(cadenceReport.intervals == 120 && abs(cadenceReport.observedCallbackHz - 120) < 0.001 &&
              cadenceReport.lateCallbacks == 0 && abs(cadenceReport.p95IntervalMS - 1000 / 120) < 0.001,
              "frame diagnostics report measured callback intervals independently of requested refresh")
    cadence.record(timestamp: 1.05, targetTimestamp: 1.05 + 1 / 120)
    let delayedReport = cadence.report(requestedHz: 120)!
    try check(delayedReport.lateCallbacks == 1 && abs(delayedReport.maxIntervalMS - 50) < 0.001 &&
              delayedReport.observedCallbackHz < 120,
              "frame diagnostics expose a 50 ms delivery gap instead of reporting the requested frame rate")

    let suite = "ClassicLaunchpad.Paging.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let session = LauncherSession(preferences: preferences)
    session.paging.resize(to: 1000)
    func beginSessionSwipe() {
        session.paging.scroll(deltaX: -40, deltaY: 0, phase: .began, momentum: [],
                              precise: true, timestamp: 10, page: session.page, pageCount: 3) { _ in }
    }
    beginSessionSwipe()
    session.query = "search"
    try check(!session.paging.isTracking && session.paging.offset == 0, "search changes cancel an in-flight swipe")
    beginSessionSwipe()
    session.folderID = "folder"
    try check(!session.paging.isTracking, "folder navigation cancels an in-flight swipe")
    beginSessionSwipe()
    session.page = 1
    try check(!session.paging.isTracking, "keyboard and dot navigation cancel an in-flight swipe")
    beginSessionSwipe()
    session.isPresented = false
    try check(!session.paging.isTracking, "hiding the launcher clears gesture state")

    let context = LauncherPageContext(folderID: nil, query: "")
    var mounted = LauncherPageMountState()
    mounted.visit(1, in: context, isDragging: false)
    try check(mounted.needsNeighbors(of: 1, count: 4, in: context), "unprepared neighbors require one mount")
    mounted.prepareNeighbors(of: 1, count: 4, in: context)
    try check(!mounted.needsNeighbors(of: 1, count: 4, in: context),
              "repeated swipes over warm neighbors require no mount-state mutation")
    try check(mounted.pages == [0, 1, 2] && mounted.lastPage == 1,
              "swiping prepares both neighbors without changing the last selected page")
    mounted.prepareNeighbors(of: 2, count: 4, in: LauncherPageContext(folderID: "folder", query: ""))
    try check(!mounted.pages.contains(3), "stale neighbor preparation cannot mount pages in a different context")

    // Render a real SwiftUI strip offscreen: state assertions alone cannot detect
    // an incorrectly sized/offset container or an accidental animation while tracking.
    let renderedPaging = LauncherPaging()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                          styleMask: .borderless, backing: .buffered, defer: false)
    let host = NSHostingView(rootView: LauncherPagingSurface(
        paging: renderedPaging, page: 1, pageCount: 3, width: 400, height: 100, animatesPageChange: true
    ) {
        HStack(spacing: 0) {
            Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1).frame(width: 400, height: 100)
            Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 1).frame(width: 400, height: 100)
            Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1).frame(width: 400, height: 100)
        }
    })
    window.contentView = host
    defer { window.orderOut(nil) }
    func sample(_ x: Int) throws -> NSColor {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Failure(description: "the paging surface can be rendered")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let pixelX = Int(CGFloat(x) / host.bounds.width * CGFloat(bitmap.pixelsWide))
        guard let color = bitmap.colorAt(x: pixelX, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) else {
            throw Failure(description: "the paging surface has readable pixels")
        }
        return color
    }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(40))
    let initial = try sample(350)
    func isGreen(_ color: NSColor) -> Bool {
        color.greenComponent > color.redComponent + 0.2 && color.greenComponent > color.blueComponent + 0.2
    }
    func isBlue(_ color: NSColor) -> Bool {
        color.blueComponent > color.redComponent + 0.2 && color.blueComponent > color.greenComponent + 0.2
    }
    try check(isGreen(initial),
              "the selected page fills the initial paging viewport (sample: \(initial))")
    renderedPaging.scroll(deltaX: 0, deltaY: 0, phase: .began, momentum: [],
                          precise: true, timestamp: 20, page: 1, pageCount: 3) { _ in }
    renderedPaging.scroll(deltaX: -100, deltaY: 0, phase: .changed, momentum: [],
                          precise: true, timestamp: 20.01, page: 1, pageCount: 3) { _ in }
    try await Task.sleep(for: .milliseconds(25))
    let revealed = try sample(350)
    let retained = try sample(250)
    try check(isBlue(revealed) && isGreen(retained),
              "the rendered strip immediately reveals exactly the dragged portion of the adjacent page (samples: \(revealed), \(retained))")

    guard let viewport = renderedPaging.viewport else {
        throw Failure(description: "the paging bridge attaches its native viewport")
    }
    var publishedSamples = 0
    let subscription = renderedPaging.objectWillChange.sink { publishedSamples += 1 }
    for index in 1...30 {
        renderedPaging.scroll(deltaX: -0.3, deltaY: 0, phase: .changed, momentum: [], precise: true,
                              timestamp: 20.01 + Double(index) / 120, page: 1, pageCount: 3) { _ in }
    }
    try check(publishedSamples == 0,
              "high-frequency input does not publish state or schedule SwiftUI body updates")
    try check(abs(viewport.precisePosition - (-400 + renderedPaging.offset)) < 0.000001 &&
              abs(viewport.displayedPosition - viewport.precisePosition) <= 0.5 / viewport.backingPixelScale,
              "tracking keeps continuous input while rendering on the physical pixel grid")
    subscription.cancel()
    let trackingLink = viewport.frameLink
    let requestedFPS = viewport.frameLink?.preferredFrameRateRange.preferred
    try check(requestedFPS == viewport.preferredFrameRateRange.maximum,
              "tracking requests the current screen's maximum frame rate")

    renderedPaging.scroll(deltaX: 0, deltaY: 0, phase: .ended, momentum: [], precise: true,
                          timestamp: 20.3, page: 1, pageCount: 3) { _ in }
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        guard let motion = viewport.motion else {
            throw Failure(description: "release creates a refresh-driven time-based trajectory")
        }
        try check(viewport.frameLink === trackingLink,
                  "finger-up reuses the active display link without a refresh scheduling gap")
        try check(viewport.frameLink?.preferredFrameRateRange.preferred == requestedFPS,
                  "settling requests the same maximum refresh rate")
        viewport.advanceAnimation(at: motion.startedAt + 0.017)
        let backingX = viewport.displayedPosition * viewport.backingPixelScale
        try check(abs(backingX - backingX.rounded()) < 0.000001,
                  "intermediate settling frames cannot interpolate the strip between physical pixels")
        let beforeInterruption = viewport.displayedPosition
        let targetPage = viewport.page
        renderedPaging.scroll(deltaX: 0, deltaY: 0, phase: .began, momentum: [], precise: true,
                              timestamp: 20.31, page: targetPage, pageCount: 3) { _ in }
        renderedPaging.scroll(deltaX: 8, deltaY: 0, phase: .changed, momentum: [], precise: true,
                              timestamp: 20.32, page: targetPage, pageCount: 3) { _ in }
        try check(abs(viewport.displayedPosition - beforeInterruption - 8) <= 0.5,
                  "a new gesture takes over the presentation position without jumping to the prior target")
        try check(viewport.frameLink === trackingLink,
                  "rapid re-grabs keep the same display link through the next gesture")
        try check(viewport.motion == nil,
                  "direct manipulation cancels the previous time-based trajectory")
    }
    renderedPaging.cancel()
    viewport.stop()
    try check(viewport.frameLink == nil, "idle viewports release their display link")

    let edgeViewport = LauncherPagingViewport()
    edgeViewport.update(content: AnyView(Color.clear), page: 0, width: 1000, height: 100, count: 3, animated: false)
    let edgePaging = LauncherPaging()
    edgePaging.viewport = edgeViewport
    edgePaging.resize(to: 1000)
    func edgeSample(_ x: CGFloat, _ phase: NSEvent.Phase, _ time: TimeInterval) {
        edgePaging.scroll(deltaX: x, deltaY: 0, phase: phase, momentum: [], precise: true,
                          timestamp: time, page: 0, pageCount: 3) { _ in }
    }
    edgeSample(0, .began, 30)
    edgeSample(500, .changed, 30.1)
    let edgeBefore = edgeViewport.displayedPosition
    edgeSample(0, .ended, 30.3)
    let edgePresentation = edgeViewport.displayedPosition
    edgeSample(0, .began, 30.31)
    edgeSample(8, .changed, 30.32)
    let expectedEdge = edgePaging.displayedTranslation(
        for: edgePaging.rawTranslation(for: edgePresentation, page: 0, count: 3) + 8, page: 0, count: 3)
    try check(abs(edgeViewport.displayedPosition - expectedEdge) <= 0.5 / edgeViewport.backingPixelScale &&
              (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || edgeViewport.displayedPosition > edgeBefore),
              "re-grabbing an edge bounce continues outward instead of jumping backward by 53 points")
    edgePaging.cancel()

    edgeViewport.stop()
    print("PASS: point-for-point tracking, velocity release, fractional tracking, interruption, measured callback diagnostics, and gesture boundaries")
}
