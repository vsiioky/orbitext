import XCTest
@testable import OrbitextWatch

/// UserInfo(tdApi:) on TDLib 1.8.64 user JSON (TDJSONSample.user).
final class UserInfoMappingTests: XCTestCase {
    private typealias Sample = TDJSONSample

    private func info(_ json: String) -> UserInfo {
        UserInfo(tdApi: TDApi.decodeUser(Sample.object(json)))
    }

    // MARK: - Names

    func testNamesAndIdAreCopied() {
        let user = info(Sample.user(id: 1002, firstName: "John", lastName: "Doe", phone: "15551234567"))

        XCTAssertEqual(user.id, 1002)
        XCTAssertEqual(user.firstName, "John")
        XCTAssertEqual(user.lastName, "Doe")
        XCTAssertEqual(user.phoneNumber, "15551234567")
        XCTAssertEqual(user.fullName, "John Doe")
        XCTAssertEqual(user.displayName, "John Doe")
    }

    func testFullNameSkipsAnEmptyPart() {
        XCTAssertEqual(info(Sample.user(id: 1, firstName: "Mononym")).fullName, "Mononym")
        XCTAssertEqual(info(Sample.user(id: 1, firstName: "", lastName: "Surname")).fullName, "Surname")
    }

    func testUserWithoutNamesHasAnEmptyFullNameAndNoDisplayName() {
        let user = info(Sample.user(id: 1, firstName: ""))

        XCTAssertEqual(user.fullName, "")
        XCTAssertNil(user.displayName)
    }

    // MARK: - Usernames

    private func usernames(active: [String], editable: String = "") -> String {
        let list = active.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"@type":"usernames","active_usernames":[\(list)],"disabled_usernames":[],\
        "editable_username":"\(editable)","collectible_usernames":[]}
        """
    }

    func testActiveUsernameIsTheFirstActiveOne() {
        let user = info(Sample.user(
            id: 1, firstName: "Bot", usernames: usernames(active: ["primary_bot", "second_bot"], editable: "second_bot")
        ))

        XCTAssertEqual(user.activeUsername, "primary_bot")
        XCTAssertEqual(user.editableUsername, "second_bot")
    }

    func testActiveUsernameIsNilWhenThereIsNoUsableOne() {
        XCTAssertNil(info(Sample.user(id: 1, firstName: "A", usernames: usernames(active: []))).activeUsername)
        XCTAssertNil(info(Sample.user(id: 1, firstName: "A", usernames: usernames(active: [""]))).activeUsername)
    }

    func testUserWithoutUsernamesObjectHasNoUsernames() {
        var json = Sample.object(Sample.user(id: 1, firstName: "A"))
        json.removeValue(forKey: "usernames")

        let user = UserInfo(tdApi: TDApi.decodeUser(json))

        XCTAssertNil(user.activeUsername)
        XCTAssertEqual(user.editableUsername, "")
    }

    // MARK: - Bot

    func testOnlyABotTypeIsABot() {
        let bot = "{\"@type\":\"userTypeBot\",\"can_join_groups\":true,\"can_read_all_group_messages\":false}"

        XCTAssertTrue(info(Sample.user(id: 1, firstName: "B", type: bot)).isBot)
        XCTAssertFalse(info(Sample.user(id: 1, firstName: "R", type: "{\"@type\":\"userTypeRegular\"}")).isBot)
        XCTAssertFalse(info(Sample.user(id: 1, firstName: "D", type: "{\"@type\":\"userTypeDeleted\"}")).isBot)
        XCTAssertFalse(info(Sample.user(id: 1, firstName: "F", type: "{\"@type\":\"userTypeFuture\"}")).isBot)
    }

    func testUserWithoutATypeIsNotABot() {
        var json = Sample.object(Sample.user(id: 1, firstName: "A"))
        json.removeValue(forKey: "type")

        XCTAssertFalse(UserInfo(tdApi: TDApi.decodeUser(json)).isBot)
    }

    // MARK: - Profile photo

    func testProfilePhotoIsTheSmallFileId() {
        XCTAssertEqual(info(Sample.user(id: 1, firstName: "A", profilePhotoSmallId: 9_081)).profilePhotoFileId, "9081")
        XCTAssertNil(info(Sample.user(id: 1, firstName: "A")).profilePhotoFileId)
    }

    // MARK: - Status

    func testStatusKinds() {
        let online = info(Sample.user(id: 1, firstName: "A", status: "{\"@type\":\"userStatusOnline\",\"expires\":1760000300}"))
        let offline = info(Sample.user(id: 1, firstName: "A", status: "{\"@type\":\"userStatusOffline\",\"was_online\":1759990000}"))
        let recently = info(Sample.user(id: 1, firstName: "A", status: "{\"@type\":\"userStatusRecently\",\"by_my_privacy_settings\":false}"))
        let empty = info(Sample.user(id: 1, firstName: "A", status: "{\"@type\":\"userStatusEmpty\"}"))
        let future = info(Sample.user(id: 1, firstName: "A", status: "{\"@type\":\"userStatusFuture\"}"))

        XCTAssertEqual(online.status, .online)
        XCTAssertTrue(online.status.isOnline)
        XCTAssertEqual(offline.status, .offline(since: Date(timeIntervalSince1970: 1_759_990_000)))
        XCTAssertFalse(offline.status.isOnline)
        XCTAssertEqual(recently.status, .unavailable)
        XCTAssertEqual(empty.status, .unavailable)
        XCTAssertEqual(future.status, .unavailable)
    }

    func testOfflineStatusWithoutADateHasNone() {
        let user = info(Sample.user(id: 1, firstName: "A", status: "{\"@type\":\"userStatusOffline\"}"))

        XCTAssertEqual(user.status, .offline(since: nil))
    }

    // MARK: - ContactInfo

    func testContactInfoCarriesTheCardFields() {
        let user = info(Sample.user(
            id: 456,
            firstName: "John",
            lastName: "Doe",
            status: "{\"@type\":\"userStatusOffline\",\"was_online\":1759990000}",
            usernames: usernames(active: ["johnny"], editable: "johnny"),
            phone: "15551234567",
            profilePhotoSmallId: 77
        ))

        XCTAssertEqual(ContactInfo(user: user), ContactInfo(
            id: 456,
            firstName: "John",
            lastName: "Doe",
            phone: "15551234567",
            username: "johnny",
            photoFileId: "77",
            isOnline: false,
            lastSeen: Date(timeIntervalSince1970: 1_759_990_000)
        ))
    }
}
