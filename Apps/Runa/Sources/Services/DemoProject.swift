import Foundation
import RunaCore

/// A small local project for trying Runa without any setup.
enum DemoProject {
    static func create() throws -> ProjectRecord {
        let url = Storage.directory("Demo").appendingPathComponent("Demo \(Int(Date().timeIntervalSince1970)).runa.json")
        let settings = ProjectSettings(name: "Demo shop", sourceLocale: "en", locales: ["sv", "de", "pl"])
        func key(_ name: String, _ description: String, _ en: String, sv: String? = nil, de: String? = nil, pl: String? = nil,
                 status: TranslationStatus = .approved, tags: [String] = []) -> StringKey
        {
            var translations: [LocaleCode: Translation] = ["en": Translation(en)]
            if let sv { translations["sv"] = Translation(sv, status: status) }
            if let de { translations["de"] = Translation(de, status: status) }
            if let pl { translations["pl"] = Translation(pl, status: status) }
            return StringKey(key: name, description: description, tags: tags, translations: translations)
        }
        var keys = [
            key("app.name", "The product name", "Runa", tags: [StringKey.doNotTranslateTag]),
            key("checkout.title", "Title of the checkout screen", "Checkout", sv: "Kassa", de: "Kasse", pl: "Kasa"),
            key("checkout.pay_button", "Primary button that charges the card", "Pay {amount}", sv: "Betala {amount}", de: "{amount} bezahlen"),
            key("checkout.summary.total", "Label before the order total", "Total", sv: "Totalt", de: "Gesamt"),
            key("checkout.delivery.estimate", "Shown under the delivery address", "Arrives {date}", sv: "Levereras {date}", status: .machine),
            key("profile.title", "Title of the profile screen", "Profile", sv: "Profil", de: "Profil", pl: "Profil"),
            key("profile.sign_out", "Destructive button at the bottom of the profile", "Sign out", sv: "Logga ut"),
            key("onboarding.welcome", "First line a new user sees", "Welcome, {name}!", sv: "Välkommen, {name}!", de: "Willkommen, {name}!",
                tags: ["onboarding"]),
            key("onboarding.subtitle", "Below the welcome line", "Your strings, in every language, in one place.", tags: ["onboarding"]),
            key("errors.network", "Shown when a request fails", "Check your connection and try again.", sv: "Kontrollera din anslutning och försök igen."),
        ]
        keys.append(StringKey(key: "cart.items", description: "Badge on the cart icon", isPlural: true, translations: [
            "en": Translation(forms: [.one: "{count:int} item", .other: "{count:int} items"]),
            "sv": Translation(forms: [.one: "{count:int} vara", .other: "{count:int} varor"]),
            "pl": Translation(forms: [.one: "{count:int} produkt", .few: "{count:int} produkty", .other: "{count:int} produktu"]),
        ]))
        keys[2].contexts = [FigmaContext(url: "https://www.figma.com/design/DEMO/Shop?node-id=12-34", fileKey: "DEMO", nodeId: "12:34",
                                         pageName: "Checkout", frameName: "Summary", nodePath: "Summary/Footer/Pay button", width: 327,
                                         height: 48, fontSize: 17, siblingTexts: ["Total", "Delivery", "Edit"])]
        var snapshot = Snapshot(settings: settings, keys: keys)
        for index in snapshot.keys.indices {
            let hash = snapshot.sourceHash(of: snapshot.keys[index])
            for locale in snapshot.keys[index].translations.keys where locale != "en" {
                snapshot.keys[index].translations[locale]?.sourceHash = hash
            }
        }
        _ = try LocalJSONBackend.create(at: url, settings: settings, keys: snapshot.keys)
        return ProjectRecord(name: settings.name, location: .localJSON(path: url.path))
    }
}
