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
  /** Font size, a hint that large text is a title. */
  fontSize?: number;
  /** Names of the layers around the text, nearest first: a hint that it sits on a button. */
  containers?: string[];
}

/**
 * Suggests a key that is not in `taken`. With a key template in the project's guidelines the suggestion follows it;
 * otherwise it is `<frame slug>.<text slug>`, with `_2`, `_3`, … added to the last segment when needed.
 */
export function suggestKey(input: SuggestInput, taken: ReadonlySet<string> = new Set(), rules?: NamingRules): string {
  if (rules?.template) return suggestFromTemplate(rules.template.parts, input, taken);
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
export function keyNameProblem(key: string, rules?: NamingRules): string | undefined {
  if (key.trim().length === 0) return "Enter a key name.";
  if (/\s/.test(key)) return "Key names cannot contain spaces. Use dots between parts and _ between words.";
  if (!KEY_PATTERN.test(key)) return "Use letters, digits, _ and -, with single dots between parts.";
  if (key.length > 200) return "Key names can be at most 200 characters.";
  if (!rules?.regex || fullMatch(rules.regex, key)) return undefined;
  const dot = key.lastIndexOf(".");
  if (dot > 0 && PLURAL_CATEGORIES.includes(key.slice(dot + 1)) && fullMatch(rules.regex, key.slice(0, dot))) {
    return `Plural forms are not part of the key name. Create one plural key named ${key.slice(0, dot)} in the Runa app.`;
  }
  return rules.template && !rules.customPattern
    ? `${key} does not follow the key format ${rules.template.source}.`
    : `${key} does not follow the key pattern ${rules.customPattern ?? ""}.`;
}

// MARK: Key templates (same rules as RunaCore's KeyTemplate; shared vectors in docs/SHEET_FORMAT.md)

const PLURAL_CATEGORIES = ["zero", "one", "two", "few", "many", "other"];
export const PLATFORMS = ["ios", "android", "web"];
const WORD_PATTERN = "[a-z][a-zA-Z0-9]*";

export type TemplatePart = { kind: "literal"; text: string } | { kind: "token"; name: string; optional: boolean; choices: string[] };

/** The guidelines the plugin uses; the naming guide itself is for people and agents. */
export interface KeyGuidelines {
  keyTemplate: string;
  keyPattern: string;
}

export interface NamingRules {
  template?: { source: string; parts: TemplatePart[] };
  customPattern?: string;
  regex?: RegExp;
  /** Template or pattern errors; the broken rule is ignored. */
  problems: string[];
}

export class TemplateError extends Error {}

/** Parses `{platform?}_{feature}_{description}_{type:title|text|action}`. Throws TemplateError. */
export function parseTemplate(source: string): TemplatePart[] {
  const text = source.trim();
  const parts: TemplatePart[] = [];
  let literal = "";
  for (let index = 0; index < text.length; index++) {
    const character = text[index]!;
    if (character === "}") throw new TemplateError('The key template has a "}" without a matching "{".');
    if (character !== "{") {
      literal += character;
      continue;
    }
    const close = text.indexOf("}", index);
    if (close < 0) throw new TemplateError('The key template has a "{" without a matching "}".');
    if (literal) parts.push({ kind: "literal", text: literal });
    literal = "";
    parts.push(parseToken(text.slice(index + 1, close)));
    index = close;
  }
  if (literal) parts.push({ kind: "literal", text: literal });
  if (!parts.some((part) => part.kind === "token")) {
    throw new TemplateError("The key template needs at least one part in braces, such as {feature}.");
  }
  if (parts.filter((part) => part.kind === "token" && part.name.toLowerCase() === "platform").length > 1) {
    throw new TemplateError("The key template can name the platform only once.");
  }
  return parts;
}

function parseToken(body: string): TemplatePart {
  let spec = body.trim();
  let choices: string[] = [];
  const colon = spec.indexOf(":");
  if (colon >= 0) {
    choices = spec.slice(colon + 1).split("|").map((choice) => choice.trim());
    spec = spec.slice(0, colon);
    if (choices.length === 0 || !choices.every((choice) => /^[A-Za-z0-9_-]+$/.test(choice))) {
      throw new TemplateError(`List values in {${body}} as letters, digits, "_" or "-", separated by "|".`);
    }
  }
  const optional = spec.endsWith("?");
  if (optional) spec = spec.slice(0, -1);
  if (!/^[A-Za-z][A-Za-z0-9]*$/.test(spec)) throw new TemplateError(`{${body}} is not a valid part name. Use a word such as {feature}.`);
  return { kind: "token", name: spec, optional, choices };
}

function tokenChoices(part: Extract<TemplatePart, { kind: "token" }>): string[] | undefined {
  if (part.choices.length > 0) return part.choices;
  return part.name.toLowerCase() === "platform" ? PLATFORMS : undefined;
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Optional tokens grouped with the literal after them (or, when last, the literal before them). */
function groups(parts: TemplatePart[]): TemplatePart[][] {
  const result: TemplatePart[][] = [];
  for (let index = 0; index < parts.length; index++) {
    const part = parts[index]!;
    if (part.kind === "token" && part.optional) {
      const next = parts[index + 1];
      if (next?.kind === "literal") {
        result.push([part, next]);
        index++;
        continue;
      }
      const last = result[result.length - 1];
      if (index === parts.length - 1 && last?.length === 1 && last[0]!.kind === "literal") {
        result[result.length - 1] = [last[0]!, part];
        continue;
      }
    }
    result.push([part]);
  }
  return result;
}

/** A regular expression matching a whole key name; the platform part is captured as `platform`. */
export function templatePattern(parts: TemplatePart[]): string {
  let pattern = "^";
  for (const group of groups(parts)) {
    const body = group
      .map((part) => {
        if (part.kind === "literal") return escapeRegExp(part.text);
        const values = tokenChoices(part);
        if (!values) return WORD_PATTERN;
        const alternatives = values.map(escapeRegExp).join("|");
        return part.name.toLowerCase() === "platform" ? `(?<platform>${alternatives})` : `(?:${alternatives})`;
      })
      .join("");
    pattern += group.some((part) => part.kind === "token" && part.optional) ? `(?:${body})?` : body;
  }
  return pattern + "$";
}

function fullMatch(regex: RegExp, text: string): boolean {
  const match = regex.exec(text);
  return !!match && match.index === 0 && match[0] === text;
}

/** Naming rules from the project's guidelines. Without a template or pattern, only the basic syntax applies. */
export function namingRules(guidelines?: Partial<KeyGuidelines>): NamingRules {
  const rules: NamingRules = { problems: [] };
  const templateText = (guidelines?.keyTemplate ?? "").trim();
  if (templateText) {
    try {
      const parts = parseTemplate(templateText);
      rules.template = { source: templateText, parts };
      rules.regex = new RegExp(templatePattern(parts));
    } catch (error) {
      rules.problems.push(error instanceof Error ? error.message : String(error));
    }
  }
  const custom = (guidelines?.keyPattern ?? "").trim();
  if (custom) {
    try {
      rules.regex = new RegExp(custom);
      rules.customPattern = custom;
    } catch {
      rules.problems.push("The key pattern is not a valid regular expression.");
    }
  }
  return rules;
}

/** What a key should look like, for hints. */
export function formatDescription(rules: NamingRules): string | undefined {
  if (rules.customPattern) return `a name matching ${rules.customPattern}`;
  return rules.template?.source;
}

/** The platform a name starts with (`ios` in `ios_checkout_pay_action`), when the template has a platform part. */
export function platformIn(key: string, rules?: NamingRules): string | undefined {
  if (!rules?.template) return undefined;
  const match = new RegExp(templatePattern(rules.template.parts)).exec(key);
  if (!match || match.index !== 0 || match[0] !== key) return undefined;
  return match.groups?.["platform"]?.toLowerCase();
}

type Role = "action" | "title" | "text";
const ROLE_WORDS: Record<Role, string[]> = {
  action: ["action", "button", "cta", "link"],
  title: ["title", "heading", "header", "headline"],
  text: ["text", "label", "body", "copy", "description", "message"],
};
const FEATURE_TOKENS = ["feature", "screen", "page", "area", "section", "module", "flow"];

/** A guess at what the text is for, from the layers around it and its size. */
function roleOf(input: SuggestInput): Role {
  const names = [input.layerName ?? "", ...(input.containers ?? [])].join(" ").toLowerCase();
  if (/button|btn|\bcta\b|\blink\b/.test(names)) return "action";
  if ((input.fontSize ?? 0) >= 20 || /title|heading|header|headline|\bh[12]\b/.test(names)) return "title";
  return "text";
}

/** lowerCamelCase of the first `max` words, or "" when there are none or it would start with a digit. */
export function camelWord(text: string, max = Number.POSITIVE_INFINITY): string {
  const list = words(text).slice(0, max);
  const word = list.map((part, index) => (index === 0 ? part : part[0]!.toUpperCase() + part.slice(1))).join("");
  return /^[a-z]/.test(word) ? word.slice(0, MAX_SEGMENT_LENGTH) : "";
}

function suggestFromTemplate(parts: TemplatePart[], input: SuggestInput, taken: ReadonlySet<string>): string {
  const role = roleOf(input);
  const feature = camelWord(input.frame ?? "", 2) || camelWord(input.page ?? "", 2) || "common";
  const description = camelWord(input.text, MAX_TEXT_WORDS) || camelWord(input.layerName ?? "", MAX_TEXT_WORDS) || "text";
  const render = (suffix: string) =>
    groups(parts)
      .map((group) => {
        if (group.some((part) => part.kind === "token" && part.optional)) return ""; // leave optional parts out
        return group
          .map((part) => {
            if (part.kind === "literal") return part.text;
            const values = tokenChoices(part);
            if (values) return values.find((value) => ROLE_WORDS[role].includes(value.toLowerCase())) ?? values.find((value) => ROLE_WORDS.text.includes(value.toLowerCase())) ?? values[0]!;
            return FEATURE_TOKENS.includes(part.name.toLowerCase()) ? feature : description + suffix;
          })
          .join("");
      })
      .join("");
  const base = render("");
  if (!taken.has(base)) return base;
  for (let n = 2; ; n++) {
    const candidate = render(String(n));
    if (!taken.has(candidate)) return candidate;
  }
}
