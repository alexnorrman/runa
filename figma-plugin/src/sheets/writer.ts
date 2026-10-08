/**
 * Pure functions that turn one plugin action into the request list of ONE
 * `spreadsheets.batchUpdate` call, following the writing rules in docs/SHEET_FORMAT.md:
 * the model passed in must come from a fresh read made right before writing, row indexes are
 * resolved from it, only rows of the touched key change, and every change gets a `_history` row.
 * Values are written with `stringValue`, so text starting with `=` stays text.
 */
import { keyNameProblem, platformIn } from "../core/keys";
import { textHash, type Forms, type PluralCategory } from "./hash";
import { cell, headerIndexes, splitList, type KeyEntry, type SheetModel, type StringsRow } from "./layout";
import { normalizeLocale } from "./locale";
import {
  CONTEXT_HEADER, CONTEXT_TAB, HISTORY_HEADER, HISTORY_TAB, SheetError, STATUS_HEADER, STATUS_TAB, STRINGS_TAB,
  type Grid, type HistoryAction,
} from "./types";

// MARK: request JSON

export type CellValue = { userEnteredValue: { stringValue: string } } | Record<string, never>;
export interface RowData {
  values: CellValue[];
}
export interface UpdateCellsRequest {
  updateCells: {
    start: { sheetId: number; rowIndex: number; columnIndex: number };
    rows: RowData[];
    fields: "userEnteredValue";
  };
}
export interface AppendCellsRequest {
  appendCells: { sheetId: number; rows: RowData[]; fields: "userEnteredValue" };
}
export type SheetRequest = UpdateCellsRequest | AppendCellsRequest;

/** An empty (or null) cell is written as `{}`, which clears it, like RunaCore does. */
function rowData(cells: readonly (string | null | undefined)[]): RowData {
  return {
    values: cells.map((value): CellValue => (value ? { userEnteredValue: { stringValue: value } } : ({} as Record<string, never>))),
  };
}

export function updateCells(sheetId: number, row: number, column: number, rows: (string | null | undefined)[][]): UpdateCellsRequest {
  return {
    updateCells: {
      start: { sheetId, rowIndex: row, columnIndex: column },
      rows: rows.map(rowData),
      fields: "userEnteredValue",
    },
  };
}

export function appendCells(sheetId: number, rows: string[][]): AppendCellsRequest {
  return { appendCells: { sheetId, rows: rows.map(rowData), fields: "userEnteredValue" } };
}

// MARK: shared pieces

export interface WriteContext {
  /** Display name from settings; written as `actor` and `linkedBy`. */
  actor: string;
  now: Date;
  /** History note. Defaults to "figma". */
  note?: string;
}

/** Design context captured for one link; exactly the `_context` columns minus id/linkedAt/linkedBy. */
export interface FigmaContextInput {
  url: string;
  fileKey: string;
  nodeId: string;
  page: string;
  frame: string;
  /** Node id (`12:34`) of the top-level frame containing the text; "" when not inside a frame. */
  frameId: string;
  path: string;
  width?: number;
  height?: number;
  fontSize?: number;
  /** Other texts in the same top-level frame, nearest first. Trimmed to 10 × 200 when written. */
  siblings: string[];
}

/** ISO 8601 UTC without fractional seconds: `2026-10-07T09:30:00Z`. */
export function isoDate(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Plain decimal, integers without a fraction (RunaCore prints numbers the same way). */
export function formatNumber(value: number | undefined): string {
  if (value === undefined || !Number.isFinite(value)) return "";
  return String(value);
}

/** The first `max` user-perceived characters (grapheme clusters, like Swift's `prefix`). */
export function truncateCharacters(text: string, max: number): string {
  if (text.length <= max) return text;
  const Segmenter = (Intl as { Segmenter?: typeof Intl.Segmenter }).Segmenter;
  if (Segmenter) {
    let out = "";
    let count = 0;
    for (const { segment } of new Segmenter(undefined, { granularity: "grapheme" }).segment(text)) {
      if (count === max) break;
      out += segment;
      count++;
    }
    return out;
  }
  return Array.from(text).slice(0, max).join("");
}

/** The `siblings` cell: a compact JSON array of up to 10 strings of at most 200 characters. */
export function siblingsCell(siblings: readonly string[]): string {
  if (siblings.length === 0) return "";
  return JSON.stringify(siblings.slice(0, 10).map((text) => truncateCharacters(text, 200)));
}

export function contextRow(id: string, context: FigmaContextInput, write: WriteContext): string[] {
  return [
    id,
    context.url,
    context.fileKey,
    context.nodeId,
    context.page,
    context.frame,
    context.path,
    formatNumber(context.width),
    formatNumber(context.height),
    formatNumber(context.fontSize),
    siblingsCell(context.siblings),
    isoDate(write.now),
    write.actor,
    context.frameId,
  ];
}

export interface HistoryInput {
  action: HistoryAction;
  id: string;
  key: string;
  locale?: string;
  plural?: PluralCategory;
  before?: string;
  after?: string;
}

export function historyRow(entry: HistoryInput, write: WriteContext): string[] {
  return [
    isoDate(write.now),
    write.actor,
    entry.action,
    entry.id,
    entry.key,
    entry.locale ?? "",
    entry.plural ?? "",
    entry.before ?? "",
    entry.after ?? "",
    write.note ?? "figma",
  ];
}

/**
 * Places a row given in canonical header order into the tab's actual column order
 * (people may reorder hidden tabs too). Columns are found by name: a value whose column the
 * tab does not have (for example `frameId` in a sheet set up before it existed) is left out
 * rather than written under the wrong header. Trailing empty cells are dropped.
 */
export function arrange(row: readonly string[], canonical: readonly string[], existingHeader: readonly string[] | undefined): string[] {
  const header = existingHeader && existingHeader.some((name) => name !== "") ? existingHeader : canonical;
  const columns = headerIndexes(header);
  const cells: string[] = new Array(header.length).fill("");
  canonical.forEach((name, index) => {
    const column = columns.get(name);
    if (column !== undefined) cells[column] = row[index] ?? "";
  });
  while (cells.length > 0 && cells[cells.length - 1] === "") cells.pop();
  return cells;
}

/** The smallest contiguous block of cells that differs, or undefined when nothing changed. */
export function diffRow(existing: readonly string[], rendered: readonly string[]): { column: number; cells: string[] } | undefined {
  const width = Math.max(existing.length, rendered.length);
  let first = -1;
  let last = -1;
  for (let index = 0; index < width; index++) {
    if ((existing[index] ?? "") !== (rendered[index] ?? "")) {
      if (first < 0) first = index;
      last = index;
    }
  }
  if (first < 0) return undefined;
  const cells: string[] = [];
  for (let index = first; index <= last; index++) cells.push(rendered[index] ?? "");
  return { column: first, cells };
}

function tabId(model: SheetModel, title: string): number | undefined {
  return model.info.tabs.find((tab) => tab.title === title)?.sheetId;
}

function requireTab(model: SheetModel, title: string): number {
  const id = tabId(model, title);
  if (id === undefined) throw setupNeeded([`the ${title} tab`]);
  return id;
}

function setupNeeded(issues: string[]): SheetError {
  return new SheetError(
    `This sheet is missing ${issues.join(", ")}. Open it once in the Runa Mac app to set it up, then refresh.`,
    "setup-needed",
  );
}

function requireWritable(model: SheetModel): void {
  if (model.setupIssues.length > 0) throw setupNeeded(model.setupIssues);
}

function sourceColumn(model: SheetModel): number {
  const entry = model.columns.locales.find((candidate) => candidate.locale === model.sourceLocale);
  if (!entry) throw new SheetError(`The source language ${model.sourceLocale} has no column.`, "no-locale");
  return entry.index;
}

/** Writes the key's id into `_id` cells that are blank (or not a UUID) on every row of the key. */
function idRequests(model: SheetModel, sheetId: number, entry: KeyEntry): SheetRequest[] {
  const column = model.columns.id;
  if (column === undefined) return [];
  return entry.rows.filter((row) => !row.hasStoredId).map((row) => updateCells(sheetId, row.index, column, [[entry.id]]));
}

export function findKey(model: SheetModel, ref: { keyId?: string; key?: string }): KeyEntry | undefined {
  return (ref.keyId ? model.byId.get(ref.keyId.toLowerCase()) : undefined) ?? (ref.key ? model.byName.get(ref.key) : undefined);
}

function requireKey(model: SheetModel, ref: { keyId?: string; key?: string }): KeyEntry {
  const entry = findKey(model, ref);
  if (!entry) throw new SheetError(`The key "${ref.key ?? ref.keyId}" is no longer in the sheet.`, "key-missing");
  return entry;
}

/** The `_context` row for (id, url): updated in place when it exists, appended otherwise. */
function upsertContext(model: SheetModel, sheetId: number, id: string, row: string[]): { update?: SheetRequest; append?: string[] } {
  const grid: Grid = model.grids[CONTEXT_TAB] ?? [];
  const header = grid[0];
  const columns = headerIndexes(header && header.length > 0 ? header : CONTEXT_HEADER);
  const desired = arrange(row, CONTEXT_HEADER, header);
  const url = row[1]!;
  for (let index = 1; index < grid.length; index++) {
    const existing = grid[index]!;
    if (cell(existing, columns.get("id")).trim().toLowerCase() !== id || cell(existing, columns.get("url")) !== url) continue;
    const diff = diffRow(existing, desired);
    return diff ? { update: updateCells(sheetId, index, diff.column, [diff.cells]) } : {};
  }
  return { append: desired };
}

function historyRows(model: SheetModel, entries: HistoryInput[], write: WriteContext): string[][] {
  const header = (model.grids[HISTORY_TAB] ?? [])[0];
  return entries.map((entry) => arrange(historyRow(entry, write), HISTORY_HEADER, header));
}

// MARK: create

export interface CreateItem {
  /** New random lowercase UUID v4. */
  id: string;
  key: string;
  /** Source-locale text (the Figma text). */
  text: string;
  description?: string;
  context: FigmaContextInput;
}

/** New keys (one or many) with their Figma context and history, in one batch. */
export function buildCreate(model: SheetModel, items: readonly CreateItem[], write: WriteContext): SheetRequest[] {
  if (items.length === 0) return [];
  requireWritable(model);
  const stringsId = requireTab(model, STRINGS_TAB);
  const contextId = requireTab(model, CONTEXT_TAB);
  const historyId = requireTab(model, HISTORY_TAB);
  const columns = model.columns;
  const source = sourceColumn(model);

  const names = new Set<string>();
  for (const item of items) {
    const problem = keyNameProblem(item.key, model.rules);
    if (problem) throw new SheetError(`"${item.key}": ${problem}`, "invalid-key");
    if (model.byName.has(item.key) || names.has(item.key)) {
      throw new SheetError(`A key named "${item.key}" already exists. Pick another name or link to it.`, "key-exists");
    }
    if (!item.text) throw new SheetError(`The layer for "${item.key}" has no text.`, "invalid-key");
    names.add(item.key);
  }

  const stringRows: string[][] = [];
  const contextRows: string[][] = [];
  const history: HistoryInput[] = [];
  for (const item of items) {
    const cells: string[] = new Array(columns.width).fill("");
    const set = (index: number | undefined, value: string) => {
      if (index !== undefined) cells[index] = value;
    };
    set(columns.id, item.id);
    set(columns.key, item.key);
    set(columns.description, item.description?.trim() ?? "");
    set(columns.plural, "");
    set(columns.platforms, platformIn(item.key, model.rules) ?? "");
    cells[source] = item.text;
    set(columns.figma, item.context.url);
    stringRows.push(cells);
    contextRows.push(arrange(contextRow(item.id, item.context, write), CONTEXT_HEADER, (model.grids[CONTEXT_TAB] ?? [])[0]));
    history.push({ action: "add-key", id: item.id, key: item.key, locale: model.sourceLocale, after: item.text });
    history.push({ action: "link-figma", id: item.id, key: item.key, after: item.context.url });
  }
  return [
    appendCells(stringsId, stringRows),
    appendCells(contextId, contextRows),
    appendCells(historyId, historyRows(model, history, write)),
  ];
}

// MARK: link

export interface LinkInput {
  keyId?: string;
  key?: string;
  context: FigmaContextInput;
}

export interface LinkResult {
  requests: SheetRequest[];
  entry: KeyEntry;
}

/** Links a layer to an existing key: figma cell, `_context` upsert, derived id, history. */
export function buildLink(model: SheetModel, input: LinkInput, write: WriteContext): LinkResult {
  requireWritable(model);
  const entry = requireKey(model, input);
  const stringsId = requireTab(model, STRINGS_TAB);
  const contextId = requireTab(model, CONTEXT_TAB);
  const historyId = requireTab(model, HISTORY_TAB);
  const url = input.context.url;
  const requests: SheetRequest[] = [];

  requests.push(...idRequests(model, stringsId, entry));

  const figmaColumn = model.columns.figma;
  const firstRow = entry.rows[0]!;
  if (figmaColumn !== undefined) {
    const current = splitList(cell(firstRow.cells, figmaColumn));
    if (!current.includes(url)) {
      requests.push(updateCells(stringsId, firstRow.index, figmaColumn, [[[...current, url].join("\n")]]));
    }
  }

  const context = upsertContext(model, contextId, entry.id, contextRow(entry.id, input.context, write));
  if (context.update) requests.push(context.update);
  if (context.append) requests.push(appendCells(contextId, [context.append]));

  const before = entry.figmaUrls;
  const after = before.includes(url) ? before : [...before, url];
  requests.push(
    appendCells(historyId, historyRows(model, [{ action: "link-figma", id: entry.id, key: entry.key, before: before.join("\n"), after: after.join("\n") }], write)),
  );
  return { requests, entry };
}

// MARK: push

export interface PushInput {
  keyId?: string;
  key?: string;
  /** The source text the plugin loaded and showed (what this edit is based on). */
  baseText: string;
  /** The Figma text to write. */
  newText: string;
}

export type PushResult =
  | { kind: "write"; requests: SheetRequest[]; entry: KeyEntry; before: string }
  | { kind: "conflict"; entry: KeyEntry; remote: string }
  | { kind: "unchanged"; entry: KeyEntry };

/** The row that holds a plain key's value: the first row of the `other` form. */
function valueRow(entry: KeyEntry): StringsRow {
  return entry.rows.find((row) => (row.category ?? "other") === "other") ?? entry.rows[0]!;
}

/** Sets a plain key's source text from Figma, with conflict detection against `baseText`. */
export function buildPush(model: SheetModel, input: PushInput, write: WriteContext): PushResult {
  requireWritable(model);
  const entry = requireKey(model, input);
  if (entry.isPlural) throw new SheetError("Plural keys are edited in the Runa app.", "plural");
  if (!input.newText) throw new SheetError("The layer is empty. Add text before pushing it.", "invalid-key");
  const stringsId = requireTab(model, STRINGS_TAB);
  const historyId = requireTab(model, HISTORY_TAB);
  const source = sourceColumn(model);
  const row = valueRow(entry);
  const remote = cell(row.cells, source);
  if (remote === input.newText) return { kind: "unchanged", entry };
  if (remote !== input.baseText) return { kind: "conflict", entry, remote };

  const requests: SheetRequest[] = [];
  requests.push(...idRequests(model, stringsId, entry));
  requests.push(updateCells(stringsId, row.index, source, [[input.newText]]));
  requests.push(...statusBaseline(model, entry));
  requests.push(
    appendCells(historyId, historyRows(model, [{ action: "set-value", id: entry.id, key: entry.key, locale: model.sourceLocale, before: remote, after: input.newText }], write)),
  );
  return { kind: "write", requests, entry, before: remote };
}

/**
 * Before the source text changes, record which source text each existing translation belongs to
 * (`_status.sourceHash`), so the Mac app shows them as needing review afterwards. Mirrors
 * `ChangeApplier.baseline` + `SheetWriter.statusRows` in RunaCore.
 */
export function statusBaseline(model: SheetModel, entry: KeyEntry): SheetRequest[] {
  const sheetId = model.info.tabs.find((tab) => tab.title === STATUS_TAB)?.sheetId;
  if (sheetId === undefined) return [];
  const oldSourceHash = Object.values(entry.source).some((text) => !!text) ? textHash(entry.source) : undefined;
  if (!oldSourceHash) return [];
  const statusGrid = model.grids[STATUS_TAB];
  // Appending without knowing the existing rows would duplicate them: writes must use readSheet(…, { forWrite: true }).
  if (!statusGrid) throw new Error("The _status tab was not read before writing.");
  const grid: Grid = statusGrid;
  const header = grid[0];
  const columns = headerIndexes(header && header.length > 0 ? header : STATUS_HEADER);
  const requests: SheetRequest[] = [];
  const appended: string[][] = [];

  for (const { locale, index } of model.columns.locales) {
    if (locale === model.sourceLocale) continue;
    const forms: Forms = {};
    const seen = new Set<PluralCategory>();
    for (const row of entry.rows) {
      const category = row.category ?? "other";
      if (seen.has(category)) continue;
      seen.add(category);
      const text = cell(row.cells, index);
      if (text) forms[category] = text;
    }
    if (Object.keys(forms).length === 0) continue;
    const hash = textHash(forms);

    let firstMatch = -1;
    let lastMatch = -1;
    for (let rowIndex = 1; rowIndex < grid.length; rowIndex++) {
      const row = grid[rowIndex]!;
      if (cell(row, columns.get("id")).trim().toLowerCase() !== entry.id) continue;
      if (normalizeLocale(cell(row, columns.get("locale"))) !== locale) continue;
      if (firstMatch < 0) firstMatch = rowIndex;
      lastMatch = rowIndex;
    }
    let status = "approved";
    let sourceHash: string | undefined;
    let updatedAt = "";
    let updatedBy = "";
    if (lastMatch >= 0) {
      const recorded = grid[lastMatch]!;
      if (cell(recorded, columns.get("hash")) === hash) {
        const stored = cell(recorded, columns.get("status"));
        status = ["machine", "needs-review", "approved"].includes(stored) ? stored : "approved";
        sourceHash = cell(recorded, columns.get("sourceHash")) || undefined;
      }
      updatedAt = cell(recorded, columns.get("updatedAt"));
      updatedBy = cell(recorded, columns.get("updatedBy"));
    }
    sourceHash ??= oldSourceHash;
    const desired = arrange([entry.id, locale, status, hash, sourceHash, updatedAt, updatedBy], STATUS_HEADER, header);
    if (firstMatch >= 0) {
      const diff = diffRow(grid[firstMatch]!, desired);
      if (diff) requests.push(updateCells(sheetId, firstMatch, diff.column, [diff.cells]));
    } else {
      appended.push(desired);
    }
  }
  if (appended.length > 0) requests.push(appendCells(sheetId, appended));
  return requests;
}
