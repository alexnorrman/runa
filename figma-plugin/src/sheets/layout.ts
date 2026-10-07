import { derivedId, isPluralCategory, parseUuid, type Forms, type PluralCategory } from "./hash";
import { localeFromHeader, normalizeLocale } from "./locale";
import { parseFigmaUrl } from "../shared/figma-url";
import {
  CONTEXT_TAB, DESCRIPTION_ALIASES, HISTORY_TAB, HIDDEN_TABS, META_TAB, SheetError, STRINGS_TAB,
  type Grid, type Grids, type SpreadsheetInfo,
} from "./types";

/** Where each known column of the `strings` tab sits (0-based). */
export interface StringsColumns {
  id?: number;
  key: number;
  description?: number;
  plural?: number;
  figma?: number;
  tags?: number;
  platforms?: number;
  locales: { locale: string; index: number }[];
  width: number;
}

export interface StringsRow {
  /** 0-based row index in the tab (the header is row 0). */
  index: number;
  id: string;
  hasStoredId: boolean;
  /** Undefined for a blank (or unknown) `plural` cell. */
  category?: PluralCategory;
  cells: string[];
}

/** A Figma link of a key, from `_context` (columns by name) or only from the `figma` column. */
export interface ContextRecord {
  url: string;
  fileKey: string;
  nodeId: string;
  /** Top-level frame node id; "" when unknown (older rows or links only in the `figma` column). */
  frameId: string;
  page: string;
  frame: string;
  path: string;
  linkedAt: string;
  linkedBy: string;
}

export interface KeyEntry {
  id: string;
  key: string;
  description: string;
  isPlural: boolean;
  /** Rows of this key in sheet order. The first one carries the figma links the plugin writes. */
  rows: StringsRow[];
  /** Source-locale text per plural form (a plain key only has `other`). */
  source: Forms;
  /** Figma links: `_context` rows first, then links found only in the `figma` column. */
  figmaUrls: string[];
  contexts: ContextRecord[];
  tags: string[];
}

export interface SheetModel {
  spreadsheetTitle: string;
  projectName: string;
  sourceLocale: string;
  locales: string[];
  columns: StringsColumns;
  rows: StringsRow[];
  keys: KeyEntry[];
  byId: Map<string, KeyEntry>;
  byName: Map<string, KeyEntry>;
  info: SpreadsheetInfo;
  grids: Grids;
  /** Hidden tabs that do not exist. */
  missingTabs: string[];
  /** What the Runa Mac app must set up before the plugin may write. Empty when writing is safe. */
  setupIssues: string[];
  warnings: string[];
}

export function cell(row: readonly string[] | undefined, index: number | undefined): string {
  if (!row || index === undefined || index >= row.length) return "";
  return row[index] ?? "";
}

/** Comma or newline separated values, trimmed, empties dropped (same as RunaCore). */
export function splitList(text: string): string[] {
  return text
    .split(/[,\n]/)
    .map((part) => part.trim())
    .filter((part) => part.length > 0);
}

/** First index of each header name, matched exactly (hidden tabs use fixed names). */
export function headerIndexes(header: readonly string[]): Map<string, number> {
  const indexes = new Map<string, number>();
  header.forEach((name, index) => {
    if (!indexes.has(name)) indexes.set(name, index);
  });
  return indexes;
}

export function parseStringsColumns(header: readonly string[]): StringsColumns {
  let key: number | undefined;
  const columns: Omit<StringsColumns, "key"> = { locales: [], width: header.length };
  header.forEach((raw, index) => {
    const name = raw.trim();
    const lower = name.toLowerCase();
    if (lower === "_id") columns.id ??= index;
    else if (lower === "key") key ??= index;
    else if (DESCRIPTION_ALIASES.includes(lower)) columns.description ??= index;
    else if (lower === "plural") columns.plural ??= index;
    else if (lower === "figma") columns.figma ??= index;
    else if (lower === "tags") columns.tags ??= index;
    else if (lower === "platforms") columns.platforms ??= index;
    else {
      const locale = localeFromHeader(name);
      if (locale && !columns.locales.some((entry) => entry.locale === locale)) columns.locales.push({ locale, index });
    }
  });
  if (key === undefined) {
    throw new SheetError(`The "${STRINGS_TAB}" tab needs a "key" column in its first row.`, "no-key-column");
  }
  return { ...columns, key };
}

/** Reads the tabs into a model. Throws a SheetError when there is no usable `strings` tab. */
export function parseSheet(info: SpreadsheetInfo, grids: Grids): SheetModel {
  const strings = grids[STRINGS_TAB];
  if (!info.tabs.some((tab) => tab.title === STRINGS_TAB) || !strings) {
    throw new SheetError(`The spreadsheet has no "${STRINGS_TAB}" tab yet. Set it up from the Runa Mac app first.`, "no-strings-tab");
  }
  const columns = parseStringsColumns(strings[0] ?? []);
  const warnings: string[] = [];

  // _meta
  const meta = new Map<string, string>();
  for (const row of (grids[META_TAB] ?? []).slice(1)) {
    if (row.length >= 2) meta.set(row[0]!, row[1]!);
  }
  const headerLocales = columns.locales.map((entry) => entry.locale);
  const declared = meta.get("sourceLocale");
  let sourceLocale = declared ? normalizeLocale(declared) : undefined;
  sourceLocale ??= headerLocales[0];
  if (sourceLocale && !headerLocales.includes(sourceLocale)) {
    warnings.push(`The source language ${sourceLocale} has no column; using ${headerLocales[0] ?? "none"}.`);
    sourceLocale = headerLocales[0];
  }
  if (!sourceLocale) {
    throw new SheetError(
      `The "${STRINGS_TAB}" tab has no language columns. Add a column named with a language code such as "en".`,
      "no-locale",
    );
  }
  const sourceIndex = columns.locales.find((entry) => entry.locale === sourceLocale)!.index;

  // strings rows, grouped by id in sheet order
  const rows: StringsRow[] = [];
  const groups = new Map<string, StringsRow[]>();
  strings.forEach((cells, index) => {
    if (index === 0) return;
    const key = cell(cells, columns.key).trim();
    if (!key) return;
    const storedId = parseUuid(cell(cells, columns.id));
    const id = storedId ?? derivedId(key);
    const pluralText = cell(cells, columns.plural).trim().toLowerCase();
    let category: PluralCategory | undefined;
    if (pluralText) {
      if (isPluralCategory(pluralText)) category = pluralText;
      else warnings.push(`Unknown plural form "${pluralText}" on row ${index + 1}.`);
    }
    const row: StringsRow = { index, id, hasStoredId: storedId !== undefined, cells };
    if (category) row.category = category;
    rows.push(row);
    const group = groups.get(id);
    if (group) group.push(row);
    else groups.set(id, [row]);
  });

  // _context rows per id, columns by name (so rows without newer columns such as frameId still read)
  const contextsById = new Map<string, ContextRecord[]>();
  const contextGrid = grids[CONTEXT_TAB] ?? [];
  const contextColumns = headerIndexes(contextGrid[0] ?? []);
  const field = (row: string[], name: string) => cell(row, contextColumns.get(name));
  for (const row of contextGrid.slice(1)) {
    const id = parseUuid(field(row, "id"));
    const url = field(row, "url");
    if (!id || !url) continue;
    const list = contextsById.get(id) ?? [];
    if (list.some((context) => context.url === url)) continue;
    const parsed = parseFigmaUrl(url);
    list.push({
      url,
      fileKey: field(row, "fileKey") || parsed?.fileKey || "",
      nodeId: field(row, "nodeId") || parsed?.nodeId || "",
      frameId: field(row, "frameId"),
      page: field(row, "page"),
      frame: field(row, "frame"),
      path: field(row, "path"),
      linkedAt: field(row, "linkedAt"),
      linkedBy: field(row, "linkedBy"),
    });
    contextsById.set(id, list);
  }

  const keys: KeyEntry[] = [];
  const byId = new Map<string, KeyEntry>();
  const byName = new Map<string, KeyEntry>();
  for (const [id, group] of groups) {
    const first = group[0]!;
    const firstNonEmpty = (column: number | undefined) => group.map((row) => cell(row.cells, column)).find((text) => text !== "") ?? "";
    const name = cell(first.cells, columns.key).trim();
    const isPlural = group.some((row) => row.category !== undefined);
    const source: Forms = {};
    const seen = new Set<PluralCategory>();
    for (const row of group) {
      const category = row.category ?? "other";
      if (seen.has(category)) continue;
      seen.add(category);
      const text = cell(row.cells, sourceIndex);
      if (text) source[category] = text;
    }
    const contexts = [...(contextsById.get(id) ?? [])];
    for (const row of group) {
      for (const url of splitList(cell(row.cells, columns.figma))) {
        const parsed = parseFigmaUrl(url);
        if (contexts.some((context) => context.url === url) || !parsed?.nodeId) continue;
        contexts.push({ url, fileKey: parsed.fileKey, nodeId: parsed.nodeId, frameId: "", page: "", frame: "", path: "", linkedAt: "", linkedBy: "" });
      }
    }
    const figmaUrls = contexts.map((context) => context.url);
    const entry: KeyEntry = {
      id,
      key: name,
      description: firstNonEmpty(columns.description),
      isPlural,
      rows: group,
      source,
      figmaUrls,
      contexts,
      tags: splitList(firstNonEmpty(columns.tags)),
    };
    if (byName.has(name)) warnings.push(`"${name}" appears more than once (row ${first.index + 1}).`);
    else byName.set(name, entry);
    byId.set(id, entry);
    keys.push(entry);
  }

  const missingTabs = HIDDEN_TABS.filter((tab) => !info.tabs.some((candidate) => candidate.title === tab));
  const setupIssues: string[] = [];
  for (const tab of [CONTEXT_TAB, HISTORY_TAB]) {
    if (missingTabs.includes(tab as (typeof HIDDEN_TABS)[number])) setupIssues.push(`the ${tab} tab`);
  }
  if (columns.id === undefined) setupIssues.push("the _id column");
  if (columns.figma === undefined) setupIssues.push("the figma column");

  const projectName = meta.get("projectName") || info.title;
  return {
    spreadsheetTitle: info.title,
    projectName,
    sourceLocale,
    locales: headerLocales,
    columns,
    rows,
    keys,
    byId,
    byName,
    info,
    grids,
    missingTabs,
    setupIssues,
    warnings,
  };
}

/** The plain text of a key in the source locale: `other`, or the first non-empty form. */
export function sourceText(entry: KeyEntry): string {
  return entry.source.other ?? Object.values(entry.source).find((text) => !!text) ?? "";
}

/** Tabs to fetch for a full read: every Runa tab that exists, in a fixed order. */
export function tabsToRead(info: SpreadsheetInfo, wanted: readonly string[]): string[] {
  return wanted.filter((tab) => info.tabs.some((candidate) => candidate.title === tab));
}

/** The grid of a tab, or an empty one. */
export function gridOf(grids: Grids, tab: string): Grid {
  return grids[tab] ?? [];
}
