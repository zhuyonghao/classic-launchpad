import AppKit
import SwiftUI

@MainActor
func runPagingClarityTests() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    let motion = LauncherPagingMotion(from: 0, target: -400, velocity: -700, startedAt: 0)
    var previous: CGFloat = 0
    for frame in 0...60 {
        let sample60 = motion.sample(at: Double(frame) / 60)
        let sample120 = motion.sample(at: Double(frame * 2) / 120)
        try check(abs(sample60.position - sample120.position) < 0.000001 &&
                  sample60.position <= previous && sample60.position >= -400,
                  "settling follows the same monotonic time-based trajectory at 60 and 120 Hz")
        previous = sample60.position
    }
    try check(abs(motion.sample(at: 0).velocity + 700) < 0.000001,
              "the refresh-driven trajectory starts with the release velocity")

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                          styleMask: .borderless, backing: .buffered, defer: false)
    let viewport = LauncherPagingViewport()
    window.contentView = viewport
    let scale = window.backingScaleFactor
    func stripes() -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            ForEach(0..<20, id: \.self) { index in
                Color.white.frame(width: 1 / scale, height: 50)
                    .offset(x: CGFloat(60 + index * 4), y: 25)
            }
        }.frame(width: 400, height: 100)
    }
    viewport.update(content: AnyView(HStack(spacing: 0) { stripes(); stripes() }),
                    page: 0, width: 400, height: 100, count: 2, animated: false)
    viewport.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    func edgePixels() throws -> (white: Int, mixed: Int) {
        viewport.layoutSubtreeIfNeeded()
        guard let bitmap = viewport.bitmapImageRepForCachingDisplay(in: viewport.bounds) else {
            throw Failure(description: "the sharpness fixture can be rendered")
        }
        viewport.cacheDisplay(in: viewport.bounds, to: bitmap)
        var white = 0, mixed = 0
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) else { continue }
            if color.redComponent > 0.95 { white += 1 }
            else if color.redComponent > 0.05 { mixed += 1 }
        }
        return (white, mixed)
    }
    let original = try edgePixels()
    try check(original.white == 20 && original.mixed == 0, "the reference contains twenty sharp physical-pixel lines")
    _ = viewport.beginTracking(page: 0)
    for offset: CGFloat in [0.1, 0.25, 0.7, 10.25] {
        viewport.track(page: 0, offset: offset)
        let pixels = try edgePixels()
        try check(viewport.precisePosition == offset && pixels.white == original.white && pixels.mixed == 0,
                  "fractional finger input preserves one-pixel edge sharpness instead of blending it into gray pixels")
    }
    viewport.track(page: 0, offset: 0)
    let commits = viewport.positionCommitCount
    for step in 1...20 { viewport.track(page: 0, offset: CGFloat(step) / (100 * scale)) }
    try check(viewport.positionCommitCount == commits && viewport.precisePosition == 0.2 / scale,
              "subpixel input accumulates without redundant view or layer commits")
    viewport.track(page: 0, offset: 0.6 / scale)
    try check(viewport.positionCommitCount == commits + 1 && viewport.displayedPosition == 1 / scale,
              "crossing a backing-pixel boundary commits exactly one sharp position")
    viewport.settle(to: 1, velocity: -700)
    if let animation = viewport.motion {
        for frame in 1...18 {
            viewport.advanceAnimation(at: animation.startedAt + Double(frame) / 60)
            let x = viewport.displayedPosition * scale
            let pixels = try edgePixels()
            try check(abs(x - x.rounded()) < 0.000001 && pixels.mixed == 0 && pixels.white == 20,
                      "all sampled moving frames preserve physical-pixel alignment and sharp edge width")
        }
    }
    viewport.stop()

    // Use two complete 7x5 grids, including image and label shadows. Merely
    // checking a colored rectangle misses the expensive finger-up content swap.
    window.setContentSize(NSSize(width: 400, height: 400))
    let initial = PagingGridBodyCounter()
    let prepared = PagingGridBodyCounter()
    let deferred = PagingGridBodyCounter()
    let icon = NSImage(named: NSImage.folderName)!
    func grid(_ counter: PagingGridBodyCounter) -> AnyView {
        AnyView(PagingDenseGridFixture(counter: counter, icon: icon))
    }
    viewport.update(content: grid(initial), page: 0, width: 400, height: 400, count: 2, animated: false)
    viewport.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    _ = viewport.beginTracking(page: 0)
    viewport.update(content: grid(prepared), page: 0, width: 400, height: 400, count: 2, animated: false, preparedPages: [0, 1])
    viewport.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    try check(prepared.renders > 0, "a first gesture can prepare both full neighboring grids")
    let countBeforeMovement = prepared.renders
    viewport.track(page: 0, offset: -10.25)
    viewport.update(content: grid(deferred), page: 1, width: 400, height: 400, count: 2, animated: true, preparedPages: [0, 1])
    if let animation = viewport.motion {
        for frame in 1...12 { viewport.advanceAnimation(at: animation.startedAt + Double(frame) / 60) }
    }
    viewport.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    try check(prepared.renders == countBeforeMovement && deferred.renders == 0,
              "two full icon grids and their shadows are not rebuilt during release animation")
    let beforeRegrab = viewport.displayedPosition
    _ = viewport.beginTracking(page: viewport.page)
    viewport.track(page: viewport.page, offset: beforeRegrab + CGFloat(viewport.page) * 400 + 8)
    // A delayed SwiftUI update from the previous release must not be mistaken
    // for mounting an unvisited neighbor just because a new drag has begun.
    viewport.update(content: grid(deferred), page: viewport.page, width: 400, height: 400,
                    count: 2, animated: false, preparedPages: [0, 1])
    viewport.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    try check(deferred.renders == 0 && prepared.renders == countBeforeMovement,
              "rapidly re-grabbing a full-grid transition does not flush its pending content diff")
    viewport.stop()
    viewport.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    try check(deferred.renders > 0, "the latest page content and hit regions are applied after movement ends")
    window.orderOut(nil)
    print("PASS: moving-frame edge sharpness, continuous input with pixel-aligned output, time-based settling, and two full 7x5 grids without mid-animation rebuilds")
}

private final class PagingGridBodyCounter { var renders = 0 }

private struct PagingDenseGridFixture: View {
    let counter: PagingGridBodyCounter
    let icon: NSImage
    var body: some View {
        counter.renders += 1
        return HStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { page in
                VStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { column in
                                VStack {
                                    Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                                        .shadow(color: .black.opacity(0.2), radius: 3, y: 4)
                                    Text("应用 \(page * 35 + row * 7 + column)").font(.system(size: 10))
                                        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                                }.frame(width: 400 / 7, height: 80)
                            }
                        }
                    }
                }.frame(width: 400, height: 400)
            }
        }.frame(width: 800, height: 400)
    }
}
