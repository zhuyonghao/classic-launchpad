import AppKit

@MainActor
func runIconInteractionTests() throws {
    struct Failure: Error { let message: String }
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
                          styleMask: .borderless, backing: .buffered, defer: false)
    let view = LauncherIconInteractionView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
    window.contentView = view
    view.itemID = "test-icon"
    view.activationSize = NSSize(width: 100, height: 110)
    var presses: [Bool] = []
    var activations = 0
    var blankClicks = 0
    view.onPressedChanged = { presses.append($0) }
    view.onActivate = { activations += 1 }
    view.onBlankClick = { blankClicks += 1 }
    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    let icon = NSPoint(x: 100, y: 50)
    let gap = NSPoint(x: 15, y: 50)
    view.mouseDown(with: event(.leftMouseDown, icon))
    try check(presses == [true] && activations == 0, "press feedback precedes activation")
    view.mouseUp(with: event(.leftMouseUp, icon))
    try check(presses == [true, false] && activations == 1, "release clears feedback and activates once")
    view.mouseUp(with: event(.leftMouseUp, icon))
    try check(activations == 1, "a stray mouse-up cannot activate an icon")

    presses = []
    view.mouseDown(with: event(.leftMouseDown, gap))
    view.mouseUp(with: event(.leftMouseUp, gap))
    try check(presses.isEmpty && activations == 1 && blankClicks == 1,
              "animation does not extend icon hit areas into gaps")

    view.mouseDown(with: event(.leftMouseDown, icon))
    view.mouseUp(with: event(.leftMouseUp, NSPoint(x: 250, y: 50)))
    try check(presses == [true, false] && activations == 1 && blankClicks == 1,
              "release outside the tile cancels feedback without launching")

    // A movement within the click tolerance must still produce a normal click.
    presses = []
    view.mouseDown(with: event(.leftMouseDown, icon))
    view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 102, y: 50)))
    view.mouseUp(with: event(.leftMouseUp, NSPoint(x: 102, y: 50)))
    try check(presses == [true, false] && activations == 2, "small pointer motion retains click feedback")

    // Moving out of the content by less than the drag threshold clears the press.
    presses = []
    view.mouseDown(with: event(.leftMouseDown, NSPoint(x: 51, y: 50)))
    view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 49, y: 50)))
    view.mouseUp(with: event(.leftMouseUp, NSPoint(x: 49, y: 50)))
    try check(presses == [true, false] && activations == 2 && blankClicks == 2,
              "leaving icon content cancels press feedback and returns from the gap")
    print("PASS: native click feedback, gap hit areas, outside release, pointer tolerance, and single activation")
}
