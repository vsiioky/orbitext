import Foundation

// MARK: - Chat list positions

//
// TDLib sends a chat's position in every list it belongs to: `positions` on
// the chat and on updateChatLastMessage / updateChatDraftMessage, and one
// `position` per updateChatPosition. ChatInfo keeps only the Main values, so
// the other lists travel on ChatPositionUpdate.

extension ChatListID {
    /// Nil for a list this schema does not know, which the app cannot show.
    init?(tdApi list: TDApi.ChatList?) {
        switch list {
        case .chatListMain: self = .main
        case .chatListArchive: self = .archive
        case .chatListFolder(let folder): self = .folder(Int64(folder.chatFolderId))
        case .unknown, .none: return nil
        }
    }

    /// The `chat_list` argument of a request.
    var tdRequest: [String: Any] {
        switch self {
        case .main: return ["@type": "chatListMain"]
        case .archive: return ["@type": "chatListArchive"]
        case .folder(let folderId): return ["@type": "chatListFolder", "chat_folder_id": Int(folderId)]
        }
    }
}

extension ChatListPosition {
    init?(tdApi position: TDApi.ChatPosition) {
        guard let list = ChatListID(tdApi: position.list) else { return nil }
        self.init(list: list, order: position.order, isPinned: position.isPinned)
    }
}

extension TDLibService {
    /// The positions in a `positions` vector, dropping lists the app does not
    /// know. Nil only when the key is absent: an empty vector is a statement
    /// (the chat is in no list) and must stay distinguishable from "no news".
    func parseChatPositions(_ raw: Any?) -> [ChatListPosition]? {
        guard let array = normalizeArray(raw) else { return nil }
        return array.compactMap { element in
            normalizeDictionary(element)
                .flatMap { ChatListPosition(tdApi: TDApi.decodeChatPosition($0)) }
        }
    }
}
