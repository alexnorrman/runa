import Foundation
import Testing
@testable import RunaCore

@Suite struct LocaleCodeTests {
    @Test func normalizes() {
        #expect(LocaleCode(rawValue: "pt_br")?.rawValue == "pt-BR")
        #expect(LocaleCode(rawValue: "ZH-hans")?.rawValue == "zh-Hans")
        #expect(LocaleCode(rawValue: "EN")?.rawValue == "en")
        #expect(LocaleCode(rawValue: "es-419")?.rawValue == "es-419")
        #expect(LocaleCode(rawValue: "english") == nil)
        #expect(LocaleCode(rawValue: "1a") == nil)
        #expect(LocaleCode(rawValue: "") == nil)
    }

    @Test func knowsRealLanguages() {
        #expect(LocaleCode("sv").isKnownLanguage)
        #expect(!LocaleCode("xq").isKnownLanguage)
        #expect(LocaleCode("ar").isRightToLeft)
        #expect(LocaleCode("sv").displayName() == "Swedish")
    }

    @Test func androidFolders() {
        #expect(KeyNaming.androidValuesFolder("sv", isDefault: false, legacyCodes: true) == "values-sv")
        #expect(KeyNaming.androidValuesFolder("pt-BR", isDefault: false, legacyCodes: true) == "values-pt-rBR")
        #expect(KeyNaming.androidValuesFolder("zh-Hans", isDefault: false, legacyCodes: true) == "values-b+zh+Hans")
        #expect(KeyNaming.androidValuesFolder("he", isDefault: false, legacyCodes: true) == "values-iw")
        #expect(KeyNaming.androidValuesFolder("he", isDefault: false, legacyCodes: false) == "values-he")
        #expect(KeyNaming.locale(fromAndroidFolder: "values-pt-rBR") == "pt-BR")
        #expect(KeyNaming.locale(fromAndroidFolder: "values-iw") == "he")
        #expect(KeyNaming.locale(fromAndroidFolder: "values-b+zh+Hans") == "zh-Hans")
        #expect(KeyNaming.locale(fromAndroidFolder: "values-night") == nil)
        #expect(KeyNaming.locale(fromAndroidFolder: "values") == nil)
    }

    @Test func androidNames() {
        #expect(KeyNaming.androidName("checkout.summary-title") == "checkout_summary_title")
        #expect(KeyNaming.androidName("1st.place") == "_1st_place")
    }
}

@Suite struct PluralRulesTests {
    @Test func categories() {
        #expect(PluralRules.categories(for: "en") == [.one, .other])
        #expect(PluralRules.categories(for: "ru") == [.one, .few, .many, .other])
        #expect(PluralRules.categories(for: "ja") == [.other])
        #expect(PluralRules.categories(for: "ar") == PluralCategory.allCases)
        #expect(PluralRules.categories(for: "pt-BR") == [.one, .many, .other])
        #expect(PluralRules.categories(for: "xx") == [.one, .other])
    }

    @Test func requiredLeavesOutCompactNumberForms() {
        #expect(PluralRules.requiredCategories(for: "fr") == [.one, .other])
        #expect(PluralRules.requiredCategories(for: "cs") == [.one, .few, .other])
        #expect(PluralRules.requiredCategories(for: "pl") == [.one, .few, .many, .other])
        #expect(PluralRules.isOptional(.many, for: "fr"))
    }
}

@Suite struct CanonicalTextTests {
    @Test func parsesPlaceholders() {
        let segments = CanonicalText.parse("Hi {name}, {count:int} new, {price:double.2} {bad:type} { spaced } {1x}")
        #expect(segments == [
            .literal("Hi "), .placeholder(Placeholder(name: "name")), .literal(", "),
            .placeholder(Placeholder(name: "count", type: .int)), .literal(" new, "),
            .placeholder(Placeholder(name: "price", type: .double(precision: 2))),
            .literal(" {bad:type} { spaced } {1x}"),
        ])
    }

    @Test func uniquePlaceholdersPreferTypedUse() {
        #expect(CanonicalText.placeholders(in: "{n} of {n:int} and {name}") == [Placeholder(name: "n", type: .int), Placeholder(name: "name")])
    }

    @Test func rendersRoundTrip() {
        let text = "Hi {name}, {count:int} {x:double.1} {curly }"
        #expect(CanonicalText.render(CanonicalText.parse(text)) == text)
    }
}

@Suite struct PlaceholderConverterTests {
    let greetingOrder = [Placeholder(name: "name"), Placeholder(name: "place")]

    @Test func appleSingleArgumentIsNotPositional() {
        let options = RenderOptions(argumentOrder: [Placeholder(name: "name")])
        #expect(PlaceholderConverter.render("Hello {name}", flavor: .apple, options: options) == "Hello %@")
    }

    @Test func appleMultipleArgumentsArePositional() {
        let options = RenderOptions(argumentOrder: greetingOrder)
        #expect(PlaceholderConverter.render("{place} welcomes {name}", flavor: .apple, options: options) == "%2$@ welcomes %1$@")
    }

    @Test func androidIsAlwaysPositional() {
        let options = RenderOptions(argumentOrder: [Placeholder(name: "price", type: .double(precision: 2))])
        #expect(PlaceholderConverter.render("Total {price:double.2}", flavor: .android, options: options) == "Total %1$.2f")
        let count = RenderOptions(argumentOrder: [Placeholder(name: "count", type: .int)])
        #expect(PlaceholderConverter.render("{count:int} items", flavor: .android, options: count) == "%1$d items")
    }

    @Test func percentEscapedOnlyWithArguments() {
        let none = RenderOptions(argumentOrder: [])
        #expect(PlaceholderConverter.render("100% sure", flavor: .apple, options: none) == "100% sure")
        let count = RenderOptions(argumentOrder: [Placeholder(name: "count", type: .int)])
        #expect(PlaceholderConverter.render("{count:int}% done", flavor: .apple, options: count) == "%lld%% done")
    }

    @Test func i18nextRenamesPluralVariable() {
        let options = RenderOptions(argumentOrder: [Placeholder(name: "n", type: .int)], pluralVariable: "n")
        #expect(PlaceholderConverter.render("{n:int} items for {who}", flavor: .i18next, options: options) == "{{count}} items for {{who}}")
    }

    @Test func icuEscapesLiterals() {
        let options = RenderOptions(argumentOrder: [Placeholder(name: "name")])
        #expect(PlaceholderConverter.render("It's {name}'s {turn}", flavor: .icu, options: options) == "It''s {name}''s {turn}")
        #expect(PlaceholderConverter.render("a { b", flavor: .icu, options: options) == "a '{' b")
    }

    @Test func parsesPrintfWithNames() {
        #expect(PlaceholderConverter.parse("Hello %@", flavor: .apple, names: [Placeholder(name: "name")]) == "Hello {name}")
        #expect(PlaceholderConverter.parse("%2$@ welcomes %1$@", flavor: .apple, names: greetingOrder) == "{place} welcomes {name}")
    }

    @Test func parsesPrintfWithoutNames() {
        #expect(PlaceholderConverter.parse("%1$s has %2$d", flavor: .android) == "{arg1} has {arg2:int}")
        #expect(PlaceholderConverter.parse("%d%% done", flavor: .android) == "{count:int}% done")
        #expect(PlaceholderConverter.parse("Total %.2f", flavor: .apple) == "Total {number:double.2}")
        #expect(PlaceholderConverter.parse("%lld items", flavor: .apple) == "{count:int} items")
        #expect(PlaceholderConverter.parse("100%", flavor: .apple) == "100%")
        #expect(PlaceholderConverter.parse("100% secure, 50% off, 2% each", flavor: .apple) == "100% secure, 50% off, 2% each")
    }

    @Test func parsesI18next() {
        #expect(PlaceholderConverter.parse("Hi {{ name }}", flavor: .i18next) == "Hi {name}")
        #expect(PlaceholderConverter.parse("{{count}} items", flavor: .i18next, names: [Placeholder(name: "n", type: .int)]) == "{n:int} items")
    }

    @Test func parsesICU() {
        #expect(PlaceholderConverter.parse("It''s {name}, '{'x'}' {n, number, integer}", flavor: .icu) == "It's {name}, {x} {n:int}")
    }

    @Test func roundTripsEveryFlavor() {
        let order = [Placeholder(name: "name"), Placeholder(name: "count", type: .int), Placeholder(name: "price", type: .double(precision: 2))]
        let text = "{name} bought {count:int} for {price:double.2}"
        for flavor in [PlaceholderFlavor.apple, .android] {
            let rendered = PlaceholderConverter.render(text, flavor: flavor, options: RenderOptions(argumentOrder: order))
            #expect(PlaceholderConverter.parse(rendered, flavor: flavor, names: order) == text, "\(flavor)")
        }
        let icu = PlaceholderConverter.render(text, flavor: .icu, options: RenderOptions(argumentOrder: order))
        #expect(PlaceholderConverter.parse(icu, flavor: .icu) == "{name} bought {count:int} for {price:double}")
    }
}

@Suite struct StatusTests {
    @Test func effectiveStatus() {
        var snapshot = Sample.snapshot
        let checkout = snapshot[id: Sample.checkoutID]!
        #expect(snapshot.status(of: checkout, locale: "sv") == .approved)
        #expect(snapshot.status(of: checkout, locale: "pl") == .missing)
        let greeting = snapshot[id: Sample.greetingID]!
        #expect(snapshot.status(of: greeting, locale: "sv") == .machine)
        let appName = snapshot[id: Sample.appNameID]!
        #expect(snapshot.status(of: appName, locale: "pl") == .approved, "do-not-translate keys use the source")

        // Editing the source makes approved translations stale.
        let index = snapshot.index(of: Sample.checkoutID)!
        snapshot.keys[index].translations["en"] = Translation("Check out")
        #expect(snapshot.status(of: snapshot.keys[index], locale: "sv") == .needsReview)
    }

    @Test func pluralNeedsEveryRequiredForm() {
        var snapshot = Sample.snapshot
        let index = snapshot.index(of: Sample.cartID)!
        snapshot.keys[index].translations["pl"]?.forms[.few] = nil
        #expect(snapshot.status(of: snapshot.keys[index], locale: "pl") == .missing)
    }

    @Test func coverage() {
        let coverage = Sample.snapshot.coverage(for: "pl")
        #expect(coverage.total == 8)
        #expect(coverage.missing == 6)
        #expect(coverage.approved == 2)
    }

    @Test func hashesAreStable() {
        #expect(TextHash.of(forms: [.other: "Hello"]) == TextHash.of(forms: [.other: "Hello", .one: ""]))
        #expect(TextHash.of(forms: [.other: "Hello"]).count == 12)
        #expect(TextHash.uuid(forKey: "a.b") == TextHash.uuid(forKey: "a.b"))
        #expect(TextHash.uuid(forKey: "a.b").lowercased.dropFirst(14).first == "5")
    }
}
