/**
 * Service-account authentication: a self-signed RS256 JWT exchanged for an OAuth access token
 * at the key's `token_uri` (Google's two-legged flow), cached until shortly before it expires.
 */
import { signRS256 } from "./rsa";
import { utf8 } from "./sha256";
import { SheetError } from "./types";

export const SPREADSHEETS_SCOPE = "https://www.googleapis.com/auth/spreadsheets";
export const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";

export interface ServiceAccount {
  type: "service_account";
  client_email: string;
  private_key: string;
  private_key_id?: string;
  project_id?: string;
  token_uri?: string;
}

export type ParsedServiceAccount = { ok: true; account: ServiceAccount } | { ok: false; error: string };

/** Validates a pasted or picked key file. */
export function parseServiceAccount(json: string): ParsedServiceAccount {
  let value: unknown;
  try {
    value = JSON.parse(json);
  } catch {
    return { ok: false, error: "This is not valid JSON. Paste the whole key file you downloaded from the Google Cloud console." };
  }
  if (!value || typeof value !== "object") return { ok: false, error: "This is not a service account key file." };
  const record = value as Record<string, unknown>;
  if (record.type !== "service_account") {
    return { ok: false, error: `The key's type is "${String(record.type ?? "missing")}"; a service account key is needed.` };
  }
  if (typeof record.client_email !== "string" || !record.client_email.includes("@")) {
    return { ok: false, error: "The key file has no client_email." };
  }
  if (typeof record.private_key !== "string" || !record.private_key.includes("PRIVATE KEY")) {
    return { ok: false, error: "The key file has no private_key." };
  }
  const account: ServiceAccount = { type: "service_account", client_email: record.client_email, private_key: record.private_key };
  if (typeof record.private_key_id === "string") account.private_key_id = record.private_key_id;
  if (typeof record.project_id === "string") account.project_id = record.project_id;
  if (typeof record.token_uri === "string") account.token_uri = record.token_uri;
  return { ok: true, account };
}

/**
 * The token endpoint to use. The plugin may only reach oauth2.googleapis.com (manifest
 * `networkAccess`), which accepts every Google service-account key.
 */
export function tokenUri(account: ServiceAccount): string {
  const uri = account.token_uri;
  return uri && /^https:\/\/oauth2\.googleapis\.com\//.test(uri) ? uri : DEFAULT_TOKEN_URI;
}

export function base64UrlFromBytes(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64UrlFromJson(value: unknown): string {
  return base64UrlFromBytes(utf8(JSON.stringify(value)));
}

export type Signer = (pem: string, data: Uint8Array) => Promise<Uint8Array>;

/** The unsigned part of the assertion, `header.claims`, same fields and order as RunaCore. */
export function signingInput(account: ServiceAccount, scopes: readonly string[], nowSeconds: number): string {
  const header: Record<string, string> = { alg: "RS256", typ: "JWT" };
  if (account.private_key_id) header.kid = account.private_key_id;
  const claims = {
    iss: account.client_email,
    scope: scopes.join(" "),
    aud: tokenUri(account),
    iat: nowSeconds,
    exp: nowSeconds + 3600,
  };
  return `${base64UrlFromJson(header)}.${base64UrlFromJson(claims)}`;
}

export async function createAssertion(
  account: ServiceAccount,
  scopes: readonly string[],
  nowSeconds: number,
  signer: Signer = signRS256,
): Promise<string> {
  const input = signingInput(account, scopes, nowSeconds);
  let signature: Uint8Array;
  try {
    signature = await signer(account.private_key, utf8(input));
  } catch (error) {
    throw new SheetError(`The service account's private key could not be used: ${(error as Error).message}`, "auth");
  }
  return `${input}.${base64UrlFromBytes(signature)}`;
}

export type FetchLike = (url: string, init?: RequestInit) => Promise<Response>;

interface CachedToken {
  token: string;
  expiresAt: number;
}

/** Hands out access tokens for one service account, refreshing a minute before expiry. */
export class TokenProvider {
  private cached?: CachedToken;
  private pending?: Promise<string>;

  constructor(
    readonly account: ServiceAccount,
    private readonly fetcher: FetchLike = (url, init) => fetch(url, init),
    private readonly clock: () => number = () => Date.now(),
    private readonly signer: Signer = signRS256,
  ) {}

  async accessToken(): Promise<string> {
    if (this.cached && this.cached.expiresAt - 60_000 > this.clock()) return this.cached.token;
    this.pending ??= this.fetchToken().finally(() => {
      this.pending = undefined;
    });
    return this.pending;
  }

  /** Forget the token, for example after a 401. */
  reset(): void {
    this.cached = undefined;
  }

  private async fetchToken(): Promise<string> {
    const now = this.clock();
    const assertion = await createAssertion(this.account, [SPREADSHEETS_SCOPE], Math.floor(now / 1000), this.signer);
    const body = `grant_type=${encodeURIComponent("urn:ietf:params:oauth:grant-type:jwt-bearer")}&assertion=${assertion}`;
    let response: Response;
    try {
      response = await this.fetcher(tokenUri(this.account), {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body,
      });
    } catch {
      throw new SheetError("Could not reach Google to sign in. Check your connection.", "network");
    }
    let json: Record<string, unknown> = {};
    try {
      json = (await response.json()) as Record<string, unknown>;
    } catch {
      // Keep the empty object; the status code explains the failure.
    }
    if (!response.ok || typeof json.access_token !== "string") {
      const detail = String(json.error_description ?? json.error ?? `HTTP ${response.status}`);
      const hint = /invalid_grant|account not found|Invalid JWT/i.test(detail)
        ? " The key may have been deleted or the computer clock is off."
        : "";
      throw new SheetError(`Google rejected the service account key: ${detail}.${hint}`, "auth");
    }
    const lifetime = typeof json.expires_in === "number" ? json.expires_in : 3600;
    this.cached = { token: json.access_token, expiresAt: now + lifetime * 1000 };
    return json.access_token;
  }
}
