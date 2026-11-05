import Foundation

// MARK: - Bot commands / callback answers <- TDLib dict

//
// userFullInfo, basicGroupFullInfo and supergroupFullInfo are not part of
// the generated bindings, so these mappings read the raw dicts and, like
// ReplyMarkup+Mapping, stay service-free for unit tests.

extension BotCommandInfo {
    /// Parses a vector<botCommand>. Duplicate commands are dropped so the
    /// list stays usable as SwiftUI identity.
    static func list(tdApiArray value: Any?, botUsername: String? = nil) -> [BotCommandInfo] {
        var seen: Set<String> = []
        return ReplyMarkup.array(value).compactMap { item in
            guard let dict = ReplyMarkup.dictionary(item),
                  let command = dict["command"] as? String, !command.isEmpty else { return nil }
            let info = BotCommandInfo(
                command: command,
                description: dict["description"] as? String ?? "",
                botUsername: botUsername
            )
            return seen.insert(info.id).inserted ? info : nil
        }
    }

    /// userFullInfo.bot_info.commands. Private bot chats address commands
    /// without the @username suffix.
    static func list(userFullInfo dict: [String: Any]) -> [BotCommandInfo] {
        list(tdApiArray: ReplyMarkup.dictionary(dict["bot_info"])?["commands"])
    }

    /// basicGroupFullInfo / supergroupFullInfo `bot_commands`: one entry per
    /// bot in the group. Commands get the bot's @username so the right bot
    /// receives them; `resolveUsername` maps bot_user_id -> username.
    static func list(groupFullInfo dict: [String: Any], resolveUsername: (Int64) -> String?) -> [BotCommandInfo] {
        var seen: Set<String> = []
        var result: [BotCommandInfo] = []
        for entry in ReplyMarkup.array(dict["bot_commands"]) {
            guard let botCommands = ReplyMarkup.dictionary(entry) else { continue }
            let botUserId = MessageOrigin.toInt64(botCommands["bot_user_id"])
            let username = botUserId == 0 ? nil : resolveUsername(botUserId)
            for command in list(tdApiArray: botCommands["commands"], botUsername: username)
            where seen.insert(command.id).inserted {
                result.append(command)
            }
        }
        return result
    }
}

extension BotCallbackAnswer {
    init(tdApiDict dict: [String: Any]) {
        self.init(
            text: dict["text"] as? String ?? "",
            showAlert: dict["show_alert"] as? Bool ?? false,
            url: dict["url"] as? String ?? ""
        )
    }
}
