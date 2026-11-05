import Foundation

struct ChatTimelineSection: Identifiable, Equatable {
    let item: ChatItem
    let showsDateSeparator: Bool

    var id: String {
        item.id
    }

    static func build(from messages: [MessageInfo], calendar: Calendar = .current) -> [ChatTimelineSection] {
        var previousDate: Date?
        return MessageAlbumInfo.group(messages).map { item in
            // Date separator anchors on the first message of the group
            // (album or singleton) so it lines up above the bubble rather
            // than between sibling photos.
            let showsDateSeparator = previousDate == nil || !calendar.isDate(previousDate!, inSameDayAs: item.date)
            previousDate = item.date
            return ChatTimelineSection(item: item, showsDateSeparator: showsDateSeparator)
        }
    }
}
