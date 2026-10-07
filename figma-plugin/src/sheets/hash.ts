import { sha256, toHex } from "./sha256";

/** CLDR plural categories in the order the hash uses. */
export const PLURAL_CATEGORIES = ["zero", "one", "two", "few", "many", "other"] as const;
export type PluralCategory = (typeof PLURAL_CATEGORIES)[number];
export type Forms = Partial<Record<PluralCategory, string>>;

export function isPluralCategory(value: string): value is PluralCategory {
  return (PLURAL_CATEGORIES as readonly string[]).includes(value);
}

/**
 * The text hash from docs/SHEET_FORMAT.md: non-empty forms in CLDR order, each written as
 * `<category> U+001F <text>`, joined with U+001E, SHA-256 of the UTF-8 bytes, first 12 hex chars.
 * A plain key is the single form `other`.
 */
export function textHash(forms: Forms): string {
  const parts: string[] = [];
  for (const category of PLURAL_CATEGORIES) {
    const value = forms[category];
    if (value) parts.push(`${category}\u001f${value}`);
  }
  return toHex(sha256(parts.join("\u001e"))).slice(0, 12);
}

/**
 * The id a `strings` row gets when its `_id` cell is blank: the first 16 bytes of
 * SHA-256("runa:key:" + key) with version 5 and RFC 4122 variant bits, lowercase 8-4-4-4-12.
 */
export function derivedId(key: string): string {
  const bytes = sha256(`runa:key:${key}`).slice(0, 16);
  bytes[6] = (bytes[6]! & 0x0f) | 0x50;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  return formatUuid(bytes);
}

export function formatUuid(bytes: Uint8Array): string {
  const hex = toHex(bytes);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Returns the lowercase UUID if `text` is one (any case), otherwise undefined. */
export function parseUuid(text: string): string | undefined {
  const trimmed = text.trim();
  return UUID_PATTERN.test(trimmed) ? trimmed.toLowerCase() : undefined;
}

/** A random lowercase UUID v4. Uses `crypto.getRandomValues` (present in every Figma UI iframe). */
export function randomUuid(random: (bytes: Uint8Array) => Uint8Array = defaultRandom): string {
  const bytes = random(new Uint8Array(16));
  bytes[6] = (bytes[6]! & 0x0f) | 0x40;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  return formatUuid(bytes);
}

function defaultRandom(bytes: Uint8Array): Uint8Array {
  return globalThis.crypto.getRandomValues(bytes);
}
