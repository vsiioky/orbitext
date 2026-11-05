import Foundation

/// TDLib JSON as the receive loop hands it to the parsers.
///
/// The samples follow td_api.tl of TDLib 1.8.64 (scripts/td_api.tl): every
/// scalar field is present, an object that is not set is left out, int53 is a
/// JSON number and int64 a string. They go through JSONSerialization like
/// td_receive output does in TDJsonWrapper, so nested containers arrive as
/// the Foundation types production sees, not as Swift literals.
enum TDJSONSample {
    static func object(_ json: String, file: StaticString = #file, line: UInt = #line) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            preconditionFailure("not a JSON object: \(json)", file: file, line: line)
        }
        return object
    }

    // MARK: Chats

    /// A supergroup chat with the given unread reaction count; set
    /// `"last_message"` on the result to add a last message.
    static func chat(id: Int64 = -1_001_234_567_890, unreadReactionCount: Int = 0) -> [String: Any] {
        object("""
        {"@type":"chat","id":\(id),"type":{"@type":"chatTypeSupergroup","supergroup_id":1234567890,\
        "is_channel":false},"title":"Tech Group","accent_color_id":4,"background_custom_emoji_id":"0",\
        "profile_accent_color_id":-1,"profile_background_custom_emoji_id":"0",\
        "positions":[{"@type":"chatPosition","list":{"@type":"chatListMain"},"order":"6755953163165450241",\
        "is_pinned":false}],"chat_lists":[{"@type":"chatListMain"}],"has_protected_content":false,\
        "is_translatable":true,"is_marked_as_unread":false,"view_as_topics":false,\
        "has_scheduled_messages":false,"can_be_deleted_only_for_self":false,\
        "can_be_deleted_for_all_users":false,"can_be_reported":true,"default_disable_notification":false,\
        "unread_count":3,"last_read_inbox_message_id":3145000,"last_read_outbox_message_id":3144000,\
        "unread_mention_count":1,"unread_reaction_count":\(unreadReactionCount),"unread_poll_vote_count":0,\
        "notification_settings":{"@type":"chatNotificationSettings","use_default_mute_for":true,\
        "mute_for":0,"use_default_sound":true,"sound_id":"0","use_default_show_preview":true,\
        "show_preview":true,"use_default_mute_stories":true,"mute_stories":false,\
        "use_default_story_sound":true,"story_sound_id":"0","use_default_show_story_poster":true,\
        "show_story_poster":true,"use_default_disable_pinned_message_notifications":true,\
        "disable_pinned_message_notifications":false,"use_default_disable_mention_notifications":true,\
        "disable_mention_notifications":false},"message_auto_delete_time":0,"reply_markup_message_id":0,"client_data":""}
        """)
    }

    // MARK: Messages

    static let textContent = """
    {"@type":"messageText","text":{"@type":"formattedText","text":"Hello","entities":[]},\
    "link_preview_options":{"@type":"linkPreviewOptions","is_disabled":false,"url":"",\
    "force_small_media":false,"force_large_media":false,"show_above_text":false}}
    """

    /// A message from `userId`. `members` are further message members written as
    /// `"name":value,` (trailing comma included).
    /// The chat of `message()`, and of the message a `replyToMessage()` in it
    /// replies to unless the sample says otherwise.
    static let defaultChatId: Int64 = -1_001_234_567_890

    static func message(
        id: Int64 = 3_145_728,
        chatId: Int64 = defaultChatId,
        userId: Int64 = 1002,
        isOutgoing: Bool = false,
        members: String = "",
        content: String = textContent
    ) -> [String: Any] {
        object("""
        {"@type":"message","id":\(id),"sender_id":{"@type":"messageSenderUser","user_id":\(userId)},\
        "chat_id":\(chatId),"is_outgoing":\(isOutgoing),"is_pinned":false,"is_from_offline":false,\
        "can_be_saved":true,"has_timestamped_media":false,"is_channel_post":false,\
        "is_paid_star_suggested_post":false,"is_paid_ton_suggested_post":false,\
        "contains_unread_mention":false,"contains_unread_poll_votes":false,"date":1760000000,\
        "edit_date":0,"unread_reactions":[],"self_destruct_in":0,"auto_delete_in":0,\
        "via_bot_user_id":0,"sender_business_bot_user_id":0,"sender_boost_count":0,"sender_tag":"",\
        "paid_message_star_count":0,"author_signature":"","media_album_id":"0","effect_id":"0",\
        "summary_language_code":"",\(members)"content":\(content)}
        """)
    }

    // MARK: reply_to

    /// A reply to a message of `chatId`, which TDLib sets to the chat of the
    /// replied message (the chat of the reply for a same-chat reply, 0 only
    /// when that chat is unknown).
    static func replyToMessage(
        chatId: Int64 = defaultChatId,
        messageId: Int64 = 3_141_592,
        quote: String? = nil,
        origin: String? = nil,
        content: String? = nil
    ) -> String {
        var members = ["\"@type\":\"messageReplyToMessage\"", "\"chat_id\":\(chatId)", "\"message_id\":\(messageId)"]
        if let quote { members.append("\"quote\":\(quote)") }
        members += ["\"checklist_task_id\":0", "\"poll_option_id\":\"\""]
        if let origin { members.append("\"origin\":\(origin)") }
        members.append("\"origin_send_date\":\(origin == nil ? 0 : 1_759_990_000)")
        if let content { members.append("\"content\":\(content)") }
        return "\"reply_to\":{\(members.joined(separator: ","))},"
    }

    static func quote(text: String, entities: String = "") -> String {
        """
        {"@type":"textQuote","text":{"@type":"formattedText","text":"\(text)","entities":[\(entities)]},\
        "position":5,"is_manual":true}
        """
    }

    static func entity(offset: Int, length: Int, type: String) -> String {
        """
        {"@type":"textEntity","offset":\(offset),"length":\(length),"type":{"@type":"\(type)"}}
        """
    }

    static let replyToStory = """
    "reply_to":{"@type":"messageReplyToStory","story_poster_chat_id":-1002233445566,"story_id":14},
    """

    // MARK: message origins

    static func originUser(_ userId: Int64) -> String {
        "{\"@type\":\"messageOriginUser\",\"sender_user_id\":\(userId)}"
    }

    static func originHiddenUser(_ name: String) -> String {
        "{\"@type\":\"messageOriginHiddenUser\",\"sender_name\":\"\(name)\"}"
    }

    static func originChat(_ chatId: Int64, signature: String = "") -> String {
        "{\"@type\":\"messageOriginChat\",\"sender_chat_id\":\(chatId),\"author_signature\":\"\(signature)\"}"
    }

    static func originChannel(_ chatId: Int64, signature: String = "") -> String {
        """
        {"@type":"messageOriginChannel","chat_id":\(chatId),"message_id":512,\
        "author_signature":"\(signature)"}
        """
    }

    // MARK: forward_info

    static func forwardInfo(origin: String, source: String? = nil, announcement: String = "") -> String {
        let sourceMember = source.map { "\"source\":\($0)," } ?? ""
        return """
        "forward_info":{"@type":"messageForwardInfo","origin":\(origin),"date":1759999000,\
        \(sourceMember)"public_service_announcement_type":"\(announcement)"},
        """
    }

    static let forwardSource = """
    {"@type":"forwardSource","chat_id":-1007766554433,"message_id":77,\
    "sender_id":{"@type":"messageSenderUser","user_id":2001},"sender_name":"","date":1759999500,\
    "is_outgoing":false}
    """

    // MARK: interaction_info

    static func reaction(type: String, count: Int, isChosen: Bool = false) -> String {
        """
        {"@type":"messageReaction","type":\(type),"total_count":\(count),"is_chosen":\(isChosen),\
        "recent_sender_ids":[{"@type":"messageSenderUser","user_id":2001}]}
        """
    }

    static func emojiReaction(_ emoji: String) -> String {
        "{\"@type\":\"reactionTypeEmoji\",\"emoji\":\"\(emoji)\"}"
    }

    static let paidReaction = "{\"@type\":\"reactionTypePaid\"}"

    static func customEmojiReaction(_ id: String) -> String {
        "{\"@type\":\"reactionTypeCustomEmoji\",\"custom_emoji_id\":\"\(id)\"}"
    }

    static func interactionInfoObject(reactions: [String]?) -> String {
        let reactionsMember = reactions.map {
            """
            ,"reactions":{"@type":"messageReactions","reactions":[\($0.joined(separator: ","))],\
            "are_tags":false,"paid_reactors":[],"can_get_added_reactions":false}
            """
        } ?? ""
        return """
        {"@type":"messageInteractionInfo","view_count":120,"forward_count":3,\
        "reply_info":{"@type":"messageReplyInfo","reply_count":2,\
        "recent_replier_ids":[{"@type":"messageSenderUser","user_id":2001}],\
        "last_read_inbox_message_id":3145000,"last_read_outbox_message_id":3144000,\
        "last_message_id":3145700}\(reactionsMember)}
        """
    }

    static func interactionInfo(reactions: [String]?) -> String {
        "\"interaction_info\":\(interactionInfoObject(reactions: reactions)),"
    }

    // MARK: polls

    static func poll(question: String, entities: String = "", type: String = "{\"@type\":\"pollTypeRegular\"}") -> String {
        """
        {"@type":"messagePoll","poll":{"@type":"poll","id":"5420323339723881652",\
        "question":{"@type":"formattedText","text":"\(question)","entities":[\(entities)]},\
        "options":[\
        {"@type":"pollOption","id":"0","text":{"@type":"formattedText","text":"Red","entities":[]},\
        "voter_count":2,"vote_percentage":67,"recent_voter_ids":[],"is_chosen":false,\
        "is_being_chosen":false,"addition_date":0},\
        {"@type":"pollOption","id":"1","text":{"@type":"formattedText","text":"Blue","entities":[]},\
        "voter_count":1,"vote_percentage":33,"recent_voter_ids":[],"is_chosen":false,\
        "is_being_chosen":false,"addition_date":0}],\
        "total_voter_count":3,"recent_voter_ids":[],"can_get_voters":false,"is_anonymous":true,\
        "allows_multiple_answers":false,"allows_revoting":true,"members_only":false,\
        "country_codes":[],"option_order":[],"type":\(type),"open_period":0,"close_date":0,\
        "is_closed":false},"description":{"@type":"formattedText","text":"","entities":[]},\
        "can_add_option":false}
        """
    }

    // MARK: users

    static func user(
        id: Int64,
        firstName: String,
        lastName: String = "",
        status: String = "{\"@type\":\"userStatusEmpty\"}",
        type: String = "{\"@type\":\"userTypeRegular\"}",
        usernames: String = "{\"@type\":\"usernames\",\"active_usernames\":[],\"disabled_usernames\":[],\"editable_username\":\"\",\"collectible_usernames\":[]}",
        phone: String = "",
        profilePhotoSmallId: Int? = nil
    ) -> String {
        let photoMember = profilePhotoSmallId.map {
            """
            "profile_photo":{"@type":"profilePhoto","id":"7351902837461","small":{"@type":"file","id":\($0),\
            "size":0,"expected_size":0,"local":{"@type":"localFile","path":"","can_be_downloaded":true,\
            "can_be_deleted":false,"is_downloading_active":false,"is_downloading_completed":false,\
            "download_offset":0,"downloaded_prefix_size":0,"downloaded_size":0},\
            "remote":{"@type":"remoteFile","id":"AQAD","unique_id":"AQADuniq","is_uploading_active":false,\
            "is_uploading_completed":true,"uploaded_size":0}},\
            "big":{"@type":"file","id":\($0 + 1),"size":0,"expected_size":0},\
            "has_animation":false,"is_personal":false},
            """
        } ?? ""
        return """
        {"@type":"user","id":\(id),"first_name":"\(firstName)","last_name":"\(lastName)",\
        "usernames":\(usernames),"phone_number":"\(phone)","status":\(status),\(photoMember)\
        "accent_color_id":3,"background_custom_emoji_id":"0","profile_accent_color_id":-1,\
        "profile_background_custom_emoji_id":"0","is_contact":true,"is_mutual_contact":true,\
        "is_close_friend":false,"is_premium":false,"is_support":false,"restricts_new_chats":false,\
        "paid_message_star_count":0,"have_access":true,"type":\(type),"language_code":"",\
        "added_to_attachment_menu":false}
        """
    }

    static func updateUser(
        id: Int64,
        firstName: String,
        lastName: String = "",
        status: String = "{\"@type\":\"userStatusEmpty\"}"
    ) -> [String: Any] {
        object("""
        {"@type":"updateUser","user":\(user(id: id, firstName: firstName, lastName: lastName, status: status))}
        """)
    }
}
