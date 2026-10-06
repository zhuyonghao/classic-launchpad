import AppKit
import CMultitouchBridge

/// The C callback runs on the device's thread. Copy its borrowed memory there,
/// then deliver on the main queue, where both the recognizer and UI are owned.
private enum TrackpadFrameDelivery {
    private static let lock = NSLock()
    private static var handler: ((UInt, [TrackpadContact], Double, TimeInterval) -> Void)?

    static func setHandler(_ newHandler: ((UInt, [TrackpadContact], Double, TimeInterval) -> Void)?) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    static func deliver(device: UInt, contacts: [TrackpadContact], timestamp: Double) {
        let receivedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let receiver = handler
        lock.unlock()
        guard let receiver else { return }
        DispatchQueue.main.async { receiver(device, contacts, timestamp, receivedAt) }
    }
}

@MainActor
final class TrackpadGestureMonitor {
    enum Status {
        case disabled, listening(Int), unavailable

        var title: String {
            switch self {
            case .disabled: return "四指手势：已关闭"
            case .listening(let count): return count > 0 ? "四指手势：触控板已连接" : "四指手势：等待触控板"
            case .unavailable: return "四指手势：当前系统不可用"
            }
        }
    }

    private var recognizers: [UInt: FourFingerGestureRecognizer] = [:]
    private var ignoredSequences: Set<UInt> = []
    private var diagnosticStates: [UInt: String] = [:]
    private var generation = 0
    private var deviceGeneration: UInt64 = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var asleep = false
    private(set) var isEnabled = false
    var isSuspended: () -> Bool = { false }
    var onGesture: (FourFingerGesture) -> Void = { _ in }
    var onStatusChanged: (Status) -> Void = { _ in }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.asleep = true
                self?.stopListening()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.asleep = false
                self?.startListening()
            }
        })
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled { startListening() }
        else { stopListening(); onStatusChanged(.disabled) }
    }

    func invalidate() {
        isEnabled = false
        stopListening()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    private func startListening() {
        guard isEnabled, !asleep, timer == nil else { return }
        generation += 1
        let currentGeneration = generation
        TrackpadFrameDelivery.setHandler { [weak self] device, contacts, timestamp, receivedAt in
            guard let self, self.isEnabled, !self.asleep, self.generation == currentGeneration else { return }
            // A modal loop or a busy main thread must not replay old gestures.
            guard ProcessInfo.processInfo.systemUptime - receivedAt < 0.25 else {
                self.recognizers.removeValue(forKey: device)
                if contacts.isEmpty { self.ignoredSequences.remove(device) }
                else { self.ignoredSequences.insert(device) }
                self.trace(device: device, count: contacts.count, state: "delayed frame")
                return
            }
            self.receive(device: device, contacts: contacts, timestamp: timestamp)
        }
        let count = LPTrackpadStart { device, pointer, count, timestamp in
            guard count >= -1, count <= 32, count <= 0 || pointer != nil else { return }
            let contacts: [TrackpadContact]
            if count == -1 {
                // Corrupt frames are not equivalent to lifting all fingers.
                contacts = [TrackpadContact(id: -1, x: .nan, y: .nan)]
            } else if let pointer {
                contacts = UnsafeBufferPointer(start: pointer, count: Int(count)).map {
                    TrackpadContact(id: $0.identifier, x: $0.x, y: $0.y)
                }
            } else { contacts = [] }
            TrackpadFrameDelivery.deliver(device: device, contacts: contacts, timestamp: timestamp)
        }
        deviceGeneration = LPTrackpadGetDiagnostics().generation
        updateStatus(count)
        guard count >= 0 else {
            TrackpadFrameDelivery.setHandler(nil)
            LPTrackpadStop()
            return
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            // This timer is installed only on RunLoop.main below.
            MainActor.assumeIsolated {
                guard let self, self.isEnabled, !self.asleep else { return }
                let count = LPTrackpadRefresh()
                let generation = LPTrackpadGetDiagnostics().generation
                if generation != self.deviceGeneration {
                    self.deviceGeneration = generation
                    self.recognizers.removeAll()
                    self.ignoredSequences.removeAll()
                }
                self.updateStatus(count)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateStatus(_ count: Int32) {
        onStatusChanged(count >= 0 ? .listening(Int(count)) : .unavailable)
    }

    private func stopListening() {
        generation += 1
        timer?.invalidate()
        timer = nil
        TrackpadFrameDelivery.setHandler(nil)
        LPTrackpadStop()
        recognizers.removeAll()
        ignoredSequences.removeAll()
        diagnosticStates.removeAll()
    }

    private func receive(device: UInt, contacts: [TrackpadContact], timestamp: Double) {
        if contacts.isEmpty { ignoredSequences.remove(device) }
        if isSuspended() {
            if !contacts.isEmpty { ignoredSequences.insert(device) }
            recognizers.removeValue(forKey: device)
            trace(device: device, count: contacts.count, state: "paused for mouse drag or dialog")
            return
        }
        guard !ignoredSequences.contains(device) else {
            trace(device: device, count: contacts.count, state: "waiting for lift")
            return
        }
        var recognizer = recognizers[device] ?? FourFingerGestureRecognizer()
        let gesture = recognizer.process(contacts: contacts, timestamp: timestamp)
        trace(device: device, count: contacts.count, state: gesture.map { String(describing: $0) } ?? recognizer.diagnostic.rawValue)
        if contacts.isEmpty { recognizers.removeValue(forKey: device) }
        else { recognizers[device] = recognizer }
        if let gesture { onGesture(gesture) }
    }

    private func trace(device: UInt, count: Int, state: String) {
        // Record state transitions for diagnosing failed four-finger gestures;
        // never record touch coordinates, identities, or individual frames.
        guard count == 4 || diagnosticStates[device] != nil else { return }
        if diagnosticStates[device] != state {
            NSLog("[Launchpad gesture] fingers=%ld state=%@", count, state)
        }
        if count == 0 { diagnosticStates.removeValue(forKey: device) }
        else { diagnosticStates[device] = state }
    }
}
