import SwiftUI
import WidgetKit

// MARK: - Configuration

/// App-group identifier shared with the main Orbitext target.
///
/// MUST stay in sync with `AppConstants.App.widgetSuite` in the main app
/// (Orbitext/App/AppConstants.swift) and with the entitlements declared
/// for both targets in `project.yml`. The widget target compiles
/// separately and cannot import AppConstants, so the literal is duplicated
/// here; if the suite ever changes, update all three call sites at once.
private let widgetAppGroupSuite = "group.com.orbitext.shared"

/// URL scheme shared with the host app. Tapping a complication / widget
/// delivers this URL via `.onOpenURL` in OrbitextApp, which routes via
/// AppRouter.openChat(chatId).
private let widgetDeepLinkScheme = "orbitext"

private func chatDeepLinkURL(chatId: Int64) -> URL? {
    URL(string: "\(widgetDeepLinkScheme)://chat/\(chatId)")
}

// MARK: - Timeline Entry

struct UnreadEntry: TimelineEntry {
    let date: Date
    let unreadCount: Int
    let lastChatName: String?
    let lastMessagePreview: String?
    let lastChatId: Int64?
}

// MARK: - Timeline Provider

struct UnreadProvider: TimelineProvider {
    func placeholder(in context: Context) -> UnreadEntry {
        UnreadEntry(date: .now, unreadCount: 3, lastChatName: "Alice", lastMessagePreview: "See you!", lastChatId: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadEntry) -> Void) {
        let entry = loadEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadEntry>) -> Void) {
        let entry = loadEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadEntry() -> UnreadEntry {
        let defaults = UserDefaults(suiteName: widgetAppGroupSuite) ?? .standard
        let rawChatId = defaults.object(forKey: "lastChatId") as? Int64
        return UnreadEntry(
            date: .now,
            unreadCount: defaults.integer(forKey: "totalUnread"),
            lastChatName: defaults.string(forKey: "lastChatName"),
            lastMessagePreview: defaults.string(forKey: "lastMessagePreview"),
            lastChatId: rawChatId
        )
    }
}

// MARK: - Widget Views

struct UnreadWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: UnreadEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circularView
            case .accessoryCorner:
                cornerView
            case .accessoryRectangular:
                rectangularView
            case .accessoryInline:
                inlineView
            default:
                circularView
            }
        }
        .widgetURL(entry.lastChatId.flatMap(chatDeepLinkURL(chatId:)))
    }

    // MARK: - Circular

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12))
                if entry.unreadCount > 0 {
                    Text("\(entry.unreadCount)")
                        .font(.system(size: 14, weight: .bold))
                } else {
                    Text("0")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Corner

    private var cornerView: some View {
        Image(systemName: "bubble.left.fill")
            .font(.title3)
            .widgetLabel {
                if entry.unreadCount > 0 {
                    Text("\(entry.unreadCount) \(String(localized: "unread"))")
                } else {
                    Text("Orbitext")
                }
            }
    }

    // MARK: - Rectangular

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "bubble.left.fill")
                    .font(.caption2)
                Text("Orbitext")
                    .font(.caption2.bold())
                Spacer()
                if entry.unreadCount > 0 {
                    Text("\(entry.unreadCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.29))
                }
            }

            if let chatName = entry.lastChatName {
                Text(chatName)
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .privacySensitive()
            } else if entry.unreadCount == 0 {
                Text(String(localized: "No new messages"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let preview = entry.lastMessagePreview {
                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Redacted when the system applies privacy redaction (locked watch).
                    .privacySensitive()
            }
        }
    }

    // MARK: - Inline

    private var inlineView: some View {
        HStack(spacing: 4) {
            Image(systemName: "bubble.left.fill")
            if entry.unreadCount > 0 {
                Text("\(entry.unreadCount) \(String(localized: "unread"))")
            } else {
                Text(String(localized: "No new messages"))
            }
        }
    }
}

// MARK: - Widget Configuration

@main
struct OrbitextWidget: Widget {
    let kind = "OrbitextUnread"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UnreadProvider()) { entry in
            UnreadWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Orbitext")
        .description(String(localized: "Unread messages and latest chat"))
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

// MARK: - Preview

#Preview(as: .accessoryCircular) {
    OrbitextWidget()
} timeline: {
    UnreadEntry(date: .now, unreadCount: 5, lastChatName: "Alice", lastMessagePreview: "See you!", lastChatId: 42)
    UnreadEntry(date: .now, unreadCount: 0, lastChatName: nil, lastMessagePreview: nil, lastChatId: nil)
}
