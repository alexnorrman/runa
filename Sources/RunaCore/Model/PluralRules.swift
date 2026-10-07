import Foundation

/// CLDR plural categories, in CLDR order.
public enum PluralCategory: String, CaseIterable, Codable, Sendable, Comparable, CodingKeyRepresentable {
    case zero, one, two, few, many, other

    public static func < (lhs: PluralCategory, rhs: PluralCategory) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Which plural categories each language uses, from CLDR 44 cardinal rules.
///
/// `categories(for:)` returns every category CLDR defines for the language.
/// `requiredCategories(for:)` leaves out categories that only apply to decimals or compact
/// numbers ("1,5 millions"), which UI counts almost never hit. Missing-translation warnings use
/// the required set so French does not nag for a `many` form nobody writes.
public enum PluralRules {
    public static func categories(for locale: LocaleCode) -> [PluralCategory] {
        let language = locale.language
        if let rule = table[language] { return rule.all }
        return [.one, .other]
    }

    public static func requiredCategories(for locale: LocaleCode) -> [PluralCategory] {
        let language = locale.language
        if let rule = table[language] { return rule.required }
        return [.one, .other]
    }

    public static func isOptional(_ category: PluralCategory, for locale: LocaleCode) -> Bool {
        !requiredCategories(for: locale).contains(category)
    }

    private struct Rule {
        let all: [PluralCategory]
        let optional: Set<PluralCategory>
        var required: [PluralCategory] { all.filter { !optional.contains($0) } }
    }

    private static let table: [String: Rule] = {
        var table: [String: Rule] = [:]
        func add(_ languages: String, _ all: [PluralCategory], optional: Set<PluralCategory> = []) {
            for language in languages.split(separator: " ") {
                table[String(language)] = Rule(all: all, optional: optional)
            }
        }
        add("bm bo dz hnj id ig ii in ja jbo jv jw kde kea km ko lkt lo ms my nqo osa sah ses sg su th to tpi vi wo yo yue zh",
            [.other])
        add("af an asa az bal bem bez bg brx ce cgg chr ckb dv ee el eo eu fo fur gsw ha haw hu jgo jmc ka kaj kcg kk kkj kl ks ksb ku ky lb lg mas mgo ml mn mr nah nb nd ne nn nnh no nr ny nyn om or os pap ps rm rof rwk saq sd sdh seh sn so sq ss ssy st syr ta te teo tig tk tn tr ts ug uz ve vo vun wae xh xog ast de en et fi fy gl ia io ji lij nl sc sv sw ur yi am as bn doi fa gu hi kn pcm zu ak bho guw ln mg nso pa ti wa tzm da is mk ceb fil tl hy ff kab si",
            [.one, .other])
        add("fr es it pt ca vec", [.one, .many, .other], optional: [.many])
        add("lv prg", [.zero, .one, .other])
        add("ksh lag", [.zero, .one, .other])
        add("ga gv br", [.one, .two, .few, .many, .other])
        add("gd sl dsb hsb", [.one, .two, .few, .other])
        add("he iu naq sat se sma smi smj smn sms", [.one, .two, .other])
        add("cs sk lt", [.one, .few, .many, .other], optional: [.many])
        add("pl be ru uk", [.one, .few, .many, .other])
        add("mt", [.one, .two, .few, .many, .other])
        add("ro mo bs hr sh sr shi", [.one, .few, .other])
        add("ar ars cy kw", [.zero, .one, .two, .few, .many, .other])
        return table
    }()
}
