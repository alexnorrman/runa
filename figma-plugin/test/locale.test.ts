import { describe, expect, it } from "vitest";
import { parseStringsColumns } from "../src/sheets/layout";
import { localeFromHeader, normalizeLocale } from "../src/sheets/locale";

describe("normalizeLocale", () => {
  it("normalises case and separators like RunaCore", () => {
    expect(normalizeLocale("pt_br")).toBe("pt-BR");
    expect(normalizeLocale("PT-BR")).toBe("pt-BR");
    expect(normalizeLocale("zh-hans")).toBe("zh-Hans");
    expect(normalizeLocale("ZH_HANT_tw")).toBe("zh-Hant-TW");
    expect(normalizeLocale("es-419")).toBe("es-419");
    expect(normalizeLocale(" sv ")).toBe("sv");
  });
  it("rejects things that are not tag shaped", () => {
    expect(normalizeLocale("english")).toBeUndefined();
    expect(normalizeLocale("e")).toBeUndefined();
    expect(normalizeLocale("en--US")).toBeUndefined();
    expect(normalizeLocale("en US")).toBeUndefined();
    expect(normalizeLocale("1a")).toBeUndefined();
  });
});

describe("locale headers", () => {
  it("accepts real languages", () => {
    for (const header of ["en", "sv", "pt-BR", "zh-Hans", "fil", "nb", "de_CH"]) {
      expect(localeFromHeader(header), header).toBeDefined();
    }
    expect(localeFromHeader("de_CH")).toBe("de-CH");
  });
  it("rejects unknown language subtags and plain words", () => {
    for (const header of ["xx", "qq-BR", "notes", "status", "owner", "zz"]) {
      expect(localeFromHeader(header), header).toBeUndefined();
    }
  });
  it("lets reserved column names win over locale detection", () => {
    // "context" and "comment" are description aliases, "key" is the key column.
    const columns = parseStringsColumns(["key", "Context", "en", "SV", "Notes", "Figma", "Tags", "platforms", "id"]);
    expect(columns.key).toBe(0);
    expect(columns.description).toBe(1);
    expect(columns.figma).toBe(5);
    expect(columns.tags).toBe(6);
    expect(columns.platforms).toBe(7);
    // "id" is Indonesian and not reserved (only "_id" is), same as RunaCore.
    expect(columns.locales).toEqual([
      { locale: "en", index: 2 },
      { locale: "sv", index: 3 },
      { locale: "id", index: 8 },
    ]);
  });
  it("keeps the first column of a duplicated locale", () => {
    const columns = parseStringsColumns(["key", "en", "EN"]);
    expect(columns.locales).toEqual([{ locale: "en", index: 1 }]);
  });
});
