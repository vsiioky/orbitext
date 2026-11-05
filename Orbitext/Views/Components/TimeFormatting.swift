import Foundation

enum TimeFormatting {
    static func chatTimestamp(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if cal.isDateInYesterday(date) {
            return L10n.string("Yesterday")
        } else {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    static func dateSeparator(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L10n.string("Today") }
        if cal.isDateInYesterday(date) { return L10n.string("Yesterday") }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func duration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        duration(Int(seconds))
    }

    static func clockDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
