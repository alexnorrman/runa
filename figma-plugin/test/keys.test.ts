import { describe, expect, it } from "vitest";
import { keyNameProblem, slugSegment, suggestKey, words } from "../src/core/keys";
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
