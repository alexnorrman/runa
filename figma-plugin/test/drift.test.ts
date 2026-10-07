import { describe, expect, it } from "vitest";
import { linkState, textMatches, type KeyLike } from "../src/core/drift";

describe("textMatches", () => {
  it("compares text exactly, treating Figma's soft line breaks as newlines", () => {
    expect(textMatches("Pay now", "Pay now")).toBe(true);
    expect(textMatches("Pay now ", "Pay now")).toBe(false);
    expect(textMatches("Line one Line two", "Line one\nLine two")).toBe(true);
  });
  it("lets placeholders match sample values", () => {
    expect(textMatches("3 items", "{count:int} items")).toBe(true);
    expect(textMatches("Hi Alex, you have 2 new messages", "Hi {name}, you have {count:int} new messages")).toBe(true);
    expect(textMatches("$9.99", "${price:double.2}")).toBe(true);
    expect(textMatches("3 things", "{count:int} items")).toBe(false);
    expect(textMatches(" items", "{count:int} items")).toBe(false);
  });
  it("escapes regex characters in the source", () => {
    expect(textMatches("a.c (x)", "a.c (x)")).toBe(true);
    expect(textMatches("abc (x)", "a.c (x)")).toBe(false);
  });
});

describe("linkState", () => {
  const key: KeyLike = { id: "1", key: "checkout.pay_now", forms: ["Pay now"] };
  const find = (link: { key?: string; keyId?: string }) => (link.keyId === "1" || link.key === "checkout.pay_now" ? key : undefined);
  it("covers every state", () => {
    expect(linkState("Pay now", {}, find, true)).toBe("unlinked");
    expect(linkState("Pay now", { keyId: "1", key: "checkout.pay_now" }, find, false)).toBe("unknown");
    expect(linkState("Pay now", { keyId: "1" }, find, true)).toBe("linked");
    expect(linkState("Pay later", { keyId: "1" }, find, true)).toBe("drift");
    expect(linkState("Pay now", { keyId: "2", key: "gone" }, find, true)).toBe("missing");
  });
  it("finds a key by name when the id is unknown", () => {
    expect(linkState("Pay now", { key: "checkout.pay_now" }, find, true)).toBe("linked");
  });
  it("accepts any plural form", () => {
    const plural: KeyLike = { id: "p", key: "cart.items", forms: ["{count:int} item", "{count:int} items"] };
    expect(linkState("1 item", { keyId: "p" }, () => plural, true)).toBe("linked");
    expect(linkState("4 items", { keyId: "p" }, () => plural, true)).toBe("linked");
  });
});
