import SwiftUI

struct ChatRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var metadataSize: CGFloat = 11
    let chat: ChatInfo

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            AvatarView(
                title: chat.title,
                id: chat.id,
                photoFileId: chat.photoFileId,
                isGroup: chat.isGroup,
                isOnline: chat.isOnline,
                size: 34
            )
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if chat.isChannel {
                        Image(systemName: "megaphone.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(chat.title)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .lineLimit(dynamicTypeSize >= .xxxLarge ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Typing indicator, draft, or last message
                if chat.isTyping {
                    TypingIndicatorView(names: chat.typingUserNames)
                } else if chat.hasDraft {
                    Text("\(L10n.string("Draft:")) \(chat.draftMessage ?? "")")
                        .font(WristTheme.Typography.preview)
                        .foregroundStyle(WristTheme.Palette.draft)
                        .lineLimit(dynamicTypeSize >= .xxxLarge ? 2 : 1)
                } else if let last = chat.lastMessage {
                    HStack(spacing: 2) {
                        if let icon = last.content.systemImage {
                            Image(systemName: icon)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(messagePreview(last))
                            .font(WristTheme.Typography.preview)
                            .foregroundStyle(WristTheme.Palette.secondaryText)
                            .lineLimit(dynamicTypeSize >= .xxxLarge ? 2 : 1)
                    }
                }

                HStack(spacing: 5) {
                    if let date = chat.lastMessage?.date {
                        Text(timeLabel(date))
                            .font(.system(size: metadataSize, design: .rounded))
                            .foregroundStyle(WristTheme.Palette.secondaryText)
                            .lineLimit(1)
                    }
                    if chat.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if chat.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(WristTheme.Palette.secondaryText)
                    }
                    Spacer(minLength: 2)
                    badgeView
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 58)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(chatAccessibilityLabel)
    }

    @ViewBuilder
    private var badgeView: some View {
        switch chat.badgeKind {
        case .mention:
            Image(systemName: "at.circle.fill")
                .font(.system(size: AppConstants.UI.Badge.iconSize))
                .foregroundStyle(.white, chat.isMuted ? Color(white: 0.28) : WristTheme.Palette.unreadBadge)
        case .reaction:
            Image(systemName: "heart.circle.fill")
                .font(.system(size: AppConstants.UI.Badge.iconSize))
                .foregroundStyle(.white, chat.isMuted ? Color(white: 0.28) : WristTheme.Palette.danger)
        case .message(let count):
            Text(count > 99 ? "99+" : "\(count)")
                .font(WristTheme.Typography.badge)
                .foregroundStyle(.white)
                .padding(.horizontal, AppConstants.UI.Badge.horizontalPadding)
                .padding(.vertical, AppConstants.UI.Badge.verticalPadding)
                .frame(minWidth: 18, minHeight: 18)
                .background(chat.isMuted ? Color(white: 0.28) : WristTheme.Palette.unreadBadge, in: Capsule())
        case .none:
            EmptyView()
        }
    }

    private var chatAccessibilityLabel: String {
        var parts = [chat.title]
        if chat.isPinned {
            parts.append(L10n.string("Pinned"))
        }
        if chat.mentionCount > 0 {
            parts.append(L10n.string("mentioned"))
        } else if chat.reactionCount > 0 {
            parts.append(L10n.string("new reaction"))
        }
        if chat.unreadCount > 0 {
            parts.append(L10n.format("%lld unread", Int64(chat.unreadCount)))
        }
        if chat.isTyping {
            parts.append(L10n.string("typing..."))
        } else if chat.hasDraft {
            parts.append("\(L10n.string("Draft:")) \(chat.draftMessage ?? "")")
        } else if let last = chat.lastMessage {
            parts.append(messagePreview(last).speakingSpoilerMasks)
        }
        return parts.joined(separator: ", ")
    }

    private func messagePreview(_ message: MessageInfo) -> String {
        guard chat.isGroup, !chat.isChannel else { return message.content.textPreview }
        let sender = message.isOutgoing
            ? L10n.string("You")
            : String(message.senderName.split(separator: " ").first ?? "")
        guard !sender.isEmpty else { return message.content.textPreview }
        return "\(sender): \(message.content.textPreview)"
    }

    private func timeLabel(_ date: Date) -> String {
        TimeFormatting.chatTimestamp(date)
    }
}
