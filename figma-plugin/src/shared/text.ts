/** Small text helpers shared by the main thread and the UI. No DOM, no Figma APIs. */

const SPECIAL_LETTERS: Record<string, string> = {
  "ß": "ss", "ẞ": "SS", "æ": "ae", "Æ": "AE", "ø": "o", "Ø": "O", "œ": "oe", "Œ": "OE", "ł": "l", "Ł": "L",
  "đ": "d", "Đ": "D", "ð": "d", "Ð": "D", "þ": "th", "Þ": "TH", "ı": "i", "ŋ": "ng", "Ŋ": "NG", "ħ": "h", "Ħ": "H",
};

/** Folds text to ASCII where there is an obvious equivalent: "Hej då, Ærø" → "Hej da, AEro". */
export function asciiFold(text: string): string {
  return text
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .replace(/[^\x00-\x7f]/g, (char) => SPECIAL_LETTERS[char] ?? char);
}

/** Figma uses U+2028 for soft line breaks; the sheet uses "\n". */
export function normalizeLineBreaks(text: string): string {
  return text.replace(/\r\n?|[\p{Zl}\p{Zp}]/gu, "\n");
}
