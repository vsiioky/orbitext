import Foundation

extension Array where Element: Identifiable {
    /// Finds the element with the given `id` and applies `block` to it in-place.
    /// Returns `true` if the element was found and mutated, `false` otherwise.
    @discardableResult
    mutating func update(where id: Element.ID, _ block: (inout Element) -> Void) -> Bool {
        guard let idx = firstIndex(where: { $0.id == id }) else { return false }
        block(&self[idx])
        return true
    }
}
