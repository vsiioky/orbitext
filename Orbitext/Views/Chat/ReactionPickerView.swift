import SwiftUI

struct ReactionsBar: View {
    let reactions: [ReactionInfo]
    let onTap: (String) -> Void

    var body: some View {
        if !reactions.isEmpty {
            FlowLayout(spacing: 4, lineSpacing: 3) {
                ForEach(reactions) { reaction in
                    reactionCapsule(for: reaction)
                }
            }
        }
    }

    @ViewBuilder
    private func reactionCapsule(for reaction: ReactionInfo) -> some View {
        let label = HStack(spacing: 2) {
            Text(reaction.emoji)
                .font(.system(size: AppConstants.UI.FontSize.body))
            Text("\(reaction.count)")
                .font(.system(size: AppConstants.UI.FontSize.tiny, weight: .medium))
                .foregroundStyle(reaction.isSelected ? WristTheme.Palette.primaryText : WristTheme.Palette.secondaryText)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(reaction.isSelected ? WristTheme.Palette.accentSoft : .white.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(reaction.isSelected ? 0.3 : 0.12), lineWidth: 0.5))

        if let actionValue = reaction.actionValue {
            Button {
                onTap(actionValue)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("%@ reaction, %lld", reaction.emoji, Int64(reaction.count)))
        } else {
            label
        }
    }
}
