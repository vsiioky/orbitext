import Foundation

/// What the transport remembers of a TDLib user between requests: the user
/// cache holds one per user seen through updateUser, getUser and getMe. It
/// carries what names, contact cards, presence and bot lookups read; the rest
/// of the TDLib user is dropped when it is mapped (Mappings/User+Mapping.swift).
struct UserInfo: Equatable, Sendable {
    /// Presence, reduced to what the UI shows: online, offline since a date
    /// (when TDLib gave one) or hidden/unknown ("recently", "last week", ...).
    enum Status: Equatable, Sendable {
        case online
        case offline(since: Date?)
        case unavailable

        var isOnline: Bool { self == .online }
    }

    let id: Int64
    let firstName: String
    let lastName: String
    let phoneNumber: String
    /// The username the user edits, shown on the contact card.
    let editableUsername: String
    /// The public username a bot command is addressed to, if any.
    let activeUsername: String?
    /// Small profile photo file, as the string id the image cache takes.
    let profilePhotoFileId: String?
    var status: Status
    let isBot: Bool

    /// First and last name joined; empty when the user has neither.
    var fullName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `fullName`, or nil when the user has no name to show.
    var displayName: String? {
        let name = fullName
        return name.isEmpty ? nil : name
    }
}
