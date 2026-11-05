import Foundation

/// One of the lists TDLib orders chats in. The app shows one at a time: Main,
/// or the folder the user picked. Archive is tracked so that a chat moving
/// there leaves the others.
enum ChatListID: Hashable, Sendable {
    case main
    case archive
    case folder(Int64)

    /// The list a folder selection shows; no folder means Main.
    init(folderId: Int64?) {
        if let folderId {
            self = .folder(folderId)
        } else {
            self = .main
        }
    }

    var folderId: Int64? {
        if case .folder(let id) = self { return id }
        return nil
    }
}

/// A chat's place in one list. TDLib sorts a list by (order, chat id)
/// descending; `order` is 0 when the chat is not in the list, or not in the
/// part of it the client has loaded.
struct ChatListPosition: Hashable, Sendable {
    let list: ChatListID
    let order: Int64
    let isPinned: Bool
}
