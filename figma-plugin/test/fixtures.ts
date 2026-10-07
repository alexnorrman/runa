import { derivedId, textHash } from "../src/sheets/hash";
import { parseSheet, type SheetModel } from "../src/sheets/layout";
import type { Grids, SpreadsheetInfo, TabInfo } from "../src/sheets/types";

export const IDS = {
  title: "d286c840-69d2-5786-b77b-30b06363380d", // derived id of checkout.title (stored)
  items: "31962844-99e1-5361-85d8-42d00b9b2191", // derived id of cart.items (stored)
  payNow: derivedId("checkout.pay_now"), // blank _id cell in the sheet
  formula: derivedId("formula.text"),
};

export const STRINGS_HEADER = ["_id", "key", "description", "plural", "en", "sv", "figma", "tags", "platforms"];
export const TITLE_URL = "https://www.figma.com/design/FILE1/App?node-id=1-2";

export const CONTEXT_HEADER_V1 = ["id", "url", "fileKey", "nodeId", "page", "frame", "path", "width", "height", "fontSize", "siblings", "linkedAt", "linkedBy"];
export const CONTEXT_HEADER = [...CONTEXT_HEADER_V1, "frameId"];

export function sampleGrids(): Grids {
  return {
    strings: [
      STRINGS_HEADER,
      [IDS.title, "checkout.title", "Title on checkout", "", "Checkout", "Kassa", TITLE_URL],
      ["", "checkout.pay_now", "", "", "Pay now", "Betala nu"],
      [IDS.items, "cart.items", "Item count", "one", "{count:int} item", "{count:int} vara"],
      [IDS.items, "cart.items", "", "other", "{count:int} items", "{count:int} varor"],
      [],
      ["", "formula.text", "", "", "=SUM(A1)"],
    ],
    _meta: [["key", "value"], ["schemaVersion", "1"], ["projectName", "Shop"], ["sourceLocale", "en"]],
    _context: [
      CONTEXT_HEADER,
      [IDS.title, TITLE_URL, "FILE1", "1:2", "Checkout", "Summary", "Summary/Title", "120", "24", "17", '["Pay now"]', "2026-10-01T08:00:00Z", "Alex", "1:1"],
    ],
    _status: [
      ["id", "locale", "status", "hash", "sourceHash", "updatedAt", "updatedBy"],
      // pay_now's sv row: matches the current text, machine status, no sourceHash yet
      [IDS.payNow, "sv", "machine", textHash({ other: "Betala nu" }), "", "2026-10-02T10:00:00Z", "AI"],
    ],
    _history: [["ts", "actor", "action", "id", "key", "locale", "plural", "before", "after", "note"]],
  };
}

export function tab(sheetId: number, title: string, hidden = false): TabInfo {
  return { sheetId, title, hidden, rowCount: 1000, columnCount: 26 };
}

export function sampleInfo(omit: string[] = []): SpreadsheetInfo {
  const tabs = [tab(0, "strings"), tab(11, "_meta", true), tab(12, "_status", true), tab(13, "_context", true), tab(14, "_history", true)];
  return { title: "Shop strings", tabs: tabs.filter((candidate) => !omit.includes(candidate.title)) };
}

export function sampleModel(edit?: (grids: Grids) => void, omit: string[] = []): SheetModel {
  const grids = sampleGrids();
  for (const name of omit) delete grids[name];
  edit?.(grids);
  return parseSheet(sampleInfo(omit), grids);
}

export { textHash };
