/** Shapes shared by the sheet modules. Tab and column names come from docs/SHEET_FORMAT.md. */

export const STRINGS_TAB = "strings";
export const META_TAB = "_meta";
export const STATUS_TAB = "_status";
export const CONTEXT_TAB = "_context";
export const HISTORY_TAB = "_history";
export const HIDDEN_TABS = [META_TAB, STATUS_TAB, CONTEXT_TAB, HISTORY_TAB] as const;
/** Visible tab with the naming guide, key template and pattern (docs/SHEET_FORMAT.md). */
export const GUIDELINES_TAB = "guidelines";

export const STATUS_HEADER = ["id", "locale", "status", "hash", "sourceHash", "updatedAt", "updatedBy"] as const;
export const CONTEXT_HEADER = [
  "id", "url", "fileKey", "nodeId", "page", "frame", "path", "width", "height", "fontSize", "siblings", "linkedAt", "linkedBy",
  "frameId",
] as const;
export const HISTORY_HEADER = ["ts", "actor", "action", "id", "key", "locale", "plural", "before", "after", "note"] as const;

/** Header names that are never locales, even when they look like one. */
export const RESERVED_COLUMNS = ["_id", "key", "description", "comment", "context", "plural", "figma", "tags", "platforms"];
export const DESCRIPTION_ALIASES = ["description", "comment", "context"];

export interface TabInfo {
  sheetId: number;
  title: string;
  hidden: boolean;
  rowCount: number;
  columnCount: number;
}

export interface SpreadsheetInfo {
  title: string;
  tabs: TabInfo[];
}

/** Formatted cell values by row, as `values:batchGet` returns them (trailing empties omitted). */
export type Grid = string[][];
export type Grids = Partial<Record<string, Grid>>;

export type HistoryAction =
  | "add-key" | "update-key" | "delete-key" | "set-value" | "set-status" | "link-figma" | "add-locale" | "remove-locale";

export class SheetError extends Error {
  constructor(
    message: string,
    readonly code:
      | "no-strings-tab"
      | "no-key-column"
      | "no-locale"
      | "setup-needed"
      | "key-exists"
      | "key-missing"
      | "plural"
      | "conflict"
      | "invalid-key"
      | "auth"
      | "access"
      | "not-found"
      | "network"
      | "rate-limited"
      | "server",
  ) {
    super(message);
    this.name = "SheetError";
  }
}
