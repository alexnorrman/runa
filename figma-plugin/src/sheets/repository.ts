/** Reads a Runa sheet through the API into a model, for display or right before a write. */
import type { SheetsApi } from "./api";
import { tabRange } from "./api";
import { parseSheet, type SheetModel } from "./layout";
import { CONTEXT_TAB, GUIDELINES_TAB, HISTORY_TAB, META_TAB, SheetError, STATUS_TAB, STRINGS_TAB, type Grids } from "./types";

export interface ReadOptions {
  /** Also read `_status` and the `_history` header, which writes need. */
  forWrite?: boolean;
}

export async function readSheet(api: Pick<SheetsApi, "spreadsheet" | "batchGet">, spreadsheetId: string, options: ReadOptions = {}): Promise<SheetModel> {
  const info = await api.spreadsheet(spreadsheetId);
  const has = (tab: string) => info.tabs.some((candidate) => candidate.title === tab);
  if (!has(STRINGS_TAB)) {
    throw new SheetError(`The spreadsheet has no "${STRINGS_TAB}" tab yet. Set it up from the Runa Mac app first.`, "no-strings-tab");
  }
  const wanted: { tab: string; range: string }[] = [{ tab: STRINGS_TAB, range: tabRange(STRINGS_TAB) }];
  for (const tab of [META_TAB, CONTEXT_TAB, GUIDELINES_TAB]) if (has(tab)) wanted.push({ tab, range: tabRange(tab) });
  if (options.forWrite) {
    if (has(STATUS_TAB)) wanted.push({ tab: STATUS_TAB, range: tabRange(STATUS_TAB) });
    if (has(HISTORY_TAB)) wanted.push({ tab: HISTORY_TAB, range: tabRange(HISTORY_TAB, "1:1") });
  }
  const values = await api.batchGet(spreadsheetId, wanted.map((item) => item.range));
  const grids: Grids = {};
  wanted.forEach((item, index) => {
    grids[item.tab] = values[index] ?? [];
  });
  return parseSheet(info, grids);
}
