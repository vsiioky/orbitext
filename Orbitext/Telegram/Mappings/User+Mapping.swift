import Foundation

// MARK: - UserInfo from typed TDApi

extension UserInfo.Status {
    init(tdApi status: TDApi.UserStatus?) {
        switch status {
        case .userStatusOnline?:
            self = .online
        case .userStatusOffline(let offline)?:
            self = .offline(since: offline.wasOnline > 0 ? Date(timeIntervalSince1970: TimeInterval(offline.wasOnline)) : nil)
        case .userStatusEmpty?, .userStatusRecently?, .userStatusLastWeek?, .userStatusLastMonth?, .unknown?, nil:
            self = .unavailable
        }
    }
}

extension UserInfo {
    init(tdApi user: TDApi.User) {
        let smallPhoto = user.profilePhoto?.small
        var isBot = false
        if case .userTypeBot? = user.type { isBot = true }
        self.init(
            id: user.id,
            firstName: user.firstName,
            lastName: user.lastName,
            phoneNumber: user.phoneNumber,
            editableUsername: user.usernames?.editableUsername ?? "",
            activeUsername: user.usernames?.activeUsernames.first.flatMap { $0.isEmpty ? nil : $0 },
            profilePhotoFileId: smallPhoto.map { "\($0.id)" },
            status: Status(tdApi: user.status),
            isBot: isBot
        )
    }
}

extension ContactInfo {
    init(user: UserInfo) {
        var lastSeen: Date?
        if case .offline(let since) = user.status { lastSeen = since }
        self.init(
            id: user.id,
            firstName: user.firstName,
            lastName: user.lastName,
            phone: user.phoneNumber,
            username: user.editableUsername,
            photoFileId: user.profilePhotoFileId,
            isOnline: user.status.isOnline,
            lastSeen: lastSeen
        )
    }
}
