import AppKit
import QuartzCore
import SwiftUI

/// Native clipping and layer movement avoid a SwiftUI layout/diff on every sample.
@MainActor
final class LauncherPagingViewport: NSView {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private(set) var page = 0
    private var pageWidth: CGFloat = 0
    private var stripSize = NSSize.zero
    private var isTracking = false
    private(set) var motion: LauncherPagingMotion?
    private(set) var precisePosition: CGFloat = 0
    private(set) var positionCommitCount = 0
    private var pendingContent: AnyView?
    private var preparedPages: Set<Int> = []
    private(set) var frameLink: CADisplayLink?
    private var frameMetrics = LauncherPagingFrameMetrics()
    private(set) var lastFrameReport: LauncherPagingFrameReport?
    private let frameLogPath = ProcessInfo.processInfo.environment["CLASSIC_LAUNCHPAD_PAGING_LOG"]

    var isMoving: Bool { isTracking || motion != nil }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        // Do not flatten text and icons into a resampled whole-page bitmap.
        hosting.layer?.shouldRasterize = false
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(content: AnyView, page: Int, width: CGFloat, height: CGFloat, count: Int,
                animated: Bool, preparedPages: Set<Int> = []) {
        let size = NSSize(width: width * CGFloat(count), height: height)
        let geometryChanged = pageWidth != width || stripSize != size
        let needsPreparation = !preparedPages.isSubset(of: self.preparedPages)
        self.preparedPages = preparedPages
        pageWidth = width
        stripSize = size
        if geometryChanged {
            pendingContent = nil
            stop()
            hosting.rootView = content
            hosting.setFrameSize(size)
            self.page = page
            setPosition(-CGFloat(page) * width)
        } else {
            if (isMoving && !(isTracking && needsPreparation)) || (self.page != page && animated) {
                // In particular, do not rebuild two full icon grids when the
                // selected page changes at finger-up. Apply once movement ends.
                pendingContent = content
            } else {
                pendingContent = nil
                hosting.rootView = content
            }
            if self.page != page { settle(to: page, animated: animated) }
        }
        updateBackingScale()
    }

    /// Return displacement relative to the current logical page, preserving motion.
    func beginTracking(page: Int) -> CGFloat {
        let displayed = displayedPosition
        // Keep an existing display link alive across a rapid re-grab. Recreating
        // it at a gesture boundary can lose the next refresh opportunity.
        motion = nil
        // A rapid re-grab keeps the existing grids and any pending update.
        // Applying it here blocks direct manipulation with a whole-strip diff.
        self.page = page
        isTracking = true
        setPosition(displayed)
        startFrames()
        return displayed + CGFloat(page) * pageWidth
    }

    func track(page: Int, offset: CGFloat) {
        setPosition(-CGFloat(page) * pageWidth + offset)
    }

    func cancelTracking() {
        completeTracking(at: page)
    }

    func completeTracking(at page: Int) {
        stop()
        self.page = page
        setPosition(-CGFloat(page) * pageWidth)
    }

    func settle(to page: Int, velocity: CGFloat = 0, animated: Bool = true) {
        let from = displayedPosition
        isTracking = false
        motion = nil
        self.page = page
        let target = -CGFloat(page) * pageWidth
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(target - from) > 0.25 else {
            setPosition(target)
            stop()
            return
        }
        // A compositor position animation interpolates through fractional
        // backing pixels. Drive the trajectory at refresh time instead so text
        // and icons keep their original pixel samples throughout the animation.
        motion = LauncherPagingMotion(from: from, target: target, velocity: velocity,
                                     startedAt: CACurrentMediaTime())
        startFrames()
    }

    var displayedPosition: CGFloat {
        hosting.frame.minX
    }

    var preferredFrameRateRange: CAFrameRateRange {
        let maximum = Float(window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        return CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
    }

    var backingPixelScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func setPosition(_ x: CGFloat) {
        precisePosition = x
        let position = (x * backingPixelScale).rounded() / backingPixelScale
        // Preserve the continuous input above, but do no AppKit/CA work when
        // successive samples resolve to the same physical-pixel position.
        guard hosting.frame.minX != position else { return }
        positionCommitCount += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosting.setFrameOrigin(NSPoint(x: position, y: 0))
        CATransaction.commit()
    }

    private func startFrames() {
        guard frameLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayTick(_:)))
        frameMetrics = LauncherPagingFrameMetrics()
        link.preferredFrameRateRange = preferredFrameRateRange
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        if frameLogPath != nil {
            frameMetrics.record(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        }
        advanceAnimation(at: link.targetTimestamp)
        if !isTracking && motion == nil { stop() }
    }

    func advanceAnimation(at timestamp: TimeInterval) {
        guard let motion else { return }
        let sample = motion.sample(at: timestamp)
        if abs(sample.position - motion.target) * backingPixelScale < 0.1 && abs(sample.velocity) < 3 {
            setPosition(motion.target)
            self.motion = nil
        } else {
            setPosition(sample.position)
        }
    }

    private func applyPendingContent() {
        guard let pendingContent else { return }
        self.pendingContent = nil
        hosting.rootView = pendingContent
    }

    func stop(applyPendingContent: Bool = true) {
        if let report = frameMetrics.report(requestedHz: Double(frameLink?.preferredFrameRateRange.preferred ?? 0)) {
            lastFrameReport = report
            if let frameLogPath { report.append(to: frameLogPath) }
        }
        frameMetrics = LauncherPagingFrameMetrics()
        frameLink?.invalidate()
        frameLink = nil
        isTracking = false
        motion = nil
        if applyPendingContent { self.applyPendingContent() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop(applyPendingContent: false) }
        updateBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    private func updateBackingScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        hosting.layer?.contentsScale = scale
        frameLink?.preferredFrameRateRange = preferredFrameRateRange
        // A display change must not leave the strip between backing pixels.
        setPosition(precisePosition)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // AppKit's hit regions are at the model position during a layer animation.
        if isMoving {
            return self
        }
        return super.hitTest(point)
    }
}
