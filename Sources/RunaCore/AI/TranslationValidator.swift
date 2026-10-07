import Foundation

/// Deterministic checks on drafts, independent of the provider. Problems are fed back to the
/// model once; drafts that still fail are reported instead of saved.
public enum TranslationValidator {
    public struct Result: Sendable {
        public var forms: [PluralCategory: String]
        public var errors: [String]
        public var warnings: [String]
    }

    public static func validate(_ draft: TranslationDraft, item: TranslationItem, targetLocale: LocaleCode) -> Result {
        var errors: [String] = []
        var warnings: [String] = []
        var forms: [PluralCategory: String] = [:]
        let allowed = Set(item.requiredForms).union(PluralRules.categories(for: targetLocale))
        for (category, raw) in draft.forms where allowed.contains(category) {
            forms[category] = clean(raw, source: item.source[category] ?? item.source[.other] ?? "")
        }
        for category in item.requiredForms where (forms[category] ?? "").isEmpty {
            errors.append(item.requiredForms == [.other] ? "the translation is empty" : "the \(category.rawValue) form is missing")
        }
        let expected = Set(item.placeholders.map(\.canonical))
        let pluralVariable = item.placeholders.first { $0.type == .int }?.canonical
        for (category, text) in forms {
            let found = Set(CanonicalText.placeholders(in: text).map(\.canonical))
            let unknown = found.subtracting(expected)
            if !unknown.isEmpty {
                errors.append("\(label(category, item))uses \(unknown.sorted().joined(separator: ", ")), which the source does not have")
            }
            var missing = expected.subtracting(found)
            // A plural form may drop the number ("one" written as a word).
            if item.requiredForms != [.other], let pluralVariable { missing.remove(pluralVariable) }
            if !missing.isEmpty {
                errors.append("\(label(category, item))is missing \(missing.sorted().joined(separator: ", "))")
            }
            if let source = item.source[category] ?? item.source[.other], source.count >= 12, text == source {
                warnings.append("\(label(category, item))is identical to the source")
            }
            if let width = item.figma?.width, let source = item.source[category] ?? item.source[.other], source.count >= 8,
               Double(text.count) > Double(source.count) * 1.5, width > 0
            {
                warnings.append("\(label(category, item))is much longer than the source and may not fit the design")
            }
        }
        return Result(forms: forms, errors: errors, warnings: warnings)
    }

    static func label(_ category: PluralCategory, _ item: TranslationItem) -> String {
        item.requiredForms == [.other] ? "the translation " : "the \(category.rawValue) form "
    }

    /// Removes wrapping quotes and stray whitespace models sometimes add.
    static func clean(_ text: String, source: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIsQuoted = ["\"", "“", "«", "„"].contains { source.hasPrefix($0) }
        for (open, close) in [("\"", "\""), ("“", "”"), ("«", "»"), ("„", "“")]
        where !sourceIsQuoted && result.count >= 2 && result.hasPrefix(open) && result.hasSuffix(close) {
            result = String(result.dropFirst().dropLast())
        }
        // Keep the source's own leading/trailing spaces (rare, but intentional when present).
        if source.hasSuffix(" ") && !result.hasSuffix(" ") { result += " " }
        if source.hasPrefix(" ") && !result.hasPrefix(" ") { result = " " + result }
        return result
    }
}
