import Foundation

/// A license or notice text bundled with the app. The notice terms of the
/// third-party code in the binary (MIT, BSD-3-Clause, Apache-2.0, FTL,
/// MPL-2.0) require the texts in every distributed copy; project.yml copies
/// THIRD_PARTY_NOTICES.md, LICENSE, LICENSES/ and the rlottie licenses into
/// the app bundle, and Settings -> Open-Source Licenses shows them.
struct LicenseDocument: Identifiable, Hashable, Sendable {
    enum Title: Hashable, Sendable {
        /// A Localizable.strings key, for the documents the app names itself.
        case localized(String)
        /// A component or license name, shown as is in every language.
        case verbatim(String)
    }

    let title: Title
    let resourceName: String
    let resourceExtension: String?

    var id: String { fileName }

    /// The file's name in the bundle, which project.yml copies flat.
    var fileName: String {
        resourceExtension.map { "\(resourceName).\($0)" } ?? resourceName
    }

    var displayTitle: String {
        switch title {
        case .localized(let key): L10n.string(key)
        case .verbatim(let name): name
        }
    }

    func loadText(from bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

extension LicenseDocument {
    static let thirdPartyNotices = LicenseDocument(
        title: .localized("Third-Party Notices"), resourceName: "THIRD_PARTY_NOTICES", resourceExtension: "md"
    )

    static let appLicense = LicenseDocument(
        title: .localized("Orbitext License (GPL-3.0)"), resourceName: "LICENSE", resourceExtension: nil
    )

    /// One row per license text, in the order of THIRD_PARTY_NOTICES.md.
    static let components: [LicenseDocument] = [
        component("TDLib (BSL-1.0)", "BSL-1.0", "txt"),
        component("SQLCipher (BSD-3-Clause)", "BSD-3-Clause-SQLCipher", "txt"),
        component("OpenSSL (Apache-2.0)", "Apache-2.0", "txt"),
        component("rlottie (MIT)", "COPYING", "MIT"),
        component("FreeType (FTL)", "COPYING", "FTL"),
        component("RapidJSON (MIT)", "COPYING", "RPD"),
        component("stb_image (MIT)", "COPYING", "STB"),
        component("Skia (BSD-3-Clause)", "COPYING", "SKIA"),
        component("Mozilla SMIL (MPL-2.0)", "COPYING", "MPL"),
        component("pixman (MIT)", "COPYING", "PIX"),
        component("QR Code generator (MIT)", "MIT-QRCodeGenerator", "txt"),
    ]

    static let all: [LicenseDocument] = [thirdPartyNotices, appLicense] + components

    private static func component(_ name: String, _ resource: String, _ ext: String) -> LicenseDocument {
        LicenseDocument(title: .verbatim(name), resourceName: resource, resourceExtension: ext)
    }
}

struct LicenseParagraph: Hashable, Sendable {
    let text: String
    let isHeading: Bool
}

/// Reflows a plain-text or Markdown license for the watch screen. The texts
/// are hard-wrapped at about 72 columns, which on a 40-column watch line
/// leaves a short line after every long one, so the lines of a paragraph are
/// joined. List items and numbered clauses keep their own lines; Markdown
/// headings, underlined headings and the MPL's asterisk box are recognized.
enum LicenseText {
    static func paragraphs(_ text: String) -> [LicenseParagraph] {
        var result: [LicenseParagraph] = []
        var lines: [String] = []

        func flush(asHeading: Bool = false) {
            guard !lines.isEmpty else { return }
            result.append(LicenseParagraph(text: lines.joined(separator: "\n"), isHeading: asHeading))
            lines = []
        }

        let physicalLines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for physicalLine in physicalLines {
            let line = unboxed(physicalLine.trimmingCharacters(in: .whitespaces))
            if line.isEmpty {
                flush()
            } else if isUnderline(line) {
                flush(asHeading: true)
            } else if let heading = markdownHeading(line) {
                flush()
                result.append(LicenseParagraph(text: heading, isHeading: true))
            } else if lines.isEmpty || startsListItem(line) {
                lines.append(line)
            } else {
                lines[lines.count - 1] += " " + line
            }
        }
        flush()
        return result
    }

    /// The text inside a `*  ...  *` box line; empty for a border line.
    private static func unboxed(_ line: String) -> String {
        guard line.count > 1, line.first == "*", line.last == "*" else { return line }
        return line.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
    }

    private static func isUnderline(_ line: String) -> Bool {
        line.count >= 3 && (line.allSatisfy { $0 == "=" } || line.allSatisfy { $0 == "-" })
    }

    private static func markdownHeading(_ line: String) -> String? {
        let marks = line.prefix { $0 == "#" }
        guard !marks.isEmpty else { return nil }
        let rest = line.dropFirst(marks.count)
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// "- item", "* item", "1. clause", "1.1. clause", "(a) clause", "iv) clause".
    private static func startsListItem(_ line: String) -> Bool {
        line.firstMatch(of: #/^(?:[-*]|\(?(?:[0-9]{1,3}(?:\.[0-9]{1,3})*|[a-z]|[ivx]{1,4})[.)])\s/#) != nil
    }
}
