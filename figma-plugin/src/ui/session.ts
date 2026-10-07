/** One connection to a Runa sheet: credentials, token cache, reads and atomic writes. */
import { SheetsApi, spreadsheetIdFrom } from "../sheets/api";
import { parseServiceAccount, TokenProvider, type ServiceAccount } from "../sheets/auth";
import type { SheetModel } from "../sheets/layout";
import { readSheet } from "../sheets/repository";
import type { SheetRequest } from "../sheets/writer";
import type { Settings } from "../shared/messages";

export type SessionResult = { ok: true; session: SheetSession } | { ok: false; error: string };

/** Token providers are kept per key so switching screens does not sign in again. */
const providers = new Map<string, TokenProvider>();

export class SheetSession {
  readonly api: SheetsApi;

  private constructor(
    readonly spreadsheetId: string,
    readonly account: ServiceAccount,
  ) {
    const cacheKey = `${account.client_email}|${account.private_key_id ?? account.private_key.length}`;
    let provider = providers.get(cacheKey);
    if (!provider || provider.account.private_key !== account.private_key) {
      provider = new TokenProvider(account);
      providers.set(cacheKey, provider);
    }
    this.api = new SheetsApi(provider);
  }

  static from(settings: Pick<Settings, "spreadsheet" | "serviceAccountJson">): SessionResult {
    const spreadsheetId = spreadsheetIdFrom(settings.spreadsheet);
    if (!spreadsheetId) return { ok: false, error: "Paste the Google Sheet's link (or its id)." };
    const parsed = parseServiceAccount(settings.serviceAccountJson);
    if (!parsed.ok) return { ok: false, error: parsed.error };
    return { ok: true, session: new SheetSession(spreadsheetId, parsed.account) };
  }

  get accountEmail(): string {
    return this.account.client_email;
  }

  /** `strings`, `_meta` and `_context`, for display. */
  load(): Promise<SheetModel> {
    return readSheet(this.api, this.spreadsheetId);
  }

  /** A fresh read right before a write: also `_status` and the `_history` header. */
  readForWrite(): Promise<SheetModel> {
    return readSheet(this.api, this.spreadsheetId, { forWrite: true });
  }

  /** One atomic `spreadsheets.batchUpdate`. */
  write(requests: SheetRequest[]): Promise<void> {
    return this.api.batchUpdate(this.spreadsheetId, requests);
  }
}
