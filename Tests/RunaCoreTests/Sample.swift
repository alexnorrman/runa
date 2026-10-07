import Foundation
@testable import RunaCore

enum Sample {
    static let checkoutID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let cartID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let greetingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let appNameID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    static let percentID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    static let androidOnlyID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    static let progressID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    static let quoteID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    static var snapshot: Snapshot {
        let settings = ProjectSettings(name: "Demo", sourceLocale: "en", locales: ["en", "sv", "pl"])
        var keys: [StringKey] = []
        keys.append(StringKey(id: checkoutID, key: "checkout.title", description: "Title on the checkout screen",
                              translations: ["en": Translation("Checkout"), "sv": Translation("Kassa")]))
        keys.append(StringKey(id: cartID, key: "cart.items", isPlural: true, translations: [
            "en": Translation(forms: [.one: "{count:int} item", .other: "{count:int} items"]),
            "sv": Translation(forms: [.one: "{count:int} vara", .other: "{count:int} varor"]),
            "pl": Translation(forms: [.one: "{count:int} produkt", .few: "{count:int} produkty", .many: "{count:int} produktów",
                                      .other: "{count:int} produktu"]),
        ]))
        keys.append(StringKey(id: greetingID, key: "greeting", translations: [
            "en": Translation("Hello {name}, welcome to {place}!"),
            "sv": Translation("Hej {name}, välkommen till {place}!", status: .machine),
        ]))
        keys.append(StringKey(id: appNameID, key: "app.name", tags: [StringKey.doNotTranslateTag], translations: ["en": Translation("Runa")]))
        keys.append(StringKey(id: percentID, key: "legal.percent", translations: [
            "en": Translation("100% secure"), "sv": Translation("100 % säker"),
        ]))
        keys.append(StringKey(id: progressID, key: "progress", translations: [
            "en": Translation("{count:int}% done"), "sv": Translation("{count:int} % klart"),
        ]))
        keys.append(StringKey(id: androidOnlyID, key: "android.only", platforms: [.android], translations: ["en": Translation("Only Android")]))
        keys.append(StringKey(id: quoteID, key: "quote.text", translations: [
            "en": Translation("It's \"quoted\" & <b>bold</b>\nsecond line"),
        ]))
        // Record source hashes so the sample's approved translations are not stale.
        var snapshot = Snapshot(settings: settings, keys: keys, fetchedAt: Date(timeIntervalSince1970: 0))
        for index in snapshot.keys.indices {
            let hash = snapshot.sourceHash(of: snapshot.keys[index])
            for locale in snapshot.keys[index].translations.keys where locale != "en" {
                snapshot.keys[index].translations[locale]?.sourceHash = hash
            }
        }
        return snapshot
    }
}
