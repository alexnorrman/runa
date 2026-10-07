/**
 * RS256 signing (RSASSA-PKCS1-v1_5 with SHA-256).
 *
 * Two paths that produce identical bytes, because PKCS#1 v1.5 signatures are deterministic:
 * - WebCrypto (`crypto.subtle`), used when the iframe has it;
 * - a dependency-free fallback: parse the PKCS#8 DER for n and d, build the EMSA-PKCS1-v1_5
 *   encoding and compute m^d mod n with BigInt.
 */
import { sha256 } from "./sha256";

export interface RsaPrivateKey {
  n: bigint;
  d: bigint;
  /** Modulus length in bytes. */
  size: number;
}

// MARK: PEM and DER

/** Decodes the base64 body of a PEM block. Accepts literal "\n" sequences from a mangled paste. */
export function pemToDer(pem: string): { der: Uint8Array; label: string } {
  const text = pem.replace(/\\n/g, "\n");
  const match = /-----BEGIN ([A-Z ]+)-----([\s\S]*?)-----END \1-----/.exec(text);
  if (!match) throw new Error("The private key is not a PEM block.");
  return { der: base64ToBytes(match[2]!.replace(/[^A-Za-z0-9+/=]/g, "")), label: match[1]! };
}

export function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

interface Tlv {
  tag: number;
  start: number;
  end: number;
}

function readTlv(bytes: Uint8Array, offset: number): Tlv {
  const tag = bytes[offset];
  let length = bytes[offset + 1];
  if (tag === undefined || length === undefined) throw new Error("The private key is truncated.");
  let start = offset + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 4) throw new Error("The private key uses an unsupported length encoding.");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + (bytes[start + i] ?? 0);
    start += count;
  }
  const end = start + length;
  if (end > bytes.length) throw new Error("The private key is truncated.");
  return { tag, start, end };
}

/** The children of a constructed DER value. */
function children(bytes: Uint8Array, parent: Tlv): Tlv[] {
  const items: Tlv[] = [];
  let offset = parent.start;
  while (offset < parent.end) {
    const item = readTlv(bytes, offset);
    items.push(item);
    offset = item.end;
  }
  return items;
}

function bytesToBigInt(bytes: Uint8Array): bigint {
  let hex = "";
  for (const byte of bytes) hex += byte.toString(16).padStart(2, "0");
  return hex ? BigInt(`0x${hex}`) : BigInt(0);
}

const RSA_ENCRYPTION_OID = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01];

/** Reads n and d from a PKCS#8 PrivateKeyInfo (or a bare PKCS#1 RSAPrivateKey). */
export function parseRsaPrivateKey(der: Uint8Array): RsaPrivateKey {
  const outer = readTlv(der, 0);
  if (outer.tag !== 0x30) throw new Error("The private key is not a DER sequence.");
  let fields = children(der, outer);
  // PKCS#8: version, AlgorithmIdentifier (SEQUENCE), privateKey (OCTET STRING)
  if (fields.length >= 3 && fields[1]!.tag === 0x30 && fields[2]!.tag === 0x04) {
    const algorithm = children(der, fields[1]!)[0];
    const oid = algorithm ? Array.from(der.slice(algorithm.start, algorithm.end)) : [];
    if (oid.join(",") !== RSA_ENCRYPTION_OID.join(",")) throw new Error("The private key is not an RSA key.");
    const inner = der.slice(fields[2]!.start, fields[2]!.end);
    const rsa = readTlv(inner, 0);
    fields = children(inner, rsa);
    return fromRsaFields(inner, fields);
  }
  return fromRsaFields(der, fields);
}

function fromRsaFields(bytes: Uint8Array, fields: Tlv[]): RsaPrivateKey {
  // RSAPrivateKey: version, n, e, d, p, q, dp, dq, qinv
  if (fields.length < 4 || fields.slice(0, 4).some((field) => field.tag !== 0x02)) {
    throw new Error("The private key is not an RSA private key.");
  }
  const nField = fields[1]!;
  const n = bytesToBigInt(bytes.slice(nField.start, nField.end));
  const d = bytesToBigInt(bytes.slice(fields[3]!.start, fields[3]!.end));
  const size = Math.ceil(n.toString(16).length / 2);
  return { n, d, size };
}

// MARK: fallback signing

/** DigestInfo prefix for SHA-256 (RFC 8017, section 9.2, note 1). */
const SHA256_DIGEST_INFO = [0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20];

export function emsaPkcs1v15(data: Uint8Array, size: number): Uint8Array {
  const t = new Uint8Array([...SHA256_DIGEST_INFO, ...sha256(data)]);
  if (size < t.length + 11) throw new Error("The RSA key is too short.");
  const em = new Uint8Array(size).fill(0xff);
  em[0] = 0x00;
  em[1] = 0x01;
  em[size - t.length - 1] = 0x00;
  em.set(t, size - t.length);
  return em;
}

export function modPow(base: bigint, exponent: bigint, modulus: bigint): bigint {
  const zero = BigInt(0);
  const one = BigInt(1);
  let result = one;
  let b = base % modulus;
  let e = exponent;
  while (e > zero) {
    if (e & one) result = (result * b) % modulus;
    e >>= one;
    if (e > zero) b = (b * b) % modulus;
  }
  return result;
}

function bigIntToBytes(value: bigint, size: number): Uint8Array {
  const hex = value.toString(16).padStart(size * 2, "0");
  const out = new Uint8Array(size);
  for (let i = 0; i < size; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

export function signWithFallback(pem: string, data: Uint8Array): Uint8Array {
  const key = parseRsaPrivateKey(pemToDer(pem).der);
  const m = bytesToBigInt(emsaPkcs1v15(data, key.size));
  return bigIntToBytes(modPow(m, key.d, key.n), key.size);
}

// MARK: WebCrypto signing

export function hasWebCrypto(): boolean {
  const subtle = (globalThis as { crypto?: Crypto }).crypto?.subtle;
  return !!subtle && typeof subtle.importKey === "function" && typeof subtle.sign === "function";
}

export async function signWithWebCrypto(pem: string, data: Uint8Array): Promise<Uint8Array> {
  const { der, label } = pemToDer(pem);
  if (label !== "PRIVATE KEY") throw new Error("WebCrypto needs a PKCS#8 key.");
  const algorithm = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };
  const key = await globalThis.crypto.subtle.importKey("pkcs8", der as BufferSource, algorithm, false, ["sign"]);
  return new Uint8Array(await globalThis.crypto.subtle.sign(algorithm.name, key, data as BufferSource));
}

/** Signs with WebCrypto when available, otherwise (or if it fails) with the BigInt fallback. */
export async function signRS256(pem: string, data: Uint8Array): Promise<Uint8Array> {
  if (hasWebCrypto()) {
    try {
      return await signWithWebCrypto(pem, data);
    } catch {
      // Fall through: some sandboxes expose crypto.subtle but refuse to use it.
    }
  }
  return signWithFallback(pem, data);
}
