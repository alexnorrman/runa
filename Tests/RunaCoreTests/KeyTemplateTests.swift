import Foundation
import Testing
@testable import RunaCore

/// Shared with figma-plugin/test/keys.test.ts and docs/SHEET_FORMAT.md: both implementations must agree.
let templateVectors: [(template: String, name: String, valid: Bool, platform: Platform?)] = [
    ("{platform?}_{feature}_{description}_{type:title|text|action}", "home_welcomeCard_title", true, nil),
    ("{platform?}_{feature}_{description}_{type:title|text|action}", "common_ok_action", true, nil),
    ("{platform?}_{feature}_{description}_{type:title|text|action}", "ios_checkout_continueWithApplePay_action", true, .ios),
    ("{platform?}_{feature}_{description}_{type:title|text|action}", "android_settings_openGooglePlay_action", true, .android),
    ("{platform?}_{feature}_{description}_{type:title|text|action}", "web_footer_terms_text", true, .web),
    ("{platform?}_{feature}_{description}_{type:title|text|action}", "home_welcomeCard_heading", false, nil),
    ("{platform?}_{feature}_{description}_{type:title|text|action}", "Home_welcomeCard_title", false, nil),
    ("{platform?}_{feature}_{description}_{type:title|text|action}", "home_welcome_card_title", false, nil),
    ("{platform?}_{feature}_{description}_{type:title|text|action}", "ios_title", false, nil),
    ("{platform?}_{feature}_{description}_{type:title|text|action}", "profile_friendsCount_text.one", false, nil),
    ("{platform?:ios|android}_{feature}_{description}", "web_footer_terms", false, nil),
    ("{feature}.{description}", "checkout.summaryTitle", true, nil),
    ("{feature}.{description}", "checkout.summary.title", false, nil),
    ("{feature}_{description}_{variant?}", "home_title", true, nil),
    ("{feature}_{description}_{variant?}", "home_title_short", true, nil),
]

@Suite struct KeyTemplateTests {
    @Test func sharedVectors() throws {
        for vector in templateVectors {
            let rules = KeyNamingRules(ProjectGuidelines(keyTemplate: vector.template))
            #expect(rules.configurationProblems.isEmpty)
            #expect((rules.problem(with: vector.name) == nil) == vector.valid, "\(vector.template) \(vector.name)")
            #expect(rules.platform(in: vector.name) == vector.platform, "\(vector.name)")
        }
    }

    @Test func parsesParts() throws {
        let template = try KeyTemplate("{platform?}_{feature}_{type:title|text}")
        #expect(template.parts == [.token(name: "platform", optional: true, choices: []), .literal("_"),
                                   .token(name: "feature", optional: false, choices: []), .literal("_"),
                                   .token(name: "type", optional: false, choices: ["title", "text"])])
        #expect(template.platformOptions == [.ios, .android, .web])
        #expect(try KeyTemplate("{platform:ios|android}.{x}").platformOptions == [.ios, .android])
    }

    @Test func rejectsBrokenTemplates() {
        for broken in ["{feature", "feature}", "plain", "{}", "{feature:}", "{a b}", "{platform}_{platform}"] {
            #expect(throws: KeyTemplate.ParseError.self) { try KeyTemplate(broken) }
            let rules = KeyNamingRules(ProjectGuidelines(keyTemplate: broken))
            #expect(!rules.configurationProblems.isEmpty, "\(broken)")
            #expect(!rules.isActive)
            #expect(rules.problem(with: "anything.goes") == nil)
        }
    }

    @Test func customPatternWins() {
        let rules = KeyNamingRules(ProjectGuidelines(keyTemplate: "{feature}_{description}", keyPattern: "^[a-z]+(\\.[a-z]+)+$"))
        #expect(rules.problem(with: "checkout.title") == nil)
        #expect(rules.problem(with: "checkout_title") != nil)
        #expect(rules.formatDescription == "a name matching ^[a-z]+(\\.[a-z]+)+$")
        #expect(rules.problem(with: "checkout_title")?.contains("key pattern") == true)
        // A broken pattern falls back to the template, and says so.
        let fallback = KeyNamingRules(ProjectGuidelines(keyTemplate: "{feature}_{description}", keyPattern: "(["))
        #expect(fallback.problem(with: "checkout_title") == nil)
        #expect(fallback.problem(with: "checkout.title")?.contains("key format") == true)
        #expect(fallback.formatDescription == "{feature}_{description}")
        #expect(!KeyNamingRules(ProjectGuidelines(keyPattern: "([")).configurationProblems.isEmpty)
    }

    @Test func explainsPluralSuffixes() {
        let rules = KeyNamingRules(ProjectGuidelines(keyTemplate: "{feature}_{description}_{type:title|text|action}"))
        let problem = rules.problem(with: "profile_friendsCount_text.one")
        #expect(problem?.contains("Plural forms are not part of the key name") == true)
        #expect(problem?.contains("profile_friendsCount_text") == true)
        #expect(rules.problem(with: "home_title")?.contains("{feature}_{description}_{type:title|text|action}") == true)
    }

    @Test func noRulesMeansBasicSyntaxOnly() {
        let rules = KeyNamingRules(ProjectGuidelines())
        #expect(!rules.isActive)
        #expect(rules.problem(with: "checkout.summary.title") == nil)
        #expect(rules.problem(with: "has space") != nil)
        #expect(rules.platform(in: "ios_anything") == nil)
    }

    @Test func platformPrefixesMatchPlatforms() {
        let rules = KeyNamingRules(ProjectGuidelines(keyTemplate: "{platform?}_{feature}_{description}_{type:title|text|action}"))
        #expect(rules.impliedPlatforms(for: "ios_checkout_pay_action") == [.ios])
        #expect(rules.impliedPlatforms(for: "checkout_pay_action") == nil)
        #expect(rules.platformProblem(for: StringKey(key: "ios_checkout_pay_action", platforms: [.ios])) == nil)
        #expect(rules.platformProblem(for: StringKey(key: "ios_checkout_pay_action"))?.contains("every platform") == true)
        #expect(rules.platformProblem(for: StringKey(key: "ios_checkout_pay_action", platforms: [.ios, .android])) != nil)
        #expect(rules.platformProblem(for: StringKey(key: "checkout_pay_action", platforms: [.android]))?.contains("start with android") == true)
        #expect(rules.platformProblem(for: StringKey(key: "checkout_pay_action", platforms: [.ios, .android])) == nil)
        #expect(rules.platformProblem(for: StringKey(key: "checkout_pay_action")) == nil)
        // Without a platform part, platforms are nobody's business.
        let plain = KeyNamingRules(ProjectGuidelines(keyTemplate: "{feature}_{description}_{type:title|text|action}"))
        #expect(plain.platformProblem(for: StringKey(key: "checkout_pay_action", platforms: [.ios])) == nil)
    }

    @Test func mergeKeepsBothSidesAndFlagsOverlaps() throws {
        let base = ProjectGuidelines(naming: "v1", styleGuides: ["sv": "du"])
        var mine = base
        mine.styleGuides["de"] = "Sie"
        var theirs = base
        theirs.naming = "v2"
        let merged = try ProjectGuidelines.merge(mine: mine, base: base, theirs: theirs)
        #expect(merged.naming == "v2")
        #expect(merged.styleGuides == ["sv": "du", "de": "Sie"])

        mine.styleGuides["sv"] = "ni"
        theirs.styleGuides["sv"] = "du, kort"
        #expect(throws: BackendError.self) { try ProjectGuidelines.merge(mine: mine, base: base, theirs: theirs) }

        // The same change on both sides is not a conflict.
        theirs.styleGuides["sv"] = "ni"
        #expect(try ProjectGuidelines.merge(mine: mine, base: base, theirs: theirs).styleGuides["sv"] == "ni")
    }

    @Test func glossaryComparesByContentNotID() {
        let a = ProjectGuidelines(glossary: [GlossaryTerm(term: "League", translations: ["sv": "Liga"])])
        var b = a
        b.glossary[0].id = UUID()
        #expect(b.changes(from: a).isEmpty)
        b.glossary[0].note = "Sports league"
        #expect(b.changes(from: a).map(\.topic) == ["glossary"])
    }

    @Test func snapshotsCachedBeforeGuidelinesStillDecode() throws {
        let snapshot = Snapshot(settings: ProjectSettings(name: "P", sourceLocale: "en"), guidelines: ProjectGuidelines(naming: "x"))
        var json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(snapshot)) as! [String: Any]
        json["guidelines"] = nil
        let old = try JSONDecoder().decode(Snapshot.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(old.guidelines.isEmpty)
    }
}
