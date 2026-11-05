import SwiftUI

enum WristTheme {
    enum Palette {
        static let canvas = Color(red: 0.02, green: 0.025, blue: 0.03)
        static let surface = Color.white.opacity(0.075)
        static let raisedSurface = Color.white.opacity(0.12)
        static let mutedSurface = Color.white.opacity(0.055)
        static let separator = Color.white.opacity(0.10)
        static let control = Color.white.opacity(0.16)
        static let controlPressed = Color.white.opacity(0.22)
        static let noticeBackground = Color(red: 0.16, green: 0.17, blue: 0.19)

        static let primaryText = Color.primary
        static let secondaryText = Color.secondary
        static let tertiaryText = Color.secondary.opacity(0.72)

        static let accent = Color(red: 0.08, green: 0.62, blue: 0.95)
        static let accentSoft = Color(red: 0.08, green: 0.62, blue: 0.95).opacity(0.24)
        static let unreadBadge = Color(red: 0.02, green: 0.40, blue: 0.72)
        static let incomingBubble = Color.white.opacity(0.14)
        static let outgoingBubble = Color(red: 0.02, green: 0.47, blue: 0.82)
        static let outgoingBubblePending = Color(red: 0.02, green: 0.47, blue: 0.82).opacity(0.62)

        static let draft = Color(red: 1.0, green: 0.45, blue: 0.20)
        static let warning = Color(red: 1.0, green: 0.68, blue: 0.18)
        static let warningHighlight = Color(red: 1.0, green: 0.86, blue: 0.26)
        static let danger = Color(red: 1.0, green: 0.22, blue: 0.22)
        static let dangerHighlight = Color(red: 1.0, green: 0.42, blue: 0.58)
        static let success = Color(red: 0.18, green: 0.84, blue: 0.44)
        static let voice = Color(red: 1.0, green: 0.18, blue: 0.36)

        static let avatarColors: [Color] = [
            Color(red: 0.10, green: 0.55, blue: 0.90),
            Color(red: 0.06, green: 0.68, blue: 0.58),
            Color(red: 0.86, green: 0.50, blue: 0.16),
            Color(red: 0.62, green: 0.40, blue: 0.90),
            Color(red: 0.88, green: 0.30, blue: 0.50),
            Color(red: 0.80, green: 0.28, blue: 0.24),
            Color(red: 0.24, green: 0.62, blue: 0.72)
        ]

        static func avatarColor(for id: Int64) -> Color {
            let index = Int(id.magnitude % UInt64(avatarColors.count))
            return avatarColors[index]
        }
    }

    enum Typography {
        static let rowTitle = Font.system(.headline, design: .rounded).weight(.semibold)
        static let rowMeta = Font.system(.caption2, design: .rounded)
        static let preview = Font.system(.caption2, design: .rounded)
        static let badge = Font.system(.caption2, design: .rounded).weight(.bold)
        static let capsule = Font.system(.caption2, design: .rounded).weight(.semibold)
        static let screenTitle = Font.system(.headline, design: .rounded).weight(.bold)
        static let detail = Font.system(.caption2, design: .rounded)
    }
}

/// The material samples a quiet colour field behind the list. Text and avatars
/// stay above the material and remain sharp as cards move under the system header.
struct WristGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var cornerRadius: CGFloat = 24
    var isSelected = false
    var tint: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color(white: isSelected ? 0.22 : 0.14))
            } else {
                shape.fill(.ultraThinMaterial)
                    .overlay {
                        shape.fill(LinearGradient(
                            colors: [.white.opacity(0.075), .white.opacity(0.015)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    }
            }
        }
        .overlay {
            if let tint {
                shape.fill(tint.opacity(reduceTransparency ? 0.3 : 0.18))
            }
        }
        .overlay {
            shape.strokeBorder(
                isSelected ? WristTheme.Palette.accent.opacity(0.7) : .white.opacity(contrast == .increased ? 0.4 : 0.14),
                lineWidth: isSelected || contrast == .increased ? 1 : 0.5
            )
        }
        .accessibilityHidden(true)
    }
}

struct WristScreenBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            WristTheme.Palette.canvas
            if !reduceTransparency {
                RadialGradient(
                    colors: [Color(red: 0.12, green: 0.28, blue: 0.40).opacity(0.7), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 220
                )
                RadialGradient(
                    colors: [Color(red: 0.20, green: 0.17, blue: 0.32).opacity(0.4), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 170
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// Apply to the List itself, leaving row layout and navigation native.
    func wristListStyle() -> some View {
        listStyle(.carousel)
            .scrollContentBackground(.hidden)
            .background { WristScreenBackground() }
    }

    func wristGlassRow(cornerRadius: CGFloat = 24) -> some View {
        listRowBackground(WristGlassBackground(cornerRadius: cornerRadius))
    }

    /// For a TextField row. The system field draws its own gray platter;
    /// inside an inset glass row it read as a small capsule floating in a
    /// bigger one, so the field fills the row instead.
    func wristFieldRow() -> some View {
        clipShape(Capsule())
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
}

/// Reusable full-width watch action with a stable touch target.
struct WristGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WristTheme.Typography.capsule)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background { WristGlassBackground(cornerRadius: 22, tint: tint) }
            .contentShape(Capsule())
            .opacity(!isEnabled ? 0.45 : (configuration.isPressed ? 0.72 : 1))
    }
}
