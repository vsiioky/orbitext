import XCTest
@testable import OrbitextWatch

/// BotCommandInfo parsing from TDLib full-info dicts and BotCallbackAnswer
/// defaults.
final class BotCommandMappingTests: XCTestCase {
    // MARK: - Helpers

    private func command(_ name: String, _ description: String = "") -> [String: Any] {
        ["@type": "botCommand", "command": name, "description": description]
    }

    private func userFullInfo(commands: [[String: Any]]) -> [String: Any] {
        ["@type": "userFullInfo", "bot_info": ["@type": "botInfo", "commands": commands] as [String: Any]]
    }

    private func groupFullInfo(_ bots: [(userId: Any, commands: [[String: Any]])]) -> [String: Any] {
        let entries: [[String: Any]] = bots.map {
            ["@type": "botCommands", "bot_user_id": $0.userId, "commands": $0.commands]
        }
        return ["@type": "supergroupFullInfo", "bot_commands": entries]
    }

    // MARK: - list(userFullInfo:)

    func testUserFullInfoCommandsAreReadFromBotInfo() {
        let dict = userFullInfo(commands: [command("start", "Begin"), command("help", "Show help")])

        let commands = BotCommandInfo.list(userFullInfo: dict)

        XCTAssertEqual(commands, [
            BotCommandInfo(command: "start", description: "Begin"),
            BotCommandInfo(command: "help", description: "Show help")
        ])
        XCTAssertEqual(commands.map(\.messageText), ["/start", "/help"])
        XCTAssertTrue(commands.allSatisfy { $0.botUsername == nil })
    }

    func testUserFullInfoWithoutBotInfoYieldsNoCommands() {
        XCTAssertTrue(BotCommandInfo.list(userFullInfo: [:]).isEmpty)
        XCTAssertTrue(BotCommandInfo.list(userFullInfo: ["bot_info": NSNull()]).isEmpty)
        XCTAssertTrue(BotCommandInfo.list(userFullInfo: ["bot_info": ["@type": "botInfo"] as [String: Any]]).isEmpty)
        XCTAssertTrue(BotCommandInfo.list(userFullInfo: userFullInfo(commands: [])).isEmpty)
    }

    func testTopLevelCommandsOfTheOldSchemaAreIgnored() {
        let dict: [String: Any] = ["commands": [command("start", "Begin")]]

        XCTAssertTrue(BotCommandInfo.list(userFullInfo: dict).isEmpty)
    }

    func testDuplicateCommandsAreDroppedKeepingTheFirst() {
        let dict = userFullInfo(commands: [command("start", "First"), command("help", "Help"), command("start", "Second")])

        let commands = BotCommandInfo.list(userFullInfo: dict)

        XCTAssertEqual(commands.map(\.command), ["start", "help"])
        XCTAssertEqual(commands.first?.description, "First")
    }

    func testCommandsWithEmptyOrMissingNameAreDropped() {
        let nameless: [String: Any] = ["@type": "botCommand", "description": "No name"]
        let dict = userFullInfo(commands: [command("", "Empty"), nameless, command("ok", "Fine")])

        let commands = BotCommandInfo.list(userFullInfo: dict)

        XCTAssertEqual(commands.map(\.command), ["ok"])
    }

    func testMissingDescriptionBecomesEmptyString() {
        let bare: [String: Any] = ["@type": "botCommand", "command": "ping"]

        let commands = BotCommandInfo.list(userFullInfo: userFullInfo(commands: [bare]))

        XCTAssertEqual(commands, [BotCommandInfo(command: "ping", description: "")])
    }

    func testBridgedCommandContainersAreParsed() {
        let bridged = NSArray(array: [NSDictionary(dictionary: ["command": "start", "description": "Begin"])])

        let commands = BotCommandInfo.list(tdApiArray: bridged, botUsername: nil)

        XCTAssertEqual(commands.map(\.command), ["start"])
    }

    func testListFromNonArrayValueIsEmpty() {
        XCTAssertTrue(BotCommandInfo.list(tdApiArray: nil).isEmpty)
        XCTAssertTrue(BotCommandInfo.list(tdApiArray: "start").isEmpty)
        XCTAssertTrue(BotCommandInfo.list(tdApiArray: NSNull()).isEmpty)
    }

    // MARK: - list(groupFullInfo:resolveUsername:)

    func testGroupCommandsGetTheBotsUsername() {
        let dict = groupFullInfo([
            (userId: 7, commands: [command("start", "Begin")]),
            (userId: 8, commands: [command("help", "Help")])
        ])
        let usernames: [Int64: String] = [7: "alpha_bot", 8: "beta_bot"]

        let commands = BotCommandInfo.list(groupFullInfo: dict, resolveUsername: { usernames[$0] })

        XCTAssertEqual(commands.map(\.messageText), ["/start@alpha_bot", "/help@beta_bot"])
        XCTAssertEqual(commands.map(\.botUsername), ["alpha_bot", "beta_bot"])
    }

    func testGroupCommandsStayBareWhenUsernameIsUnknown() {
        let dict = groupFullInfo([
            (userId: 7, commands: [command("start")]),
            (userId: 8, commands: [command("help")])
        ])

        let commands = BotCommandInfo.list(groupFullInfo: dict, resolveUsername: { $0 == 7 ? "alpha_bot" : nil })

        XCTAssertEqual(commands.map(\.messageText), ["/start@alpha_bot", "/help"])
    }

    func testGroupBotUserIdAsStringIsResolved() {
        let dict = groupFullInfo([(userId: "7000000001", commands: [command("start")])])
        var requested: [Int64] = []

        let commands = BotCommandInfo.list(groupFullInfo: dict, resolveUsername: { id in
            requested.append(id)
            return "big_bot"
        })

        XCTAssertEqual(requested, [7_000_000_001])
        XCTAssertEqual(commands.map(\.messageText), ["/start@big_bot"])
    }

    func testGroupBotWithZeroUserIdIsNotResolvedAndKeepsBareCommands() {
        let dict = groupFullInfo([(userId: 0, commands: [command("start")])])
        var resolverCalled = false

        let commands = BotCommandInfo.list(groupFullInfo: dict, resolveUsername: { _ in
            resolverCalled = true
            return "ghost_bot"
        })

        XCTAssertFalse(resolverCalled)
        XCTAssertEqual(commands.map(\.messageText), ["/start"])
    }

    func testSameCommandFromTwoBotsIsKeptForBoth() {
        let dict = groupFullInfo([
            (userId: 7, commands: [command("start")]),
            (userId: 8, commands: [command("start")])
        ])
        let usernames: [Int64: String] = [7: "alpha_bot", 8: "beta_bot"]

        let commands = BotCommandInfo.list(groupFullInfo: dict, resolveUsername: { usernames[$0] })

        XCTAssertEqual(commands.map(\.messageText), ["/start@alpha_bot", "/start@beta_bot"])
        XCTAssertEqual(Set(commands.map(\.id)).count, 2)
    }

    func testDuplicateCommandsOfTheSameGroupBotAreDropped() {
        let dict = groupFullInfo([
            (userId: 7, commands: [command("start", "A"), command("start", "B")]),
            (userId: 7, commands: [command("start", "C"), command("extra", "D")])
        ])

        let commands = BotCommandInfo.list(groupFullInfo: dict, resolveUsername: { _ in "alpha_bot" })

        XCTAssertEqual(commands.map(\.messageText), ["/start@alpha_bot", "/extra@alpha_bot"])
        XCTAssertEqual(commands.first?.description, "A")
    }

    func testGroupFullInfoWithoutBotCommandsIsEmpty() {
        XCTAssertTrue(BotCommandInfo.list(groupFullInfo: [:], resolveUsername: { _ in "x" }).isEmpty)
        XCTAssertTrue(BotCommandInfo.list(groupFullInfo: ["bot_commands": NSNull()], resolveUsername: { _ in "x" }).isEmpty)
        XCTAssertTrue(BotCommandInfo.list(groupFullInfo: groupFullInfo([]), resolveUsername: { _ in "x" }).isEmpty)
    }

    // MARK: - messageText / id

    func testMessageTextWithoutUsernameIsBareSlashCommand() {
        let command = BotCommandInfo(command: "start", description: "")

        XCTAssertEqual(command.messageText, "/start")
        XCTAssertEqual(command.id, "/start")
    }

    func testMessageTextWithUsernameAddsAtSuffix() {
        let command = BotCommandInfo(command: "start", description: "", botUsername: "alpha_bot")

        XCTAssertEqual(command.messageText, "/start@alpha_bot")
        XCTAssertEqual(command.id, "/start@alpha_bot")
    }

    func testMessageTextTreatsEmptyUsernameAsMissing() {
        let command = BotCommandInfo(command: "help", description: "", botUsername: "")

        XCTAssertEqual(command.messageText, "/help")
    }

    // MARK: - BotCallbackAnswer

    func testCallbackAnswerDefaultsForEmptyDict() {
        let answer = BotCallbackAnswer(tdApiDict: [:])

        XCTAssertEqual(answer, BotCallbackAnswer())
        XCTAssertEqual(answer.text, "")
        XCTAssertFalse(answer.showAlert)
        XCTAssertEqual(answer.url, "")
    }

    func testCallbackAnswerReadsAllFields() {
        let dict: [String: Any] = [
            "@type": "callbackQueryAnswer",
            "text": "Saved",
            "show_alert": true,
            "url": "https://t.me/somebot?start=x"
        ]

        let answer = BotCallbackAnswer(tdApiDict: dict)

        XCTAssertEqual(answer, BotCallbackAnswer(text: "Saved", showAlert: true, url: "https://t.me/somebot?start=x"))
    }

    func testCallbackAnswerIgnoresWronglyTypedFields() {
        let dict: [String: Any] = ["text": 5, "show_alert": "yes", "url": NSNull()]

        XCTAssertEqual(BotCallbackAnswer(tdApiDict: dict), BotCallbackAnswer())
    }
}
