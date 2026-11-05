/// TDLib message identifiers are unique only within their chat.
struct MessageKey: Hashable, Sendable {
    let chatId: Int64
    let messageId: Int64
}
