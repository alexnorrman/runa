import { normalizeLineBreaks } from "../shared/text";

/** Link state of a text layer, shown as a status dot. */
export type LinkState = "unlinked" | "linked" | "drift" | "missing" | "unknown";

const PLACEHOLDER_SOURCE = "\\{[A-Za-z_][A-Za-z0-9_]*(?::[A-Za-z]+(?:\\.\\d+)?)?\\}";
const HAS_PLACEHOLDER = new RegExp(PLACEHOLDER_SOURCE);
const PLACEHOLDERS = new RegExp(PLACEHOLDER_SOURCE, "g");

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Whether the text in Figma matches a source text. Runa placeholders (`{name}`, `{count:int}`,
 * `{price:double.2}`) match any sample value the designer typed, so "3 items" matches
 * "{count:int} items" and is not drift.
 */
export function textMatches(figmaText: string, source: string): boolean {
  const figma = normalizeLineBreaks(figmaText);
  const sheet = normalizeLineBreaks(source);
  if (figma === sheet) return true;
  if (!HAS_PLACEHOLDER.test(sheet)) return false;
  const pattern = sheet
    .split(PLACEHOLDERS)
    .map(escapeRegExp)
    .join("[\\s\\S]+?");
  return new RegExp(`^${pattern}$`).test(figma);
}

export interface LinkInfo {
  /** Key name stored on the layer. */
  key?: string;
  /** Key id stored on the layer. */
  keyId?: string;
}

export interface KeyLike {
  id: string;
  key: string;
  /** Non-empty source forms. */
  forms: string[];
}

/**
 * The state of one layer. `findKey` looks a key up by id first, then by name (a layer linked
 * before the sheet had ids, or a key whose row was re-created).
 */
export function linkState(figmaText: string, link: LinkInfo, findKey: (link: LinkInfo) => KeyLike | undefined, loaded: boolean): LinkState {
  if (!link.key && !link.keyId) return "unlinked";
  if (!loaded) return "unknown";
  const key = findKey(link);
  if (!key) return "missing";
  if (key.forms.length === 0) return "drift";
  return key.forms.some((form) => textMatches(figmaText, form)) ? "linked" : "drift";
}
