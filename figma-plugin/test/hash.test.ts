import { createHash, randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { derivedId, parseUuid, randomUuid, textHash } from "../src/sheets/hash";
import { sha256, toHex } from "../src/sheets/sha256";

describe("cross-language test vectors (docs/SHEET_FORMAT.md)", () => {
  it("hashes a plain key", () => {
    expect(textHash({ other: "Hello" })).toBe("a8a7157e2918");
  });
  it("hashes plural forms in CLDR order", () => {
    expect(textHash({ one: "{count:int} item", other: "{count:int} items" })).toBe("28e56bf13e39");
    expect(textHash({ other: "{count:int} items", one: "{count:int} item" })).toBe("28e56bf13e39");
  });
  it("hashes UTF-8 text with an emoji", () => {
    expect(textHash({ other: "Hej då 👋" })).toBe("48a4dc59c479");
  });
  it("derives ids from key names", () => {
    expect(derivedId("checkout.title")).toBe("d286c840-69d2-5786-b77b-30b06363380d");
    expect(derivedId("cart.items")).toBe("31962844-99e1-5361-85d8-42d00b9b2191");
  });
  it("skips empty forms", () => {
    expect(textHash({ zero: "", other: "Hello" })).toBe("a8a7157e2918");
  });
});

describe("sha256", () => {
  it("matches node:crypto for many lengths, including block boundaries", () => {
    for (const length of [0, 1, 3, 55, 56, 57, 63, 64, 65, 119, 120, 128, 1000, 4097]) {
      const data = new Uint8Array(randomBytes(length));
      expect(toHex(sha256(data))).toBe(createHash("sha256").update(data).digest("hex"));
    }
  });
  it("hashes strings as UTF-8", () => {
    expect(toHex(sha256("Hej då 👋"))).toBe(createHash("sha256").update("Hej då 👋", "utf8").digest("hex"));
  });
});

describe("uuids", () => {
  it("makes random lowercase v4 uuids", () => {
    const id = randomUuid();
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(randomUuid()).not.toBe(id);
  });
  it("parses uuids in any case and rejects other text", () => {
    expect(parseUuid(" D286C840-69D2-5786-B77B-30B06363380D ")).toBe("d286c840-69d2-5786-b77b-30b06363380d");
    expect(parseUuid("not-a-uuid")).toBeUndefined();
    expect(parseUuid("")).toBeUndefined();
  });
});
