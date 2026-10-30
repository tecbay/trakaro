import Foundation

/// Subsequence matching with bonuses, for the command palette. "gmy" matches "Go to My issues".
///
/// Each matched character scores 1, plus 10 at the very start, 8 at the start of a word, 5 when it directly
/// follows the previous match, minus up to 3 for the gap since the previous match. A query that is a prefix of
/// the text scores 20 more. Spaces in the query are ignored.
public enum FuzzyMatch {
    public static func score(_ query: String, in text: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(text.lowercased())
        var total = 0
        var matched = 0
        var previous = -1
        for (index, character) in haystack.enumerated() where matched < needle.count {
            guard character == needle[matched] else { continue }
            var points = 1
            if index == 0 {
                points += 10
            } else if !(haystack[index - 1].isLetter || haystack[index - 1].isNumber) {
                points += 8
            }
            if previous >= 0 {
                if previous == index - 1 { points += 5 } else { points -= min(index - previous - 1, 3) }
            }
            total += points
            previous = index
            matched += 1
        }
        guard matched == needle.count else { return nil }
        if text.lowercased().hasPrefix(query.lowercased()) { total += 20 }
        return total
    }

    /// Items that match, best first. Ties go to the shorter text, then to the original order.
    public static func rank<Item>(_ items: [Item], query: String, text: (Item) -> String) -> [Item] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.enumerated()
            .compactMap { offset, item in score(query, in: text(item)).map { (item, $0, text(item).count, offset) } }
            .sorted { ($1.1, $0.2, $0.3) < ($0.1, $1.2, $1.3) }
            .map(\.0)
    }
}
