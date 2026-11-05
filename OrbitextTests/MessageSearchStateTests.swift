import XCTest
@testable import OrbitextWatch

final class MessageSearchStateTests: XCTestCase {
    func testChangedQueryRejectsPreviousResultsAndFailure() throws {
        var state = MessageSearchState()
        let first = try XCTUnwrap(state.begin(query: "old query"))
        let latest = try XCTUnwrap(state.begin(query: "new query"))

        state.complete(results: [message(id: 1)], generation: first.generation)
        state.fail(generation: first.generation)
        XCTAssertEqual(state.phase, .loading)
        XCTAssertTrue(state.results.isEmpty)

        state.complete(results: [message(id: 2)], generation: latest.generation)
        XCTAssertEqual(state.phase, .loaded)
        XCTAssertEqual(state.results.map(\.id), [2])
    }

    func testFailedSearchCanRetrySameQueryAndShowEmptySuccess() throws {
        var state = MessageSearchState()
        let first = try XCTUnwrap(state.begin(query: "find this"))
        state.fail(generation: first.generation)
        XCTAssertEqual(state.phase, .failed)

        let retry = try XCTUnwrap(state.begin(query: "find this", force: true))
        state.complete(results: [], generation: retry.generation)
        XCTAssertEqual(state.phase, .loaded)
        XCTAssertTrue(state.results.isEmpty)
    }

    func testLeavingDuringSearchInvalidatesResponseAndAllowsResume() throws {
        var state = MessageSearchState()
        let request = try XCTUnwrap(state.begin(query: "pending"))
        state.cancelPending()
        state.complete(results: [message(id: 1)], generation: request.generation)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.shouldResume)
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertNotNil(state.begin(query: "pending", force: true))
    }

    func testShortenedQueryClearsResultsAndInvalidatesPendingSearch() throws {
        var state = MessageSearchState()
        let first = try XCTUnwrap(state.begin(query: "pending"))
        XCTAssertNil(state.begin(query: "x"))
        state.complete(results: [message(id: 1)], generation: first.generation)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.shouldResume)
        XCTAssertTrue(state.results.isEmpty)
    }

    func testWhitespaceOnlyChangeKeepsRequestAndMeaningfulQueryText() throws {
        var state = MessageSearchState()
        let request = try XCTUnwrap(state.begin(query: "  Café\n Москва  "))
        XCTAssertEqual(request.query, "Café Москва")
        XCTAssertNil(state.begin(query: "Café   Москва"))
        XCTAssertEqual(state.generation, request.generation)
        state.complete(results: [message(id: 1)], generation: request.generation)
        XCTAssertEqual(state.results.map(\.id), [1])
    }

    private func message(id: Int64) -> MessageInfo {
        MessageInfo(id: id, chatId: 7, senderName: "Demo", senderId: 2,
                    content: .text("Example"), date: Date(timeIntervalSince1970: 0),
                    isOutgoing: false, isRead: true)
    }
}
