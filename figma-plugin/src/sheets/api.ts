/**
 * The three Google Sheets calls the plugin needs: spreadsheet metadata, `values:batchGet`
 * (FORMATTED_VALUE) and `spreadsheets.batchUpdate` (atomic). Errors become SheetErrors with
 * sentences a designer can act on.
 */
import type { FetchLike, TokenProvider } from "./auth";
import type { SheetRequest } from "./writer";
import { SheetError, type Grid, type SpreadsheetInfo } from "./types";

const BASE = "https://sheets.googleapis.com/v4/spreadsheets/";

/** Accepts a full link (`…/spreadsheets/d/<id>/edit#gid=0`) or a bare id. */
export function spreadsheetIdFrom(input: string): string | undefined {
  const trimmed = input.trim();
  const match = /\/spreadsheets\/d\/([A-Za-z0-9_-]+)/.exec(trimmed);
  if (match) return match[1];
  return /^[A-Za-z0-9_-]{20,}$/.test(trimmed) ? trimmed : undefined;
}

/** A1 range for a whole tab, `'my tab'`, with quotes doubled. `rows` limits it, for example "1:1". */
export function tabRange(tab: string, rows?: string): string {
  const quoted = `'${tab.replace(/'/g, "''")}'`;
  return rows ? `${quoted}!${rows}` : quoted;
}

export interface ApiOptions {
  fetcher?: FetchLike;
  sleep?: (ms: number) => Promise<void>;
  /** Retries for 429 and 5xx responses. */
  retries?: number;
}

export class SheetsApi {
  private readonly fetcher: FetchLike;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly retries: number;

  constructor(
    private readonly tokens: Pick<TokenProvider, "accessToken" | "reset" | "account">,
    options: ApiOptions = {},
  ) {
    this.fetcher = options.fetcher ?? ((url, init) => fetch(url, init));
    this.sleep = options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    this.retries = options.retries ?? 3;
  }

  get accountEmail(): string {
    return this.tokens.account.client_email;
  }

  async spreadsheet(id: string): Promise<SpreadsheetInfo> {
    const fields = "properties.title,sheets.properties(sheetId,title,hidden,gridProperties(rowCount,columnCount))";
    const json = (await this.send(id, `${encodeURIComponent(id)}?fields=${encodeURIComponent(fields)}`)) as {
      properties?: { title?: string };
      sheets?: { properties?: Record<string, unknown> }[];
    };
    const tabs = (json.sheets ?? []).map((sheet) => {
      const properties = sheet.properties ?? {};
      const grid = (properties.gridProperties ?? {}) as Record<string, unknown>;
      return {
        sheetId: Number(properties.sheetId ?? 0),
        title: String(properties.title ?? ""),
        hidden: properties.hidden === true,
        rowCount: Number(grid.rowCount ?? 0),
        columnCount: Number(grid.columnCount ?? 0),
      };
    });
    return { title: json.properties?.title ?? "Untitled", tabs };
  }

  /** Formatted values of each range, in the order asked. */
  async batchGet(id: string, ranges: readonly string[]): Promise<Grid[]> {
    if (ranges.length === 0) return [];
    const query = ranges.map((range) => `ranges=${encodeURIComponent(range)}`);
    query.push("valueRenderOption=FORMATTED_VALUE", "majorDimension=ROWS");
    const json = (await this.send(id, `${encodeURIComponent(id)}/values:batchGet?${query.join("&")}`)) as {
      valueRanges?: { values?: unknown[][] }[];
    };
    return ranges.map((_, index) => {
      const values = json.valueRanges?.[index]?.values ?? [];
      return values.map((row) => (Array.isArray(row) ? row.map(cellText) : []));
    });
  }

  async batchUpdate(id: string, requests: readonly SheetRequest[]): Promise<void> {
    if (requests.length === 0) return;
    await this.send(id, `${encodeURIComponent(id)}:batchUpdate`, "POST", JSON.stringify({ requests }));
  }

  private async send(id: string, path: string, method = "GET", body?: string): Promise<unknown> {
    let attempt = 0;
    let reauthenticated = false;
    for (;;) {
      const token = await this.tokens.accessToken();
      const headers: Record<string, string> = { Authorization: `Bearer ${token}` };
      if (body !== undefined) headers["Content-Type"] = "application/json";
      let response: Response;
      try {
        response = await this.fetcher(BASE + path, { method, headers, body });
      } catch {
        throw new SheetError("Could not reach Google Sheets. Check your connection.", "network");
      }
      if ((response.status === 429 || response.status >= 500) && attempt < this.retries) {
        attempt++;
        await this.sleep(500 * 2 ** attempt);
        continue;
      }
      if (response.status === 401 && !reauthenticated) {
        reauthenticated = true;
        this.tokens.reset();
        continue;
      }
      let json: unknown = null;
      try {
        json = await response.json();
      } catch {
        json = null;
      }
      if (response.ok) return json;
      throw this.error(id, response.status, json);
    }
  }

  private error(id: string, status: number, json: unknown): SheetError {
    const error = (json as { error?: { message?: string; status?: string } } | null)?.error;
    const message = error?.message ?? `HTTP ${status}`;
    switch (status) {
      case 401:
        return new SheetError(`Google did not accept the sign-in: ${message}`, "auth");
      case 403:
        if (/has not been used|is disabled|SERVICE_DISABLED|API has not been enabled/i.test(message)) {
          return new SheetError(
            "The Google Sheets API is not enabled for the service account's Cloud project. Enable it in the Google Cloud console, wait a minute and try again.",
            "access",
          );
        }
        return new SheetError(`No access to the spreadsheet. Share the sheet with ${this.accountEmail} as an editor.`, "access");
      case 404:
        return new SheetError(`Spreadsheet not found. Check the link in Settings (id ${id}).`, "not-found");
      case 429:
        return new SheetError("Google Sheets is rate limiting requests. Wait a moment and try again.", "rate-limited");
      default:
        return new SheetError(status >= 500 ? `Google Sheets had a problem (${status}). Try again.` : message, "server");
    }
  }
}

function cellText(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number") return String(value);
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
  return "";
}
