import SwiftUI

/// Animate only the icon artwork. The native click surface and label stay fixed,
/// and retained pages stop cycling as soon as they become inactive.
struct LauncherBatchIconFeedback: ViewModifier {
    let id: String
    let isOrganizing: Bool
    let isSelected: Bool
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var seed: Int { id.utf8.reduce(0) { ($0 + Int($1)) % 7 } }
    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.58)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if isOrganizing {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.4))
                        .scaleEffect(isSelected && !reduceMotion ? 1.12 : 1)
                        .animation(selectionAnimation, value: isSelected)
                        .padding(2)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .modifier(LauncherBatchWiggle(isEnabled: isOrganizing && isActive && !reduceMotion, seed: seed))
            .scaleEffect(isOrganizing && isSelected && !reduceMotion ? 1.045 : 1)
            .animation(selectionAnimation, value: isSelected)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isOrganizing)
    }
}

private struct LauncherBatchWiggle: ViewModifier {
    let isEnabled: Bool
    let seed: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            // Mount a fresh two-phase animator on entry. Changing a mounted
            // single-phase animator's phases can leave it at a static angle.
            // Only artwork changes identity; the native event surface survives.
            content.phaseAnimator([-1.0, 1.0]) { icon, phase in
                icon.rotationEffect(.degrees(phase * (seed.isMultiple(of: 2) ? 2.2 : -2.2)))
                    .offset(y: phase * 0.35)
            } animation: { _ in
                .easeInOut(duration: 0.14 + Double(seed % 3) * 0.015)
            }
        } else {
            content
        }
    }
}
