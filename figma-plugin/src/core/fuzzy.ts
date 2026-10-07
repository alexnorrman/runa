import { asciiFold } from "../shared/text";

/**
 * Fuzzy search over keys: every query token must match the key name or the source text as a
 * subsequence. Substring matches, word starts and consecutive runs score higher. Key name matches
 * weigh more than text matches.
 */

export interface SearchItem {
  key: string;
  text: string;
}

export interface SearchResult<T extends SearchItem> {
  item: T;
  score: number;
}

function fold(text: string): string {
  return asciiFold(text).toLowerCase();
}

const BOUNDARY = /[\s._\-/:,()[\]{}]/;

/** Score of one token against one field, or 0 when it does not match. */
export function tokenScore(token: string, field: string): number {
  if (!token) return 0;
  const substring = field.indexOf(token);
  if (substring >= 0) {
    let score = 100 + token.length * 4;
    if (substring === 0) score += 40;
    else if (BOUNDARY.test(field[substring - 1]!)) score += 25;
    if (field.length === token.length) score += 60;
    return score;
  }
  // Subsequence match with bonuses for consecutive characters and word starts.
  let score = 0;
  let fieldIndex = 0;
  let previous = -2;
  for (const char of token) {
    const found = field.indexOf(char, fieldIndex);
    if (found < 0) return 0;
    score += 1;
    if (found === previous + 1) score += 5;
    if (found === 0 || BOUNDARY.test(field[found - 1]!)) score += 8;
    score -= Math.min(found - fieldIndex, 10) * 0.5;
    previous = found;
    fieldIndex = found + 1;
  }
  return Math.max(score, 1);
}

/** Score of a whole query against one field (sum over tokens), 0 if any token fails. */
export function fieldScore(tokens: string[], field: string): number {
  let total = 0;
  for (const token of tokens) {
    const score = tokenScore(token, field);
    if (score === 0) return 0;
    total += score;
  }
  return total;
}

export function search<T extends SearchItem>(items: readonly T[], query: string, limit = 8): SearchResult<T>[] {
  const tokens = fold(query).split(/\s+/).filter((token) => token.length > 0);
  if (tokens.length === 0) return [];
  const results: SearchResult<T>[] = [];
  for (const item of items) {
    const keyScore = fieldScore(tokens, fold(item.key));
    const textScore = fieldScore(tokens, fold(item.text)) * 0.8;
    // A query like "checkout pay" may match across the key and the text.
    const combined = keyScore || textScore ? 0 : fieldScore(tokens, `${fold(item.key)} ${fold(item.text)}`) * 0.6;
    const score = Math.max(keyScore, textScore, combined);
    if (score > 0) results.push({ item, score });
  }
  results.sort((a, b) => b.score - a.score || a.item.key.length - b.item.key.length || a.item.key.localeCompare(b.item.key));
  return results.slice(0, limit);
}
