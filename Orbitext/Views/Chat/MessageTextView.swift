import SwiftUI

/// Renders FormattedString.attributedString. When the payload contains
/// spoiler ranges we overlay a blurred slab that reveals the content
/// on tap (replaces the earlier Braille-block hack).
struct MessageTextView: View {
    let formatted: FormattedString
    let isOutgoing: Bool

    @State private var isLocallyRevealed = false
    @State private var isExpanded = false
    @State private var heights = MessageTextHeights()
    @Environment(\.spoilerReveal) private var sharedReveal

    private var isRevealed: Bool { sharedReveal?.wrappedValue ?? isLocallyRevealed }
    private var isSpoilerHidden: Bool { formatted.hasSpoiler && !isRevealed }
    private var lineLimit: Int? { isExpanded ? nil : AppConstants.Message.collapsedLineLimit }

    var body: some View {
        let attributed = formatted.attributedString
        let textColor: Color = isOutgoing ? .white : WristTheme.Palette.primaryText

        VStack(alignment: .leading, spacing: 2) {
            text(attributed, color: textColor)
            if isExpanded || heights.isTruncated {
                Button(isExpanded ? L10n.string("Show less") : L10n.string("Show more")) {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isOutgoing ? .white : WristTheme.Palette.accent)
                .buttonStyle(.plain)
            }
        }
    }

    private func text(_ attributed: AttributedString, color textColor: Color) -> some View {
        ZStack(alignment: .topLeading) {
            Text(attributed)
                .font(.caption2)
                .foregroundStyle(textColor)
                .lineLimit(lineLimit)
                .opacity(isSpoilerHidden ? 0 : 1)
                // A hidden link must not open before the spoiler is revealed.
                .allowsHitTesting(!isSpoilerHidden)
                .accessibilityHidden(isSpoilerHidden)

            if isSpoilerHidden {
                Text(formatted.text)
                    .font(.caption2)
                    .foregroundStyle(.clear)
                    .lineLimit(lineLimit)
                    .padding(.horizontal, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.gray.opacity(0.6))
                            .blur(radius: 3)
                    )
                    .accessibilityLabel(formatted.maskingSpoilers.text.speakingSpoilerMasks)
                    .accessibilityActions {
                        // A container that owns the reveal (MessageRow) offers
                        // this action itself; avoid a duplicate in its element.
                        if sharedReveal == nil {
                            Button(L10n.string("Show spoiler")) { reveal() }
                        }
                    }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { reveal() }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.shown = $0 }
        .background(alignment: .topLeading) {
            // The whole text, laid out but never drawn, says whether the
            // shown lines cut it.
            Text(attributed)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.full = $0 }
        }
    }

    private func reveal() {
        guard formatted.hasSpoiler else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            if let sharedReveal {
                sharedReveal.wrappedValue = true
            } else {
                isLocallyRevealed = true
            }
        }
    }
}

/// Heights of a message text as shown and as a whole.
struct MessageTextHeights: Equatable {
    var shown: CGFloat = 0
    var full: CGFloat = 0

    /// Whether lines are cut: the whole text is taller than what is shown.
    /// Half a point of slack absorbs rounding between the two layouts.
    var isTruncated: Bool { full > shown + 0.5 }
}

private struct SpoilerRevealKey: EnvironmentKey {
    static let defaultValue: Binding<Bool>? = nil
}

extension EnvironmentValues {
    /// Reveal state owned by a container such as MessageRow, so its
    /// VoiceOver label and the visual cover change together.
    var spoilerReveal: Binding<Bool>? {
        get { self[SpoilerRevealKey.self] }
        set { self[SpoilerRevealKey.self] = newValue }
    }
}
