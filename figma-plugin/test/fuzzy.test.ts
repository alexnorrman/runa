import { describe, expect, it } from "vitest";
import { search, tokenScore } from "../src/core/fuzzy";

const items = [
  { key: "checkout.title", text: "Checkout" },
  { key: "checkout.pay_now", text: "Pay now" },
  { key: "checkout.summary.total", text: "Total" },
  { key: "cart.items", text: "{count:int} items" },
  { key: "profile.payment_methods", text: "Payment methods" },
  { key: "settings.privacy", text: "Privacy" },
  { key: "home.welcome", text: "Welcome back" },
];

describe("fuzzy search", () => {
  it("returns nothing for an empty query", () => {
    expect(search(items, "  ")).toEqual([]);
  });
  it("ranks exact and prefix matches first", () => {
    expect(search(items, "checkout.title")[0]!.item.key).toBe("checkout.title");
    expect(search(items, "cart")[0]!.item.key).toBe("cart.items");
  });
  it("matches subsequences across word boundaries", () => {
    const keys = search(items, "chkpay").map((result) => result.item.key);
    expect(keys[0]).toBe("checkout.pay_now");
  });
  it("matches source text, and multi-word queries in any field", () => {
    expect(search(items, "welcome back")[0]!.item.key).toBe("home.welcome");
    expect(search(items, "pay now")[0]!.item.key).toBe("checkout.pay_now");
    expect(search(items, "checkout total")[0]!.item.key).toBe("checkout.summary.total");
  });
  it("prefers key matches over text-only matches", () => {
    const keys = search(items, "pay").map((result) => result.item.key);
    expect(keys.slice(0, 2)).toEqual(["checkout.pay_now", "profile.payment_methods"]);
  });
  it("is accent-insensitive and caps results", () => {
    expect(search([{ key: "a.cafe", text: "Café" }], "CAFÉ")[0]!.item.key).toBe("a.cafe");
    const many = Array.from({ length: 20 }, (_, index) => ({ key: `list.item_${index}`, text: "Item" }));
    expect(search(many, "item")).toHaveLength(8);
  });
  it("excludes items that do not contain the query characters in order", () => {
    expect(search(items, "zzz")).toEqual([]);
    expect(tokenScore("tac", "cat")).toBe(0);
  });
});
