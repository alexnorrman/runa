/**
 * Locale column detection, the TypeScript twin of `LocaleCode` in RunaCore.
 *
 * A header is a locale when it normalises as a BCP 47 tag (language of 2–3 ASCII letters,
 * script title case, region upper case, `_` accepted as separator) and its language subtag is a
 * real ISO 639 language, which we ask `Intl.DisplayNames` about: it returns a name that differs
 * from the code only for languages it knows.
 */

/** `pt_br` → `pt-BR`, `ZH-hans` → `zh-Hans`. Returns undefined if it is not tag shaped. */
export function normalizeLocale(input: string): string | undefined {
  const parts = input.trim().replace(/_/g, "-").split("-");
  const first = parts[0] ?? "";
  if (!/^[A-Za-z]{2,3}$/.test(first)) return undefined;
  const output = [first.toLowerCase()];
  for (const part of parts.slice(1)) {
    if (!/^[A-Za-z0-9]{1,8}$/.test(part)) return undefined;
    if (/^[A-Za-z]{4}$/.test(part)) {
      output.push(part.charAt(0).toUpperCase() + part.slice(1).toLowerCase());
    } else if (/^[A-Za-z]{2}$/.test(part) || /^[0-9]{3}$/.test(part)) {
      output.push(part.toUpperCase());
    } else {
      output.push(part.toLowerCase());
    }
  }
  return output.join("-");
}

let displayNames: Intl.DisplayNames | null | undefined;
const knownCache = new Map<string, boolean>();

/** Whether a 2–3 letter language subtag is a real language (`en`, `sv`, `fil`), per ICU. */
export function isKnownLanguage(language: string): boolean {
  const code = language.toLowerCase();
  const cached = knownCache.get(code);
  if (cached !== undefined) return cached;
  let known = false;
  try {
    if (displayNames === undefined) {
      displayNames = typeof Intl !== "undefined" && "DisplayNames" in Intl ? new Intl.DisplayNames(["en"], { type: "language" }) : null;
    }
    if (displayNames) {
      const name = displayNames.of(code);
      known = !!name && name.toLowerCase() !== code;
    } else {
      // No Intl.DisplayNames: accept any well-formed language subtag.
      known = /^[a-z]{2,3}$/.test(code);
    }
  } catch {
    known = false;
  }
  knownCache.set(code, known);
  return known;
}

/** The normalised locale for a header cell, or undefined when the header is not a locale. */
export function localeFromHeader(header: string): string | undefined {
  const normalized = normalizeLocale(header);
  if (!normalized) return undefined;
  const language = normalized.split("-")[0]!;
  return isKnownLanguage(language) ? normalized : undefined;
}

/** "English", "Brazilian Portuguese", or the code itself when unknown. */
export function localeDisplayName(code: string): string {
  try {
    return new Intl.DisplayNames(["en"], { type: "language" }).of(code) ?? code;
  } catch {
    return code;
  }
}
