#if DEBUG
import Foundation

/// Fixed wall-clock times anchored to the current day, so a screenshot shows
/// the same times and "Yesterday" whenever it is taken.
struct DemoDates: Sendable {
    private let calendar: Calendar
    private let startOfToday: Date

    init(now: Date = .now, calendar: Calendar = .current) {
        self.calendar = calendar
        startOfToday = calendar.startOfDay(for: now)
    }

    func at(daysAgo: Int = 0, _ hour: Int, _ minute: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: startOfToday) ?? startOfToday
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}

/// The people, chats and messages of demo mode. Every name, number and text
/// is invented: phone numbers use the reserved 555-01xx range, usernames end
/// in "_demo", and nothing points at a real account.
struct DemoContent: Sendable {
    static let meId: Int64 = 1000
    static let alexId: Int64 = 1001
    static let priyaId: Int64 = 1002
    static let samId: Int64 = 1003
    static let jamieId: Int64 = 1004
    static let rileyId: Int64 = 1005
    static let hikeChatId: Int64 = -100_200_000_001
    static let newsChatId: Int64 = -100_200_000_002
    static let personalFolderId: Int64 = 11
    static let groupsFolderId: Int64 = 12
    /// Messages of Alex's chat that screens open at.
    static let alexPhotoMessageId: Int64 = 3
    static let alexVoiceMessageId: Int64 = 9

    let me: ContactInfo
    let contacts: [ContactInfo]
    let chats: [ChatInfo]
    /// Oldest first, as the transport keeps them.
    let messages: [Int64: [MessageInfo]]
    let folders: [ChatFolder]
    let folderMembers: [Int64: Set<Int64>]
    let groupInfo: [Int64: GroupInfo]
    let stickers: [StickerOption]

    init(now: Date = .now, calendar: Calendar = .current) {
        let dates = DemoDates(now: now, calendar: calendar)
        let people = Self.makePeople(dates)
        let me = people[0]
        let threads = Self.makeThreads(dates: dates, me: me, people: people)
        self.me = me
        contacts = people.dropFirst().sorted { $0.fullName < $1.fullName }
        messages = threads
        chats = Self.makeChats(threads: threads)
        folders = [
            ChatFolder(id: Self.personalFolderId, title: "Personal", iconName: "folder", chatIds: []),
            ChatFolder(id: Self.groupsFolderId, title: "Groups", iconName: "folder", chatIds: []),
        ]
        folderMembers = [
            Self.personalFolderId: [
                Self.meId, Self.alexId, Self.priyaId, Self.samId, Self.jamieId, Self.rileyId,
            ],
            Self.groupsFolderId: [Self.hikeChatId, Self.newsChatId],
        ]
        groupInfo = [
            Self.hikeChatId: GroupInfo(memberCount: 4, description: "Saturday trail runs and coffee. A fictional group."),
            Self.newsChatId: GroupInfo(memberCount: 1280, description: "Release notes for the demo. A fictional channel."),
        ]
        stickers = ["😀", "😎", "😍", "🥳", "😴", "👍", "🔥", "🎉"].enumerated().map { index, emoji in
            StickerOption(fileId: String(101 + index), emoji: emoji, thumbnailFileId: nil, width: 512, height: 512)
        }
    }

    // MARK: - People

    /// The signed-in user first, then everyone else.
    private static func makePeople(_ dates: DemoDates) -> [ContactInfo] {
        func person(_ id: Int64, _ first: String, _ last: String, online: Bool = false, seen: Date? = nil) -> ContactInfo {
            ContactInfo(
                id: id, firstName: first, lastName: last, phone: "+1 555 0\(100 + Int(id - meId))",
                username: "\(first.lowercased())_demo", photoFileId: nil, isOnline: online, lastSeen: seen
            )
        }
        return [
            person(meId, "Casey", "Brooks", online: true),
            person(alexId, "Alex", "Morgan", online: true),
            person(priyaId, "Priya", "Shah", seen: dates.at(8, 41)),
            person(samId, "Sam", "Lee", online: true),
            person(jamieId, "Jamie", "Park", seen: dates.at(daysAgo: 1, 22, 15)),
            person(rileyId, "Riley", "Stone", seen: dates.at(daysAgo: 3, 14, 30)),
            person(1006, "Taylor", "Kim", seen: dates.at(daysAgo: 1, 9, 5)),
            person(1007, "Dana", "Cruz", seen: dates.at(7, 12)),
            person(1008, "Chris", "Novak", seen: dates.at(daysAgo: 6, 18, 0)),
        ]
    }

    // MARK: - Messages

    private static func makeThreads(dates: DemoDates, me: ContactInfo, people: [ContactInfo]) -> [Int64: [MessageInfo]] {
        let alex = people[1], priya = people[2], sam = people[3], jamie = people[4], riley = people[5]
        var alexThread = DemoThread(chatId: alexId, me: me)
        alexThread.incoming(alex, "Are we still on for Saturday?", dates.at(daysAgo: 1, 18, 42))
        alexThread.outgoing("Yes! Trailhead at 8. I'll bring coffee.", dates.at(daysAgo: 1, 18, 44))
        alexThread.incoming(
            alex, .photo(caption: "Route for Saturday", fileId: DemoMedia.photoFileId, width: 480, height: 360, minithumbnail: nil),
            dates.at(daysAgo: 1, 18, 46)
        )
        alexThread.outgoing(
            "Looks great. How long is the loop?", dates.at(daysAgo: 1, 18, 50),
            reactions: [ReactionInfo(emoji: "❤", count: 1, isSelected: false)]
        )
        alexThread.incoming(alex, "About three hours with a lunch stop.", dates.at(daysAgo: 1, 18, 52))
        alexThread.outgoing("Perfect. I'll pack lunch too.", dates.at(daysAgo: 1, 18, 55))
        alexThread.incoming(alex, "Same here. Good night!", dates.at(daysAgo: 1, 19, 1))
        alexThread.incoming(alex, "Bring layers, it gets cold near the top.", dates.at(9, 12))
        alexThread.incoming(
            alex, .voice(duration: DemoMedia.voiceDuration, fileId: DemoMedia.voiceFileId, waveform: DemoMedia.waveform(seed: 3)),
            dates.at(9, 13)
        )
        alexThread.outgoing(
            "Will do. Thermos is packed.", dates.at(9, 16), replyTo: 8,
            reactions: [ReactionInfo(emoji: "👍", count: 1, isSelected: false)]
        )

        var priyaThread = DemoThread(chatId: priyaId, me: me)
        priyaThread.outgoing("Did you finish the slides?", dates.at(daysAgo: 1, 20, 10))
        priyaThread.incoming(priya, "Almost. Sending them tonight.", dates.at(daysAgo: 1, 20, 14))
        priyaThread.incoming(priya, .voice(duration: 9, fileId: "demo-voice-priya", waveform: DemoMedia.waveform(seed: 5)), dates.at(8, 20))

        var samThread = DemoThread(chatId: samId, me: me)
        samThread.outgoing("Thanks for the lift today!", dates.at(daysAgo: 1, 20, 55))
        samThread.incoming(
            sam, .photo(caption: "", fileId: "demo-photo-sam", width: 480, height: 360, minithumbnail: nil), dates.at(daysAgo: 1, 21, 5)
        )

        var jamieThread = DemoThread(chatId: jamieId, me: me)
        jamieThread.incoming(jamie, "Table is booked for 7.", dates.at(daysAgo: 1, 18, 30))
        jamieThread.outgoing("Great, see you there.", dates.at(daysAgo: 1, 18, 32))

        var rileyThread = DemoThread(chatId: rileyId, me: me)
        rileyThread.incoming(riley, "Thanks again for the help!", dates.at(daysAgo: 3, 14, 2))
        rileyThread.outgoing("Anytime.", dates.at(daysAgo: 3, 14, 5))

        var savedThread = DemoThread(chatId: meId, me: me)
        savedThread.outgoing("Buy oat milk and batteries", dates.at(daysAgo: 1, 10, 5))
        savedThread.outgoing("Trail map for Saturday: loop via the north ridge", dates.at(7, 30))

        var hikeThread = DemoThread(chatId: hikeChatId, me: me)
        hikeThread.incoming(priya, "Who is driving on Saturday?", dates.at(daysAgo: 1, 19, 0))
        hikeThread.incoming(sam, "I can take three people.", dates.at(daysAgo: 1, 19, 3))
        hikeThread.outgoing("I'll ride with you, Sam.", dates.at(daysAgo: 1, 19, 5))
        hikeThread.incoming(alex, "Weather looks clear all day.", dates.at(7, 41))
        hikeThread.incoming(priya, "I'll bring the thermos.", dates.at(7, 48))
        hikeThread.incoming(sam, "Trailhead parking is free before 8.", dates.at(7, 55))

        let news = ContactInfo(
            id: newsChatId, firstName: "Orbitext News", lastName: "", phone: "", username: "",
            photoFileId: nil, isOnline: false, lastSeen: nil
        )
        var newsThread = DemoThread(chatId: newsChatId, me: me)
        newsThread.incoming(news, "Version 0.1.0 is open for testing.", dates.at(daysAgo: 2, 10, 0))
        newsThread.incoming(news, "New: folder filter and a pinned chats section.", dates.at(daysAgo: 1, 9, 30))
        newsThread.incoming(news, "Tip: swipe a chat row to pin, mute or mark it as read.", dates.at(6, 10))

        return [alexThread, priyaThread, samThread, jamieThread, rileyThread, savedThread, hikeThread, newsThread]
            .reduce(into: [:]) { $0[$1.chatId] = $1.messages }
    }

    // MARK: - Chats

    private static func makeChats(threads: [Int64: [MessageInfo]]) -> [ChatInfo] {
        func chat(_ id: Int64, _ title: String, configure: (inout ChatInfo) -> Void = { _ in }) -> ChatInfo {
            let thread = threads[id] ?? []
            var info = ChatInfo(
                id: id, title: title, lastMessage: thread.last, unreadCount: 0, isGroup: false, isMuted: false,
                order: Int64(thread.last?.date.timeIntervalSince1970 ?? 0)
            )
            info.lastReadOutboxMessageId = thread.last(where: \.isOutgoing)?.id ?? 0
            configure(&info)
            return info
        }
        return [
            chat(alexId, "Alex Morgan") { $0.isPinned = true
            $0.isOnline = true
            $0.reactionCount = 1
            },
            chat(meId, "Saved Messages") { $0.isPinned = true },
            chat(priyaId, "Priya Shah") { $0.unreadCount = 1 },
            chat(hikeChatId, "Weekend Hike") { $0.isGroup = true
            $0.unreadCount = 3
            },
            chat(newsChatId, "Orbitext News") { $0.isChannel = true
            $0.isMuted = true
            $0.unreadCount = 2
            },
            chat(samId, "Sam Lee") { $0.isOnline = true },
            chat(jamieId, "Jamie Park") { $0.draftMessage = "Running ten minutes late" },
            chat(rileyId, "Riley Stone"),
        ]
    }
}

/// One chat's messages, numbered from 1 in the order they are added.
private struct DemoThread {
    let chatId: Int64
    let me: ContactInfo
    private(set) var messages: [MessageInfo] = []

    init(chatId: Int64, me: ContactInfo) {
        self.chatId = chatId
        self.me = me
    }

    mutating func incoming(_ sender: ContactInfo, _ text: String, _ date: Date) {
        incoming(sender, .text(FormattedString(text: text)), date)
    }

    mutating func incoming(_ sender: ContactInfo, _ content: MessageContent, _ date: Date) {
        messages.append(MessageInfo(
            id: Int64(messages.count + 1), chatId: chatId, senderName: sender.fullName, senderId: sender.id,
            content: content, date: date, isOutgoing: false, isRead: true
        ))
    }

    /// Always read: the demo has no message that is still on its way.
    mutating func outgoing(_ text: String, _ date: Date, replyTo: Int64? = nil, reactions: [ReactionInfo] = []) {
        var message = MessageInfo(
            id: Int64(messages.count + 1), chatId: chatId, senderName: me.fullName, senderId: me.id,
            content: .text(FormattedString(text: text)), date: date, isOutgoing: true, isRead: true,
            replyToMessageId: replyTo, reactions: reactions
        )
        if let replyTo, let original = messages.first(where: { $0.id == replyTo }) {
            message.replyToSenderName = original.senderName
            message.replyToSenderUserId = original.senderId
            message.replyToPreview = FormattedString(text: original.content.textPreview)
        }
        messages.append(message)
    }
}
#endif
