import SwiftUI

struct LauncherTileFeedbackActions {
    let activate: () -> Void
    let setPressed: (Bool) -> Void
}

/// Keep click state inside one tile. The native event surface stays full-sized
/// while the visual content animates, so spacing and drag hit areas do not move.
struct LauncherTileFeedback<Content: View, Interaction: View>: View {
    let isFolder: Bool
    let isActive: Bool
    let anchor: UnitPoint
    let onActivate: () -> Void
    private let content: Content
    private let interaction: (LauncherTileFeedbackActions) -> Interaction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    @State private var isActivating = false
    private static var activationDuration: Double { 0.14 }

    init(isFolder: Bool, isActive: Bool, anchor: UnitPoint, onActivate: @escaping () -> Void,
         @ViewBuilder content: () -> Content,
         @ViewBuilder interaction: @escaping (LauncherTileFeedbackActions) -> Interaction) {
        self.isFolder = isFolder
        self.isActive = isActive
        self.anchor = anchor
        self.onActivate = onActivate
        self.content = content()
        self.interaction = interaction
    }

    private var scale: CGFloat {
        if reduceMotion { return 1 }
        if isActivating { return isFolder ? 1.04 : 1.10 }
        return isPressed ? 0.91 : 1
    }

    private var opacity: Double {
        if isActivating && !isFolder && !reduceMotion { return 0.35 }
        return isPressed ? 0.82 : 1
    }

    var body: some View {
        content
            .scaleEffect(scale, anchor: anchor)
            .opacity(opacity)
            .overlay {
                interaction(.init(activate: activate, setPressed: setPressed))
            }
            .task(id: isActivating && isActive) {
                guard isActivating && isActive else { return }
                if !reduceMotion {
                    do { try await Task.sleep(for: .seconds(Self.activationDuration)) }
                    catch { return }
                }
                guard !Task.isCancelled else { return }
                onActivate()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    isActivating = false
                }
            }
            .onChange(of: isActive) { _, active in
                if !active { reset() }
            }
            .onDisappear { reset() }
    }

    private func setPressed(_ pressed: Bool) {
        guard isActive, !isActivating, isPressed != pressed else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.08)) {
            isPressed = pressed
        }
    }

    private func activate() {
        guard isActive, !isActivating else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: Self.activationDuration)) {
            isPressed = false
            isActivating = true
        }
    }

    private func reset() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPressed = false
            isActivating = false
        }
    }
}
