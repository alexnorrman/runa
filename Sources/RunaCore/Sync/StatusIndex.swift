import Foundation

/// Every key's status in every locale, computed once per snapshot. Status checks hash the source
/// text, so views that draw thousands of rows should read this instead of calling
/// `Snapshot.status(of:locale:)` per cell.
public struct StatusIndex: Sendable {
    public let statuses: [UUID: [LocaleCode: TranslationStatus]]
    public let coverage: [LocaleCode: Coverage]

    public init(_ snapshot: Snapshot) {
        var statuses: [UUID: [LocaleCode: TranslationStatus]] = [:]
        var coverage = Dictionary(uniqueKeysWithValues: snapshot.settings.locales.map { ($0, Coverage(locale: $0)) })
        statuses.reserveCapacity(snapshot.keys.count)
        for key in snapshot.keys {
            let sourceHash = snapshot.sourceHash(of: key)
            var row: [LocaleCode: TranslationStatus] = [:]
            for locale in snapshot.settings.locales {
                let status = snapshot.status(of: key, locale: locale, sourceHash: sourceHash)
                row[locale] = status
                coverage[locale]?.total += 1
                switch status {
                case .missing: coverage[locale]?.missing += 1
                case .machine: coverage[locale]?.machine += 1
                case .needsReview: coverage[locale]?.needsReview += 1
                case .approved: coverage[locale]?.approved += 1
                }
            }
            statuses[key.id] = row
        }
        self.statuses = statuses
        self.coverage = coverage
    }

    public static let empty = StatusIndex(Snapshot(settings: ProjectSettings(name: "", sourceLocale: "en")))

    public func status(_ id: UUID, _ locale: LocaleCode) -> TranslationStatus {
        statuses[id]?[locale] ?? .missing
    }

    public func coverage(for locale: LocaleCode) -> Coverage {
        coverage[locale] ?? Coverage(locale: locale)
    }
}
