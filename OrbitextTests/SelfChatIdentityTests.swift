import XCTest
@testable import OrbitextWatch

final class SelfChatIdentityTests: XCTestCase {
    func testServiceWithoutKnownIdentityNeverRecognizesSelfChat() {
        let service: any TelegramServiceProtocol = MockTelegramService()
        XCTAssertNil(service.currentUserID)
        XCTAssertFalse(service.isSelfChat(chatId: 0))
        XCTAssertFalse(service.isSelfChat(chatId: 42))
    }

    func testNativeCachedIdentityTracksKnownUserAndReset() throws {
        let native = try makeService()
        let service: any TelegramServiceProtocol = native
        XCTAssertNil(service.currentUserID)
        XCTAssertFalse(service.isSelfChat(chatId: 0))

        native.myUserId = 42
        XCTAssertEqual(service.currentUserID, 42)
        XCTAssertTrue(service.isSelfChat(chatId: 42))

        native.myUserId = 0
        XCTAssertNil(service.currentUserID)
        XCTAssertFalse(service.isSelfChat(chatId: 42))
    }

    func testChatTitleCannotGrantOrRemoveSelfIdentity() throws {
        let service = try makeService()
        service.myUserId = 42
        let selfChat = ChatInfo(id: 42, title: "My private notes", lastMessage: nil, unreadCount: 0,
                                photoFileId: nil, isGroup: false, isMuted: false, order: 1)
        let otherChat = ChatInfo(id: 43, title: "Saved Messages", lastMessage: nil, unreadCount: 0,
                                 photoFileId: nil, isGroup: false, isMuted: false, order: 1)
        XCTAssertTrue(service.isSelfChat(chatId: selfChat.id))
        XCTAssertFalse(service.isSelfChat(chatId: otherChat.id))
    }

    func testLateIdentityFromReplacedOrClosedClientIsRejected() async throws {
        let service = try makeService()
        let oldClient = offlineClient(id: 123)
        let currentClient = offlineClient(id: 124)
        service.session.replaceClientForTesting(oldClient)
        XCTAssertTrue(service.cacheCurrentUserID(42, from: oldClient))
        XCTAssertEqual(service.currentUserID, 42)

        service.session.replaceClientForTesting(currentClient)
        XCTAssertTrue(service.cacheCurrentUserID(43, from: currentClient))
        XCTAssertFalse(service.cacheCurrentUserID(42, from: oldClient))
        XCTAssertEqual(service.currentUserID, 43)

        try await currentClient.stopAndWait(timeout: .seconds(1))
        service.myUserId = 0
        XCTAssertFalse(service.cacheCurrentUserID(43, from: currentClient))
        XCTAssertNil(service.currentUserID, "A terminal client cannot restore the cleared account identity")
        try await oldClient.stopAndWait(timeout: .seconds(1))
    }

    private func offlineClient(id: Int32) -> TDJsonWrapper {
        TDJsonWrapper(clientId: id, send: { _, _ in }, receive: { _ in
            "{\"@type\":\"updateAuthorizationState\",\"@client_id\":\(id),\"authorization_state\":{\"@type\":\"authorizationStateClosed\"}}"
        })
    }

    private func makeService() throws -> TDLibService {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("self-chat-identity-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return TDLibService(databaseDirectory: directory)
    }
}
