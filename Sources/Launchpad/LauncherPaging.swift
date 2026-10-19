import AppKit
import SwiftUI

/// Only gesture boundaries publish state. Scroll samples go straight to AppKit.
@MainActor
final class LauncherPaging: ObservableObject {
    private(set) var offset: CGFloat = 0
    @Published private(set) var isTracking = false
    weak var viewport: LauncherPagingViewport?
    private(set) var width: CGFloat = 0
    private var originPage = 0
    private var hasSequence = false
    private var verticalSequence = false
    private var translation: CGFloat = 0
    private var verticalTranslation: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastSample: TimeInterval = 0
    private var lastMovement: TimeInterval = 0
    private var wheelDistance: CGFloat = 0
    private var lastWheelSample: TimeInterval = -.infinity
    private var lastWheelTurn: TimeInterval = -.infinity
    private var preservesPresentation = false

    /// Use the event's point deltas for every drag, including rapid re-grabs.
    /// System swipe progress is normalized independently of the viewport width;
    /// mixing it with point deltas changes the tracking ratio between gestures.
    func scroll(event: NSEvent, page: Int, pageCount: Int, commit: (Int) -> Void) -> Bool {
        scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
               phase: event.phase, momentum: event.momentumPhase,
               precise: event.hasPreciseScrollingDeltas, timestamp: event.timestamp,
               page: page, pageCount: pageCount, commit: commit)
    }

    func resize(to width: CGFloat) {
        guard self.width != width else { return }
        cancel()
        self.width = width
    }

    func cancel() {
        resetGesture(preservingPresentation: false)
    }

    private func resetGesture(preservingPresentation: Bool) {
        let hadVisualGesture = isTracking || offset != 0 || preservesPresentation
        preservesPresentation = preservingPresentation && viewport?.isMoving == true
        hasSequence = false
        verticalSequence = false
        translation = 0
        verticalTranslation = 0
        velocity = 0
        wheelDistance = 0
        offset = 0
        if isTracking { isTracking = false }
        if hadVisualGesture && !preservesPresentation { viewport?.cancelTracking() }
    }

    @discardableResult
    func scroll(deltaX: CGFloat, deltaY: CGFloat, phase: NSEvent.Phase,
                momentum: NSEvent.Phase, precise: Bool, timestamp: TimeInterval,
                page: Int, pageCount: Int, commit: (Int) -> Void) -> Bool {
        // The release already chose a target. Momentum must not turn more pages.
        if !momentum.isEmpty { return isTracking || abs(deltaX) > abs(deltaY) }

        if phase.isEmpty {
            guard abs(deltaX) > abs(deltaY) else { return false }
            if timestamp - lastWheelSample > 0.25 { wheelDistance = 0 }
            lastWheelSample = timestamp
            wheelDistance += deltaX
            if abs(wheelDistance) >= (precise ? 55 : 5), timestamp - lastWheelTurn >= 0.25 {
                commit(max(0, min(pageCount - 1, page + (wheelDistance < 0 ? 1 : -1))))
                wheelDistance = 0
                lastWheelTurn = timestamp
            }
            return true
        }

        if phase.contains(.began) || phase.contains(.mayBegin) {
            resetGesture(preservingPresentation: true)
            guard width > 0 else { return false }
            hasSequence = true
            originPage = page
            lastSample = timestamp
            lastMovement = timestamp
        }
        guard hasSequence else { return false }
        guard originPage == page else { cancel(); return false }

        if phase.contains(.cancelled) {
            let handled = isTracking
            if handled { finish(target: originPage, commit: commit) }
            else { cancel() }
            return handled
        }

        translation = max(-width * 1.25, min(width * 1.25, translation + deltaX))
        verticalTranslation += deltaY
        if !isTracking && !verticalSequence && max(abs(translation), abs(verticalTranslation)) >= 4 {
            if abs(translation) > abs(verticalTranslation) * 1.15 {
                // Interrupt a settling animation at its presentation position,
                // rather than jumping to the last gesture's logical target.
                let displayed = viewport?.beginTracking(page: originPage) ?? 0
                translation += rawTranslation(for: displayed, page: originPage, count: pageCount)
                preservesPresentation = false
                isTracking = true
            } else if abs(verticalTranslation) > abs(translation) * 1.15 {
                verticalSequence = true
            }
        }

        let interval = timestamp - lastSample
        if deltaX != 0 {
            let sample = interval > 0 && interval < 0.08 ? deltaX / max(interval, 0.004) : 0
            velocity = velocity * 0.25 + sample * 0.75
            velocity = max(-width * 4, min(width * 4, velocity))
            lastMovement = timestamp
        }
        lastSample = timestamp
        let handled = isTracking
        if isTracking {
            offset = displayedTranslation(for: translation, page: originPage, count: pageCount)
            viewport?.track(page: originPage, offset: offset)
        }

        if phase.contains(.ended) {
            guard isTracking else { cancel(); return false }
            let releaseVelocity = timestamp - lastMovement <= 0.08 ? velocity : 0
            let projected = translation + releaseVelocity * 0.16
            let shouldTurn = isTracking && abs(translation) >= 10
                && abs(projected) >= width * 0.22 && projected * translation > 0
            let target = shouldTurn ? originPage + (projected < 0 ? 1 : -1) : originPage
            let visualVelocity = releaseVelocity * translationSlope(at: translation, page: originPage, count: pageCount)
            finish(target: max(0, min(pageCount - 1, target)), velocity: visualVelocity, commit: commit)
        }
        return handled
    }

    private func limit(for translation: CGFloat, page: Int, count: Int) -> CGFloat {
        (page == 0 && translation > 0) || (page == count - 1 && translation < 0) ? 0 : width
    }

    func displayedTranslation(for raw: CGFloat, page: Int, count: Int) -> CGFloat {
        let limit = limit(for: raw, page: page, count: count)
        let distance = abs(raw)
        let excess = max(0, distance - limit)
        let resistance = max(1, width * 0.18)
        let displayed = min(distance, limit) + resistance * excess / (resistance + excess)
        return raw < 0 ? -displayed : displayed
    }

    func rawTranslation(for displayed: CGFloat, page: Int, count: Int) -> CGFloat {
        let limit = limit(for: displayed, page: page, count: count)
        let resistance = max(1, width * 0.18)
        let excess = min(max(0, abs(displayed) - limit), resistance * 0.999999)
        let raw = min(abs(displayed), limit) + resistance * excess / (resistance - excess)
        return displayed < 0 ? -raw : raw
    }

    func translationSlope(at raw: CGFloat, page: Int, count: Int) -> CGFloat {
        let excess = max(0, abs(raw) - limit(for: raw, page: page, count: count))
        let resistance = max(1, width * 0.18)
        return pow(resistance / (resistance + excess), 2)
    }

    private func finish(target: Int, velocity: CGFloat = 0, commit: (Int) -> Void) {
        hasSequence = false
        offset = 0
        isTracking = false
        viewport?.settle(to: target, velocity: velocity)
        commit(target)
    }
}

/// The hosting hierarchy stays still; AppKit moves its existing Retina layers.
struct LauncherPagingSurface<Content: View>: View {
    let paging: LauncherPaging
    let page: Int
    let pageCount: Int
    var preparedPages: Set<Int> = []
    let width: CGFloat
    let height: CGFloat
    let animatesPageChange: Bool
    @ViewBuilder var content: Content

    var body: some View {
        LauncherNativePagingBridge(paging: paging, page: page, pageCount: pageCount, preparedPages: preparedPages,
                                   width: width, height: height,
                                   animatesPageChange: animatesPageChange, content: content)
            .frame(width: width, height: height)
            .onAppear { paging.resize(to: width) }
            .onChange(of: width) { _, width in paging.resize(to: width) }
    }
}

private struct LauncherNativePagingBridge<Content: View>: NSViewRepresentable {
    let paging: LauncherPaging
    let page: Int
    let pageCount: Int
    let preparedPages: Set<Int>
    let width: CGFloat
    let height: CGFloat
    let animatesPageChange: Bool
    let content: Content

    func makeNSView(context: Context) -> LauncherPagingViewport {
        let viewport = LauncherPagingViewport()
        paging.viewport = viewport
        return viewport
    }

    func updateNSView(_ viewport: LauncherPagingViewport, context: Context) {
        viewport.update(content: AnyView(content.frame(width: width * CGFloat(pageCount), height: height,
                                                      alignment: .topLeading)
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.layoutDirection, context.environment.layoutDirection)),
                        page: page, width: width, height: height, count: pageCount,
                        animated: animatesPageChange, preparedPages: preparedPages)
    }

    static func dismantleNSView(_ viewport: LauncherPagingViewport, coordinator: ()) {
        viewport.stop()
    }
}
