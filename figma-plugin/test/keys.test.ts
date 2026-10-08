import { describe, expect, it } from "vitest";
import {
  camelWord, formatDescription, keyNameProblem, namingRules, parseTemplate, platformIn, slugSegment, suggestKey, TemplateError, words,
} from "../src/core/keys";
import { asciiFold } from "../src/shared/text";

describe("slugging", () => {
  it("folds to ASCII", () => {
    expect(asciiFold("Hej då, Ærø, Straße, Łódź, Crème brûlée")).toBe("Hej da, AEro, Strasse, Lodz, Creme brulee");
  });
  it("splits into lowercase words", () => {
    expect(words("Checkout — Summary")).toEqual(["checkout", "summary"]);
    expect(words("Don't miss out!")).toEqual(["dont", "miss", "out"]);
    expect(words("👋 ")).toEqual([]);
  });
  it("makes snake_case segments with a word limit", () => {
    expect(slugSegment("Checkout — Summary")).toBe("checkout_summary");
    expect(slugSegment("Pay now and get 10% off today", 4)).toBe("pay_now_and_get");
    expect(slugSegment("Ångström Ölbryggeri", 4)).toBe("angstrom_olbryggeri");
  });
});

describe("suggestKey", () => {
  it("joins the frame slug and the text slug with a dot", () => {
    expect(suggestKey({ frame: "Checkout — Summary", text: "Pay now" })).toBe("checkout_summary.pay_now");
  });
  it("keeps at most four words of the text", () => {
    expect(suggestKey({ frame: "Home", text: "Welcome back to your account, Alex" })).toBe("home.welcome_back_to_your");
  });
  it("uses the page when there is no frame, and the layer name when the text has no words", () => {
    expect(suggestKey({ page: "Onboarding", text: "Next" })).toBe("onboarding.next");
    expect(suggestKey({ frame: "Cart", text: "€ ✓", layerName: "Price label" })).toBe("cart.price_label");
    expect(suggestKey({ text: "…" })).toBe("text");
  });
  it("avoids keys that exist", () => {
    const taken = new Set(["cart.total", "cart.total_2"]);
    expect(suggestKey({ frame: "Cart", text: "Total" }, taken)).toBe("cart.total_3");
  });
  it("produces valid key names", () => {
    expect(keyNameProblem(suggestKey({ frame: "Größe & Farbe", text: "Wähle eine Größe" }))).toBeUndefined();
  });
});

describe("keyNameProblem", () => {
  it("accepts dot notation", () => {
    expect(keyNameProblem("checkout.summary.title")).toBeUndefined();
    expect(keyNameProblem("cart.items_2-b")).toBeUndefined();
  });
  it("rejects empty names, spaces and bad dots", () => {
    expect(keyNameProblem("")).toBeDefined();
    expect(keyNameProblem("pay now")).toMatch(/spaces/);
    expect(keyNameProblem("checkout..title")).toBeDefined();
    expect(keyNameProblem(".title")).toBeDefined();
    expect(keyNameProblem("title.")).toBeDefined();
    expect(keyNameProblem("tïtle")).toBeDefined();
  });
});

// The same vectors as Tests/RunaCoreTests/KeyTemplateTests.swift and docs/SHEET_FORMAT.md.
const TEMPLATE = "{platform?}_{feature}_{description}_{type:title|text|action}";
const VECTORS: [template: string, name: string, valid: boolean, platform: string | undefined][] = [
  [TEMPLATE, "home_welcomeCard_title", true, undefined],
  [TEMPLATE, "common_ok_action", true, undefined],
  [TEMPLATE, "ios_checkout_continueWithApplePay_action", true, "ios"],
  [TEMPLATE, "android_settings_openGooglePlay_action", true, "android"],
  [TEMPLATE, "web_footer_terms_text", true, "web"],
  [TEMPLATE, "home_welcomeCard_heading", false, undefined],
  [TEMPLATE, "Home_welcomeCard_title", false, undefined],
  [TEMPLATE, "home_welcome_card_title", false, undefined],
  [TEMPLATE, "ios_title", false, undefined],
  [TEMPLATE, "profile_friendsCount_text.one", false, undefined],
  ["{platform?:ios|android}_{feature}_{description}", "web_footer_terms", false, undefined],
  ["{feature}.{description}", "checkout.summaryTitle", true, undefined],
  ["{feature}.{description}", "checkout.summary.title", false, undefined],
  ["{feature}_{description}_{variant?}", "home_title", true, undefined],
  ["{feature}_{description}_{variant?}", "home_title_short", true, undefined],
];

describe("key templates", () => {
  it.each(VECTORS)("%s: %s", (template, name, valid, platform) => {
    const rules = namingRules({ keyTemplate: template });
    expect(rules.problems).toEqual([]);
    expect(keyNameProblem(name, rules) === undefined).toBe(valid);
    expect(platformIn(name, rules)).toBe(platform);
  });

  it("parses parts", () => {
    expect(parseTemplate("{platform?}_{feature}_{type:title|text}")).toEqual([
      { kind: "token", name: "platform", optional: true, choices: [] },
      { kind: "literal", text: "_" },
      { kind: "token", name: "feature", optional: false, choices: [] },
      { kind: "literal", text: "_" },
      { kind: "token", name: "type", optional: false, choices: ["title", "text"] },
    ]);
  });

  it.each(["{feature", "feature}", "plain", "{}", "{feature:}", "{a b}", "{platform}_{platform}"])("rejects %s", (broken) => {
    expect(() => parseTemplate(broken)).toThrow(TemplateError);
    const rules = namingRules({ keyTemplate: broken });
    expect(rules.problems).toHaveLength(1);
    expect(keyNameProblem("anything.goes", rules)).toBeUndefined();
  });

  it("lets a custom pattern win and explains plural suffixes", () => {
    const rules = namingRules({ keyTemplate: "{feature}_{description}", keyPattern: "^[a-z]+(\\.[a-z]+)+$" });
    expect(keyNameProblem("checkout.title", rules)).toBeUndefined();
    expect(keyNameProblem("checkout_title", rules)).toContain("key pattern");
    expect(formatDescription(rules)).toBe("a name matching ^[a-z]+(\\.[a-z]+)+$");
    const plural = keyNameProblem("profile_friendsCount_text.one", namingRules({ keyTemplate: TEMPLATE }));
    expect(plural).toContain("Plural forms are not part of the key name");
    expect(namingRules({ keyPattern: "([" }).problems).toEqual(["The key pattern is not a valid regular expression."]);
  });

  it("suggests names in the template's format", () => {
    const rules = namingRules({ keyTemplate: TEMPLATE });
    expect(suggestKey({ frame: "Home", text: "Welcome back, Alex" }, new Set(), rules)).toBe("home_welcomeBackAlex_text");
    expect(suggestKey({ frame: "League Details", text: "Join league", containers: ["Button / Primary"] }, new Set(), rules)).toBe(
      "leagueDetails_joinLeague_action",
    );
    expect(suggestKey({ frame: "Profile", text: "Your friends", fontSize: 28 }, new Set(), rules)).toBe("profile_yourFriends_title");
    expect(suggestKey({ text: "OK", layerName: "Label" }, new Set(), rules)).toBe("common_ok_text");
    expect(suggestKey({ frame: "Home", text: "Welcome" }, new Set(["home_welcome_text"]), rules)).toBe("home_welcome2_text");
    for (const input of [{ frame: "Checkout — Summary", text: "Pay now" }, { text: "€ 12", layerName: "Price" }, { page: "Ångström", text: "100%" }]) {
      expect(keyNameProblem(suggestKey(input, new Set(), rules), rules)).toBeUndefined();
    }
  });

  it("makes camelCase words that start with a letter", () => {
    expect(camelWord("Welcome back, Alex")).toBe("welcomeBackAlex");
    expect(camelWord("League Details", 1)).toBe("league");
    expect(camelWord("100 points")).toBe("");
  });
});
