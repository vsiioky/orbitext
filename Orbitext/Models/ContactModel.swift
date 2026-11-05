import Foundation

struct ContactInfo: Identifiable, Equatable, Hashable, Codable {
    let id: Int64
    var firstName: String
    var lastName: String
    var phone: String
    var username: String
    var photoFileId: String?
    var isOnline: Bool
    var lastSeen: Date?

    var fullName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var statusText: String {
        if isOnline { return "online" }
        guard let lastSeen else { return "last seen recently" }
        let cal = Calendar.current
        if cal.isDateInToday(lastSeen) {
            return "last seen \(lastSeen.formatted(date: .omitted, time: .shortened))"
        } else if cal.isDateInYesterday(lastSeen) {
            return "last seen yesterday"
        } else {
            return "last seen \(lastSeen.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }
}
