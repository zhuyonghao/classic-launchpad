import SwiftUI

enum LauncherDropPlacement: Equatable {
    case before, after, merge

    static func resolve(horizontalFraction: CGFloat, inFolder: Bool) -> Self {
        if inFolder { return horizontalFraction > 0.5 ? .after : .before }
        if horizontalFraction < 0.25 { return .before }
        if horizontalFraction > 0.75 { return .after }
        return .merge
    }
}

enum LauncherDropTarget: Equatable {
    case item(String, LauncherDropPlacement)
    case slot(Int)

    func placement(for id: String) -> LauncherDropPlacement? {
        guard case let .item(targetID, placement) = self, targetID == id else { return nil }
        return placement
    }
}

struct LauncherInsertionIndicator: View {
    let placement: LauncherDropPlacement?
    let height: CGFloat

    var body: some View {
        HStack {
            if placement == .after { Spacer() }
            if placement == .before || placement == .after {
                Capsule().fill(.white)
                    .frame(width: 3, height: height)
                    .shadow(color: .cyan.opacity(0.8), radius: 5)
            }
            if placement == .before { Spacer() }
        }
        .padding(.horizontal, 5)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct LauncherEmptySlotFeedback: View {
    let isTargeted: Bool
    let iconSize: CGFloat

    var body: some View {
        if isTargeted {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 19)
                    .fill(.white.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 19)
                        .strokeBorder(.white.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    .overlay(Image(systemName: "plus").font(.system(size: 24, weight: .light)).foregroundStyle(.white.opacity(0.9)))
                    .frame(width: iconSize + 10, height: iconSize + 10)
                Text("放在这里").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
