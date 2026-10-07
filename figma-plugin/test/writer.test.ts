import { describe, expect, it } from "vitest";
import { textHash } from "../src/sheets/hash";
import { SheetError } from "../src/sheets/types";
import {
  arrange, buildCreate, buildLink, buildPush, diffRow, formatNumber, isoDate, siblingsCell,
  type FigmaContextInput, type SheetRequest, type WriteContext,
} from "../src/sheets/writer";
import { CONTEXT_HEADER_V1, IDS, sampleModel, TITLE_URL } from "./fixtures";

const NEW_ID = "0b6f3c8e-2f4a-4d6b-9c1e-7a8b9c0d1e2f";
const NEW_URL = "https://www.figma.com/design/FILE1/App?node-id=9-10";
const TS = "2026-10-07T09:30:00Z";
const write: WriteContext = { actor: "Alex", now: new Date("2026-10-07T09:30:00.123Z") };

function context(overrides: Partial<FigmaContextInput> = {}): FigmaContextInput {
  return {
    url: NEW_URL,
    fileKey: "FILE1",
    nodeId: "9:10",
    page: "Checkout",
    frame: "Summary",
    frameId: "1:1",
    path: "Summary/Footer/Pay",
    width: 96.5,
    height: 20,
    fontSize: 14,
    siblings: ["Total", "Checkout"],
    ...overrides,
  };
}

/** The cell texts of a request's rows ("" for cleared cells). */
function rowsOf(request: SheetRequest): string[][] {
  const rows = "updateCells" in request ? request.updateCells.rows : request.appendCells.rows;
  return rows.map((row) => row.values.map((value) => ("userEnteredValue" in value ? value.userEnteredValue.stringValue : "")));
}

function target(request: SheetRequest): string {
  if ("updateCells" in request) {
    const start = request.updateCells.start;
    return `update ${start.sheetId} r${start.rowIndex} c${start.columnIndex}`;
  }
  return `append ${request.appendCells.sheetId}`;
}

const contextRowNew = [NEW_ID, NEW_URL, "FILE1", "9:10", "Checkout", "Summary", "Summary/Footer/Pay", "96.5", "20", "14", '["Total","Checkout"]', TS, "Alex", "1:1"];

describe("request JSON", () => {
  it("writes text with stringValue and clears empty cells with {}", () => {
    const [strings] = buildCreate(sampleModel(), [{ id: NEW_ID, key: "math.formula", text: "=1+1", context: context() }], write);
    expect(strings).toEqual({
      appendCells: {
        sheetId: 0,
        rows: [
          {
            values: [
              { userEnteredValue: { stringValue: NEW_ID } },
              { userEnteredValue: { stringValue: "math.formula" } },
              {},
              {},
              { userEnteredValue: { stringValue: "=1+1" } },
              {},
              { userEnteredValue: { stringValue: NEW_URL } },
              {},
              {},
            ],
          },
        ],
        fields: "userEnteredValue",
      },
    });
  });
});

describe("buildCreate", () => {
  it("appends the key row, its _context row and add-key + link-figma history", () => {
    const requests = buildCreate(sampleModel(), [{ id: NEW_ID, key: "checkout.total", text: "Total", description: " Sum of the order ", context: context() }], write);
    expect(requests.map(target)).toEqual(["append 0", "append 13", "append 14"]);
    expect(rowsOf(requests[0]!)).toEqual([[NEW_ID, "checkout.total", "Sum of the order", "", "Total", "", NEW_URL, "", ""]]);
    expect(rowsOf(requests[1]!)).toEqual([contextRowNew]);
    expect(rowsOf(requests[2]!)).toEqual([
      [TS, "Alex", "add-key", NEW_ID, "checkout.total", "en", "", "", "Total", "figma"],
      [TS, "Alex", "link-figma", NEW_ID, "checkout.total", "", "", "", NEW_URL, "figma"],
    ]);
  });

  it("creates several keys in one batch", () => {
    const second = "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f";
    const requests = buildCreate(
      sampleModel(),
      [
        { id: NEW_ID, key: "checkout.total", text: "Total", context: context() },
        { id: second, key: "checkout.vat", text: "VAT", context: context({ url: NEW_URL.replace("9-10", "9-11"), nodeId: "9:11" }) },
      ],
      write,
    );
    expect(requests).toHaveLength(3);
    expect(rowsOf(requests[0]!).map((row) => row[1])).toEqual(["checkout.total", "checkout.vat"]);
    expect(rowsOf(requests[1]!)).toHaveLength(2);
    expect(rowsOf(requests[2]!)).toHaveLength(4);
  });

  it("refuses names that exist in the sheet or twice in the batch", () => {
    const model = sampleModel();
    expect(() => buildCreate(model, [{ id: NEW_ID, key: "checkout.title", text: "x", context: context() }], write)).toThrow(/already exists/);
    expect(() =>
      buildCreate(model, [
        { id: NEW_ID, key: "a.b", text: "x", context: context() },
        { id: IDS.items, key: "a.b", text: "y", context: context() },
      ], write),
    ).toThrow(SheetError);
    expect(() => buildCreate(model, [{ id: NEW_ID, key: "bad key", text: "x", context: context() }], write)).toThrow(/spaces/);
  });

  it("refuses to write when the sheet is not set up by the Mac app", () => {
    const model = sampleModel(undefined, ["_context"]);
    try {
      buildCreate(model, [{ id: NEW_ID, key: "a.b", text: "x", context: context() }], write);
      expect.unreachable();
    } catch (error) {
      expect((error as SheetError).code).toBe("setup-needed");
      expect((error as SheetError).message).toMatch(/Runa Mac app/);
    }
  });

  it("leaves frameId out of _context rows when the tab has no frameId column", () => {
    const model = sampleModel((grids) => {
      grids._context = [CONTEXT_HEADER_V1];
    });
    const requests = buildCreate(model, [{ id: NEW_ID, key: "a.b", text: "x", context: context() }], write);
    expect(rowsOf(requests[1]!)).toEqual([contextRowNew.slice(0, 13)]);
  });
});

describe("buildLink", () => {
  it("writes the derived id, the figma cell, a _context row and history for a key without a stored id", () => {
    const { requests, entry } = buildLink(sampleModel(), { keyId: IDS.payNow, context: context() }, write);
    expect(entry.key).toBe("checkout.pay_now");
    expect(requests.map(target)).toEqual(["update 0 r2 c0", "update 0 r2 c6", "append 13", "append 14"]);
    expect(rowsOf(requests[0]!)).toEqual([[IDS.payNow]]);
    expect(rowsOf(requests[1]!)).toEqual([[NEW_URL]]);
    expect(rowsOf(requests[2]!)).toEqual([[IDS.payNow, ...contextRowNew.slice(1)]]);
    expect(rowsOf(requests[3]!)).toEqual([[TS, "Alex", "link-figma", IDS.payNow, "checkout.pay_now", "", "", "", NEW_URL, "figma"]]);
  });

  it("adds a URL to the existing figma cell, one per line", () => {
    const { requests } = buildLink(sampleModel(), { keyId: IDS.title, context: context() }, write);
    expect(requests.map(target)).toEqual(["update 0 r1 c6", "append 13", "append 14"]);
    expect(rowsOf(requests[0]!)).toEqual([[`${TITLE_URL}\n${NEW_URL}`]]);
    expect(rowsOf(requests[2]!)[0]!.slice(7, 9)).toEqual([TITLE_URL, `${TITLE_URL}\n${NEW_URL}`]);
  });

  it("updates the existing _context row for the same node in place, only the cells that changed", () => {
    const relink = context({
      url: TITLE_URL,
      nodeId: "1:2",
      path: "Summary/Header/Title",
      width: 120,
      height: 24,
      fontSize: 17,
      siblings: ["Pay now"],
    });
    const { requests } = buildLink(sampleModel(), { key: "checkout.title", context: relink }, write);
    // No figma cell change: the URL is already there.
    expect(requests.map(target)).toEqual(["update 13 r1 c6", "append 14"]);
    expect(rowsOf(requests[0]!)).toEqual([["Summary/Header/Title", "120", "24", "17", '["Pay now"]', TS]]);
  });

  it("writes plural keys' links on the key's first row", () => {
    const { requests } = buildLink(sampleModel(), { keyId: IDS.items, context: context() }, write);
    expect(requests.map(target)).toEqual(["update 0 r3 c6", "append 13", "append 14"]);
  });

  it("resolves rows from the fresh read, even after rows moved", () => {
    const model = sampleModel((grids) => {
      grids.strings!.splice(1, 0, ["", "inserted.by.someone", "", "", "Hi"]);
    });
    const { requests } = buildLink(model, { keyId: IDS.payNow, context: context() }, write);
    expect(requests.map(target).slice(0, 2)).toEqual(["update 0 r3 c0", "update 0 r3 c6"]);
  });

  it("reports a key that is gone", () => {
    expect(() => buildLink(sampleModel(), { keyId: NEW_ID, key: "gone.key", context: context() }, write)).toThrow(/no longer in the sheet/);
  });
});

describe("buildPush", () => {
  it("sets the source cell, baselines translations in _status and appends set-value history", () => {
    const result = buildPush(sampleModel(), { keyId: IDS.title, baseText: "Checkout", newText: "Check out" }, write);
    expect(result.kind).toBe("write");
    if (result.kind !== "write") return;
    expect(result.requests.map(target)).toEqual(["update 0 r1 c4", "append 12", "append 14"]);
    expect(rowsOf(result.requests[0]!)).toEqual([["Check out"]]);
    // sv had no _status row: it now records the old source hash, so the app shows it as needing review.
    expect(rowsOf(result.requests[1]!)).toEqual([[IDS.title, "sv", "approved", textHash({ other: "Kassa" }), textHash({ other: "Checkout" })]]);
    expect(rowsOf(result.requests[2]!)).toEqual([[TS, "Alex", "set-value", IDS.title, "checkout.title", "en", "", "Checkout", "Check out", "figma"]]);
  });

  it("fills a missing sourceHash on an existing _status row and writes the derived id", () => {
    const result = buildPush(sampleModel(), { keyId: IDS.payNow, baseText: "Pay now", newText: "Pay today" }, write);
    if (result.kind !== "write") throw new Error(result.kind);
    expect(result.requests.map(target)).toEqual(["update 0 r2 c0", "update 0 r2 c4", "update 12 r1 c4", "append 14"]);
    expect(rowsOf(result.requests[2]!)).toEqual([[textHash({ other: "Pay now" })]]);
  });

  it("does not write when the sheet changed since the plugin loaded it", () => {
    const model = sampleModel((grids) => {
      grids.strings![1]![4] = "Checkout now";
    });
    const result = buildPush(model, { keyId: IDS.title, baseText: "Checkout", newText: "Check out" }, write);
    expect(result).toMatchObject({ kind: "conflict", remote: "Checkout now" });
  });

  it("does nothing when the sheet already has the text", () => {
    const result = buildPush(sampleModel(), { keyId: IDS.title, baseText: "Old", newText: "Checkout" }, write);
    expect(result.kind).toBe("unchanged");
  });

  it("writes text that looks like a formula as text", () => {
    const result = buildPush(sampleModel(), { keyId: IDS.formula, baseText: "=SUM(A1)", newText: "=SUM(A2)" }, write);
    if (result.kind !== "write") throw new Error(result.kind);
    expect(result.requests[1]).toEqual({
      updateCells: {
        start: { sheetId: 0, rowIndex: 6, columnIndex: 4 },
        rows: [{ values: [{ userEnteredValue: { stringValue: "=SUM(A2)" } }] }],
        fields: "userEnteredValue",
      },
    });
  });

  it("refuses plural keys", () => {
    expect(() => buildPush(sampleModel(), { keyId: IDS.items, baseText: "", newText: "x" }, write)).toThrow(/edited in the Runa app/);
  });
});

describe("helpers", () => {
  it("formats dates and numbers like RunaCore", () => {
    expect(isoDate(new Date("2026-10-07T09:30:00.999Z"))).toBe("2026-10-07T09:30:00Z");
    expect(formatNumber(120)).toBe("120");
    expect(formatNumber(96.5)).toBe("96.5");
    expect(formatNumber(undefined)).toBe("");
  });

  it("keeps at most 10 siblings of at most 200 characters, counting emoji as one", () => {
    const siblings = Array.from({ length: 12 }, (_, index) => `Text ${index}`);
    expect(JSON.parse(siblingsCell(siblings))).toHaveLength(10);
    const long = "👋".repeat(250);
    const [first] = JSON.parse(siblingsCell([long])) as string[];
    expect(Array.from(first!)).toHaveLength(200);
    expect(siblingsCell([])).toBe("");
    expect(siblingsCell(['Say "hi"'])).toBe('["Say \\"hi\\""]');
  });

  it("arranges rows by the tab's own header", () => {
    expect(arrange(["a", "b", "c"], ["x", "y", "z"], ["z", "x", "extra", "y"])).toEqual(["c", "a", "", "b"]);
    expect(arrange(["a", "b", ""], ["x", "y", "z"], [])).toEqual(["a", "b"]);
  });

  it("diffs rows to the smallest changed block", () => {
    expect(diffRow(["a", "b", "c", "d"], ["a", "B", "c", "D"])).toEqual({ column: 1, cells: ["B", "c", "D"] });
    expect(diffRow(["a"], ["a", ""])).toBeUndefined();
    expect(diffRow(["a", "b"], ["a"])).toEqual({ column: 1, cells: [""] });
  });
});

describe("fresh reads", () => {
  it("refuses to push from a display read that did not include _status", () => {
    const model = sampleModel((grids) => {
      delete grids._status;
    });
    expect(() => buildPush(model, { keyId: IDS.title, baseText: "Checkout", newText: "Check out" }, write)).toThrow(/_status/);
  });
});
