import { asciiFold } from "../shared/text";

/**
 * Key naming: dot notation with snake_case segments, ASCII only.
 * `<frame slug>.<text slug>`: frame "Checkout — Summary" + text "Pay now" → `checkout_summary.pay_now`.
 */

const MAX_TEXT_WORDS = 4;
const MAX_SEGMENT_LENGTH = 40;

/** Lowercase ASCII words of a text. */
export function words(text: string): string[] {
  return asciiFold(text)
    .toLowerCase()
    .replace(/'/g, "")
    .split(/[^a-z0-9]+/)
    .filter((word) => word.length > 0);
}

/** One snake_case key segment, at most `maxWords` words. Empty when there are no usable words. */
export function slugSegment(text: string, maxWords = Number.POSITIVE_INFINITY): string {
  const segment = words(text).slice(0, maxWords).join("_");
  if (segment.length <= MAX_SEGMENT_LENGTH) return segment;
  return segment.slice(0, MAX_SEGMENT_LENGTH).replace(/_[^_]*$/, "") || segment.slice(0, MAX_SEGMENT_LENGTH);
}

export interface SuggestInput {
  /** Top-level frame the text sits in, if any. */
  frame?: string;
  /** Page name, used when the text is not inside a frame. */
  page?: string;
  /** The text layer's characters. */
  text: string;
  /** Layer name, used when the text has no words (for example "€ 12"). */
  layerName?: string;
}

/**
 * Suggests a key that is not in `taken`. Adds `_2`, `_3`, … to the last segment when needed.
 */
export function suggestKey(input: SuggestInput, taken: ReadonlySet<string> = new Set()): string {
  const prefix = slugSegment(input.frame ?? "") || slugSegment(input.page ?? "");
  const last = slugSegment(input.text, MAX_TEXT_WORDS) || slugSegment(input.layerName ?? "", MAX_TEXT_WORDS) || "text";
  const base = prefix ? `${prefix}.${last}` : last;
  if (!taken.has(base)) return base;
  for (let n = 2; ; n++) {
    const candidate = `${base}_${n}`;
    if (!taken.has(candidate)) return candidate;
  }
}

const KEY_PATTERN = /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$/;

/** Undefined when the key name is fine, otherwise a sentence explaining what is wrong. */
export function keyNameProblem(key: string): string | undefined {
  if (key.trim().length === 0) return "Enter a key name.";
  if (/\s/.test(key)) return "Key names cannot contain spaces. Use dots between parts and _ between words.";
  if (!KEY_PATTERN.test(key)) return "Use letters, digits, _ and -, with single dots between parts.";
  if (key.length > 200) return "Key names can be at most 200 characters.";
  return undefined;
}
