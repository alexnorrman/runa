import { beforeAll, describe, expect, it } from "vitest";
import {
  base64UrlFromBytes, createAssertion, parseServiceAccount, signingInput, TokenProvider, type ServiceAccount,
} from "../src/sheets/auth";
import { emsaPkcs1v15, modPow, parseRsaPrivateKey, pemToDer, signRS256, signWithFallback, signWithWebCrypto } from "../src/sheets/rsa";
import { utf8 } from "../src/sheets/sha256";

const subtle = globalThis.crypto.subtle;
const algorithm = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };

let pem = "";
let publicKey: CryptoKey;
let account: ServiceAccount;

function toPem(der: ArrayBuffer, label: string): string {
  const base64 = Buffer.from(der).toString("base64");
  const lines = base64.match(/.{1,64}/g) ?? [];
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`;
}

function base64UrlDecode(text: string): Buffer {
  return Buffer.from(text.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

beforeAll(async () => {
  const pair = await subtle.generateKey(
    { ...algorithm, modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]) },
    true,
    ["sign", "verify"],
  );
  pem = toPem(await subtle.exportKey("pkcs8", pair.privateKey), "PRIVATE KEY");
  publicKey = pair.publicKey;
  account = {
    type: "service_account",
    client_email: "runa-bot@my-project.iam.gserviceaccount.com",
    private_key: pem,
    private_key_id: "abc123",
    token_uri: "https://oauth2.googleapis.com/token",
  };
});

describe("RS256 signing", () => {
  it("produces the identical signature with WebCrypto and the BigInt fallback", async () => {
    for (const message of ["hello", "header.claims", "Hej då 👋".repeat(100)]) {
      const data = utf8(message);
      const web = await signWithWebCrypto(pem, data);
      const fallback = signWithFallback(pem, data);
      expect(fallback).toHaveLength(256);
      expect(Buffer.from(fallback).toString("hex")).toBe(Buffer.from(web).toString("hex"));
      expect(await subtle.verify(algorithm.name, publicKey, fallback as BufferSource, data as BufferSource)).toBe(true);
    }
  });

  it("falls back when crypto.subtle is missing", async () => {
    const original = Object.getOwnPropertyDescriptor(globalThis, "crypto")!;
    const data = utf8("no webcrypto here");
    const expected = await signWithWebCrypto(pem, data);
    const real = globalThis.crypto;
    Object.defineProperty(globalThis, "crypto", { value: { getRandomValues: real.getRandomValues.bind(real) }, configurable: true });
    expect(globalThis.crypto.subtle).toBeUndefined();
    try {
      expect(Buffer.from(await signRS256(pem, data)).toString("hex")).toBe(Buffer.from(expected).toString("hex"));
    } finally {
      Object.defineProperty(globalThis, "crypto", original);
    }
  });

  it("reads n and d from PKCS#8 and accepts escaped newlines from a pasted key", () => {
    const key = parseRsaPrivateKey(pemToDer(pem.replace(/\n/g, "\\n")).der);
    expect(key.size).toBe(256);
    // m^(d) then ^(e) gives m back.
    const m = BigInt(123456789);
    expect(modPow(modPow(m, key.d, key.n), BigInt(65537), key.n)).toBe(m);
  });

  it("builds the EMSA-PKCS1-v1_5 block", () => {
    const em = emsaPkcs1v15(utf8("x"), 256);
    expect([em[0], em[1], em[2]]).toEqual([0, 1, 0xff]);
    expect(em[256 - 52]).toBe(0);
    expect(Array.from(em.slice(256 - 51, 256 - 32))).toEqual([0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20]);
  });

  it("rejects things that are not PEM keys", () => {
    expect(() => signWithFallback("not a key", utf8("x"))).toThrow(/PEM/);
  });
});

describe("JWT assertion", () => {
  it("has the header and claims Google expects, and a valid signature", async () => {
    const jwt = await createAssertion(account, ["https://www.googleapis.com/auth/spreadsheets"], 1_790_000_000);
    const [header, claims, signature] = jwt.split(".");
    expect(JSON.parse(base64UrlDecode(header!).toString())).toEqual({ alg: "RS256", typ: "JWT", kid: "abc123" });
    expect(JSON.parse(base64UrlDecode(claims!).toString())).toEqual({
      iss: "runa-bot@my-project.iam.gserviceaccount.com",
      scope: "https://www.googleapis.com/auth/spreadsheets",
      aud: "https://oauth2.googleapis.com/token",
      iat: 1_790_000_000,
      exp: 1_790_003_600,
    });
    expect(signature).not.toMatch(/[+/=]/);
    const valid = await subtle.verify(algorithm.name, publicKey, new Uint8Array(base64UrlDecode(signature!)), utf8(`${header}.${claims}`) as BufferSource);
    expect(valid).toBe(true);
  });

  it("is the same JWT whichever signer is used", async () => {
    const web = await createAssertion(account, ["s"], 1000, signWithWebCrypto);
    const fallback = await createAssertion(account, ["s"], 1000, async (key, data) => signWithFallback(key, data));
    expect(fallback).toBe(web);
  });

  it("uses the default token endpoint when the key names another host", () => {
    const input = signingInput({ ...account, token_uri: "https://accounts.google.com/o/oauth2/token" }, ["s"], 0);
    expect(JSON.parse(base64UrlDecode(input.split(".")[1]!).toString()).aud).toBe("https://oauth2.googleapis.com/token");
  });

  it("encodes base64url without padding", () => {
    expect(base64UrlFromBytes(new Uint8Array([0xfb, 0xff]))).toBe("-_8");
  });
});

describe("service account keys", () => {
  it("validates type, client_email and private_key", () => {
    expect(parseServiceAccount("{").ok).toBe(false);
    expect(parseServiceAccount(JSON.stringify({ type: "authorized_user" }))).toMatchObject({ ok: false, error: expect.stringMatching(/authorized_user/) });
    expect(parseServiceAccount(JSON.stringify({ type: "service_account", private_key: "-----BEGIN PRIVATE KEY-----" }))).toMatchObject({
      ok: false,
      error: expect.stringMatching(/client_email/),
    });
    expect(parseServiceAccount(JSON.stringify({ type: "service_account", client_email: "a@b.c" }))).toMatchObject({ ok: false, error: expect.stringMatching(/private_key/) });
    const parsed = parseServiceAccount(JSON.stringify({ ...account, project_id: "p", extra: 1 }));
    expect(parsed.ok && parsed.account.client_email).toBe(account.client_email);
  });
});

describe("TokenProvider", () => {
  it("exchanges the assertion once and caches the token until shortly before expiry", async () => {
    let now = 1_790_000_000_000;
    const calls: { url: string; body: string }[] = [];
    const fetcher = async (url: string, init?: RequestInit) => {
      calls.push({ url, body: String(init?.body) });
      return new Response(JSON.stringify({ access_token: `token-${calls.length}`, expires_in: 3600 }), { status: 200 });
    };
    const provider = new TokenProvider(account, fetcher, () => now);
    expect(await Promise.all([provider.accessToken(), provider.accessToken()])).toEqual(["token-1", "token-1"]);
    now += 3000 * 1000;
    expect(await provider.accessToken()).toBe("token-1");
    now += 560 * 1000;
    expect(await provider.accessToken()).toBe("token-2");
    expect(calls).toHaveLength(2);
    expect(calls[0]!.url).toBe("https://oauth2.googleapis.com/token");
    expect(calls[0]!.body).toMatch(/^grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=[\w-]+\.[\w-]+\.[\w-]+$/);
  });

  it("explains a rejected key", async () => {
    const fetcher = async () => new Response(JSON.stringify({ error: "invalid_grant", error_description: "Invalid JWT Signature." }), { status: 400 });
    const provider = new TokenProvider(account, fetcher);
    await expect(provider.accessToken()).rejects.toThrow(/Invalid JWT Signature/);
  });
});
