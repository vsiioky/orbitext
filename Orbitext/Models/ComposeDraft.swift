import Foundation

enum ComposeDraft {
    static func matchesSubmitted(_ current: String?, submitted: String) -> Bool {
        current?.trimmingCharacters(in: .whitespacesAndNewlines) == submitted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Suggestions fill the editor; sending remains an explicit action.
    static func appending(_ suggestion: String, to draft: String, limit: Int = AppConstants.Message.charLimit) -> String {
        let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
        return String((draft + separator + suggestion).prefix(max(0, limit)))
    }
}
