import Foundation

/// Where a bot button URL leads. Public Telegram usernames are opened
/// inside the app; other web links are offered to the user as external
/// links; Telegram-only links Orbitext cannot handle (invites, sticker
/// sets, proxies...) are reported as unsupported.
enum TelegramLink: Equatable {
    case publicChat(username: String)
    case external(URL)
    case unsupported

    private static let telegramHosts: Set = ["t.me", "telegram.me", "telegram.dog"]

    /// First path components on t.me that are not usernames.
    private static let reservedPaths: Set = [
        "addemoji", "addlist", "addstickers", "addtheme", "bg", "boost", "c",
        "confirmphone", "contact", "giftcode", "invoice", "iv", "joinchat",
        "login", "m", "nft", "proxy", "s", "setlanguage", "share", "socks"
    ]

    /// Returns nil when the string is not a usable URL at all.
    init?(string: String) {
        var raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        if !lowered.contains("://"),
           Self.telegramHosts.contains(where: { lowered.hasPrefix("\($0)/") || lowered.hasPrefix("www.\($0)/") }) {
            raw = "https://" + raw
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return nil }

        if scheme == "tg" {
            self = Self.resolveTGLink(url)
            return
        }

        var host = url.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard scheme == "https" || scheme == "http", Self.telegramHosts.contains(host) else {
            guard !host.isEmpty || scheme == "mailto" || scheme == "tel" else { return nil }
            self = .external(url)
            return
        }

        let components = url.path.split(separator: "/").map(String.init)
        guard let first = components.first,
              !Self.reservedPaths.contains(first.lowercased()),
              Self.isUsername(first) else {
            self = .unsupported
            return
        }
        // t.me/<username> or a message link t.me/<username>/<id>; the chat
        // is what Orbitext can open.
        if components.count == 1 || (components.count == 2 && Int64(components[1]) != nil) {
            self = .publicChat(username: first)
        } else {
            self = .unsupported
        }
    }

    private static func resolveTGLink(_ url: URL) -> TelegramLink {
        guard url.host?.lowercased() == "resolve",
              let domain = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "domain" })?.value,
              isUsername(domain) else {
            return .unsupported
        }
        return .publicChat(username: domain)
    }

    /// Telegram usernames: a letter followed by letters, digits or
    /// underscores, 4-32 characters in total.
    static func isUsername(_ value: String) -> Bool {
        guard (4...32).contains(value.count),
              let first = value.unicodeScalars.first,
              CharacterSet.letters.contains(first), first.isASCII else { return false }
        return value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_")
        }
    }
}
