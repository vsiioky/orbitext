import Foundation

struct ChatFolder: Identifiable, Equatable {
    let id: Int64
    var title: String
    var iconName: String
    var chatIds: [Int64]
}
