import Foundation

/// Fuzzy key search shared by the app, `runa keys search` and the MCP server.
public enum KeySearch {
    public static func search(_ query: String, in snapshot: Snapshot, limit: Int) -> [StringKey] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return Array(snapshot.keys.sorted { $0.key < $1.key }.prefix(limit)) }
        let scored = snapshot.keys.compactMap { key -> (StringKey, Int)? in
            var best = score(needle, key.key.lowercased(), weight: 3)
            for translation in key.translations.values {
                for text in translation.forms.values { best = max(best, score(needle, text.lowercased(), weight: 2)) }
            }
            best = max(best, score(needle, key.description.lowercased(), weight: 1))
            return best > 0 ? (key, best) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.key < $1.0.key }.prefix(limit).map(\.0)
    }

    /// Exact substring beats prefix-of-word beats in-order subsequence.
    public static func score(_ needle: String, _ haystack: String, weight: Int) -> Int {
        if haystack == needle { return 1000 * weight }
        if haystack.contains(needle) { return (haystack.hasPrefix(needle) ? 600 : 400) * weight }
        var index = haystack.startIndex
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return 0 }
            index = haystack.index(after: found)
        }
        return 100 * weight
    }
}
