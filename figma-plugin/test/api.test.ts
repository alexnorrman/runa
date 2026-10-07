import { describe, expect, it } from "vitest";
import { SheetsApi, spreadsheetIdFrom, tabRange } from "../src/sheets/api";
import { readSheet } from "../src/sheets/repository";
import { appendCells } from "../src/sheets/writer";
import { sampleGrids, sampleInfo } from "./fixtures";

const account = { type: "service_account" as const, client_email: "runa-bot@p.iam.gserviceaccount.com", private_key: "" };

function api(responses: (Response | (() => Response))[], log: { url: string; init?: RequestInit }[] = [], resets = { count: 0 }) {
  const tokens = {
    account,
    accessToken: async () => "tok",
    reset: () => {
      resets.count++;
    },
  };
  const fetcher = async (url: string, init?: RequestInit) => {
    log.push({ url, init });
    const next = responses.shift();
    if (!next) throw new TypeError("Failed to fetch");
    return typeof next === "function" ? next() : next;
  };
  return new SheetsApi(tokens, { fetcher, sleep: async () => undefined });
}

const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });

describe("spreadsheet ids and ranges", () => {
  it("accepts links and bare ids", () => {
    expect(spreadsheetIdFrom("https://docs.google.com/spreadsheets/d/1AbC_dEf-123456789012345/edit#gid=0")).toBe("1AbC_dEf-123456789012345");
    expect(spreadsheetIdFrom(" 1AbC_dEf-123456789012345 ")).toBe("1AbC_dEf-123456789012345");
    expect(spreadsheetIdFrom("hello")).toBeUndefined();
  });
  it("quotes tab names", () => {
    expect(tabRange("_history", "1:1")).toBe("'_history'!1:1");
    expect(tabRange("it's")).toBe("'it''s'");
  });
});

describe("SheetsApi", () => {
  it("reads metadata", async () => {
    const log: { url: string; init?: RequestInit }[] = [];
    const client = api([json({ properties: { title: "Shop" }, sheets: [{ properties: { sheetId: 7, title: "strings", gridProperties: { rowCount: 10, columnCount: 9 } } }] })], log);
    expect(await client.spreadsheet("ID")).toEqual({ title: "Shop", tabs: [{ sheetId: 7, title: "strings", hidden: false, rowCount: 10, columnCount: 9 }] });
    expect(log[0]!.url).toMatch(/^https:\/\/sheets\.googleapis\.com\/v4\/spreadsheets\/ID\?fields=/);
    expect((log[0]!.init!.headers as Record<string, string>).Authorization).toBe("Bearer tok");
  });

  it("batch-gets formatted values in the order asked", async () => {
    const log: { url: string; init?: RequestInit }[] = [];
    const client = api([json({ valueRanges: [{ values: [["key", "en"], ["a", 1, true]] }, {}] })], log);
    expect(await client.batchGet("ID", ["'strings'", "'_meta'"])).toEqual([[["key", "en"], ["a", "1", "TRUE"]], []]);
    expect(log[0]!.url).toContain("values:batchGet?ranges='strings'&ranges='_meta'&valueRenderOption=FORMATTED_VALUE&majorDimension=ROWS");
  });

  it("sends all requests in one batchUpdate", async () => {
    const log: { url: string; init?: RequestInit }[] = [];
    const client = api([json({})], log);
    await client.batchUpdate("ID", [appendCells(14, [["a"]])]);
    expect(log).toHaveLength(1);
    expect(log[0]!.url).toBe("https://sheets.googleapis.com/v4/spreadsheets/ID:batchUpdate");
    expect(log[0]!.init!.method).toBe("POST");
    expect(JSON.parse(String(log[0]!.init!.body))).toEqual({ requests: [appendCells(14, [["a"]])] });
  });

  it("asks to share the sheet with the service account on 403", async () => {
    const client = api([json({ error: { message: "The caller does not have permission", status: "PERMISSION_DENIED" } }, 403)]);
    await expect(client.spreadsheet("ID")).rejects.toThrow("Share the sheet with runa-bot@p.iam.gserviceaccount.com as an editor.");
  });

  it("explains a disabled Sheets API", async () => {
    const client = api([json({ error: { message: "Google Sheets API has not been used in project 123 before or it is disabled." } }, 403)]);
    await expect(client.spreadsheet("ID")).rejects.toThrow(/not enabled/);
  });

  it("says when the spreadsheet is not found", async () => {
    const client = api([json({ error: { message: "Requested entity was not found." } }, 404)]);
    await expect(client.spreadsheet("ID")).rejects.toThrow(/Spreadsheet not found/);
  });

  it("retries 429 and 5xx, and re-authenticates once on 401", async () => {
    const resets = { count: 0 };
    const client = api([json({}, 503), json({}, 429), json({ error: { message: "expired" } }, 401), json({ properties: { title: "T" }, sheets: [] })], [], resets);
    expect((await client.spreadsheet("ID")).title).toBe("T");
    expect(resets.count).toBe(1);
  });

  it("reports network failures", async () => {
    await expect(api([]).spreadsheet("ID")).rejects.toThrow(/Could not reach Google Sheets/);
  });
});

describe("readSheet", () => {
  it("reads strings, _meta and _context for display, and also _status and the _history header for writing", async () => {
    const grids = sampleGrids();
    const asked: string[][] = [];
    const fake = {
      spreadsheet: async () => sampleInfo(),
      batchGet: async (_id: string, ranges: readonly string[]) => {
        asked.push([...ranges]);
        return ranges.map((range) => grids[range.replace(/^'|'(!.*)?$/g, "")] ?? []);
      },
    };
    const model = await readSheet(fake, "ID");
    expect(asked[0]).toEqual(["'strings'", "'_meta'", "'_context'"]);
    expect(model.keys).toHaveLength(4);
    await readSheet(fake, "ID", { forWrite: true });
    expect(asked[1]).toEqual(["'strings'", "'_meta'", "'_context'", "'_status'", "'_history'!1:1"]);
  });

  it("only asks for tabs that exist", async () => {
    const asked: string[][] = [];
    const fake = {
      spreadsheet: async () => sampleInfo(["_context", "_history", "_status", "_meta"]),
      batchGet: async (_id: string, ranges: readonly string[]) => {
        asked.push([...ranges]);
        return [sampleGrids().strings!];
      },
    };
    const model = await readSheet(fake, "ID", { forWrite: true });
    expect(asked[0]).toEqual(["'strings'"]);
    expect(model.setupIssues).toEqual(["the _context tab", "the _history tab"]);
  });

  it("tells the user to set the sheet up when there is no strings tab", async () => {
    const fake = { spreadsheet: async () => ({ title: "Empty", tabs: [] }), batchGet: async () => [] };
    await expect(readSheet(fake, "ID")).rejects.toThrow(/Runa Mac app/);
  });
});
