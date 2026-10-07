import Foundation

/// Xcode String Catalogs (`.xcstrings`). One file holds every locale.
///
/// Output matches what Xcode writes byte for byte (key order, ` : ` separators, empty objects),
/// so opening the catalog in Xcode does not churn the diff.
public enum XCStringsFormat {
    public static func export(_ snapshot: Snapshot, options: ExportOptions = ExportOptions(), fileName: String = "Localizable.xcstrings") -> ExportResult {
        let context = ExportContext(snapshot: snapshot, options: options, platform: .ios)
        var strings: [String: JSONValue] = [:]
        for key in context.keys {
            var entry: [(String, JSONValue)] = []
            if options.includeComments, !key.description.isEmpty { entry.append(("comment", .string(key.description))) }
            entry.append(("extractionState", .string("manual")))
            let render = context.renderOptions(for: key)
            var localizations: [String: JSONValue] = [:]
            for locale in snapshot.settings.locales {
                guard let forms = context.forms(for: key, locale: locale) else { continue }
                let state = stateString(context.status(key, locale))
                func unit(_ text: String) -> JSONValue {
                    .object([("stringUnit", .object([
                        ("state", .string(state)),
                        ("value", .string(PlaceholderConverter.render(text, flavor: .apple, options: render))),
                    ]))])
                }
                if key.isPlural {
                    var plural: [String: JSONValue] = [:]
                    for (category, text) in forms { plural[category.rawValue] = unit(text) }
                    localizations[locale.rawValue] = .object([("variations", .object([("plural", JSONValue.sortedObject(plural))]))])
                } else if let text = forms[.other] {
                    localizations[locale.rawValue] = unit(text)
                }
            }
            if !localizations.isEmpty { entry.append(("localizations", JSONValue.sortedObject(localizations))) }
            if key.doNotTranslate { entry.append(("shouldTranslate", .bool(false))) }
            strings[key.key] = .object(entry)
        }
        let root = JSONValue.object([
            ("sourceLanguage", .string(snapshot.settings.sourceLocale.rawValue)),
            ("strings", JSONValue.sortedObject(strings)),
            ("version", .string("1.0")),
        ])
        return ExportResult(files: [ExportedFile(relativePath: fileName, contents: Data(root.serialized(style: .xcode).utf8))], warnings: [])
    }

    static func stateString(_ status: TranslationStatus) -> String {
        switch status {
        case .approved: "translated"
        case .machine, .needsReview: "needs_review"
        case .missing: "new"
        }
    }

    static func status(fromState state: String?) -> TranslationStatus? {
        switch state {
        case "translated": .approved
        case "needs_review", "stale": .needsReview
        default: nil
        }
    }

    /// Reads every locale from a catalog. Device and width variations use their `other`/default
    /// branch; substitutions (several plurals in one string) are reported as warnings and skipped.
    public static func parse(_ data: Data, file: String) throws -> (entries: [ImportedEntry], sourceLocale: LocaleCode?, warnings: [String]) {
        let root = try JSONValue.parse(data)
        guard let strings = root["strings"]?.objectMembers else {
            throw FormatError.invalidFile(file, reason: "No \"strings\" object")
        }
        let sourceLocale = root["sourceLanguage"]?.stringValue.flatMap(LocaleCode.init(rawValue:))
        var entries: [ImportedEntry] = []
        var warnings: [String] = []
        for (key, entry) in strings {
            let comment = entry["comment"]?.stringValue
            let translatable = entry["shouldTranslate"]?.boolValue ?? true
            for (localeName, localization) in entry["localizations"]?.objectMembers ?? [] {
                guard let locale = LocaleCode(rawValue: localeName) else {
                    warnings.append("\(key): unknown locale \(localeName)")
                    continue
                }
                if localization["substitutions"] != nil {
                    warnings.append("\(key) [\(locale)]: substitutions are not supported yet and were skipped")
                    continue
                }
                if let unit = localization["stringUnit"], let value = unit["value"]?.stringValue {
                    entries.append(ImportedEntry(key: key, locale: locale, forms: [.other: value], comment: comment, translatable: translatable,
                                                 flavor: .apple, status: status(fromState: unit["state"]?.stringValue), file: file))
                } else if let variations = localization["variations"] {
                    if let plural = variations["plural"]?.objectMembers {
                        var forms: [PluralCategory: String] = [:]
                        var state: String?
                        for (categoryName, variation) in plural {
                            guard let category = PluralCategory(rawValue: categoryName),
                                let unit = variation["stringUnit"], let value = unit["value"]?.stringValue
                            else { continue }
                            forms[category] = value
                            state = state ?? unit["state"]?.stringValue
                        }
                        entries.append(ImportedEntry(key: key, locale: locale, isPlural: true, forms: forms, comment: comment,
                                                     translatable: translatable, flavor: .apple, status: status(fromState: state), file: file))
                    } else if let device = variations["device"]?.objectMembers {
                        let branch = device.first { $0.0 == "other" }?.1 ?? device.first?.1
                        if let value = branch?["stringUnit"]?["value"]?.stringValue {
                            entries.append(ImportedEntry(key: key, locale: locale, forms: [.other: value], comment: comment, translatable: translatable,
                                                         flavor: .apple, file: file))
                            warnings.append("\(key) [\(locale)]: device variations were flattened to one value")
                        }
                    }
                }
            }
        }
        return (entries, sourceLocale, warnings)
    }
}
