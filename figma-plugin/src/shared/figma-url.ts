import { asciiFold } from "./text";

/**
 * Figma node links, in the format the Runa sheet stores:
 * `https://www.figma.com/design/<fileKey>/<file-name-slug>?node-id=<id with ":" as "-">`.
 * Parsed with regular expressions because the plugin main thread has no `URL` class.
 */

export interface FigmaLink {
  fileKey: string;
  /** API form, `12:34`. Undefined when the link has no node. */
  nodeId?: string;
}

const KINDS = ["design", "file", "proto", "board"];

export function parseFigmaUrl(input: string): FigmaLink | undefined {
  const match = /^https?:\/\/([^/?#\s]+)(\/[^?#\s]*)?(\?[^#\s]*)?/i.exec(input.trim());
  if (!match) return undefined;
  const host = match[1]!.toLowerCase();
  if (host !== "figma.com" && !host.endsWith(".figma.com")) return undefined;
  const segments = (match[2] ?? "").split("/").filter((segment) => segment.length > 0);
  const kindIndex = segments.findIndex((segment) => KINDS.includes(segment));
  if (kindIndex < 0 || kindIndex + 1 >= segments.length) return undefined;
  const fileKey = segments[kindIndex + 1]!;
  let nodeId: string | undefined;
  for (const pair of (match[3] ?? "").replace(/^\?/, "").split("&")) {
    const [name, value] = pair.split("=");
    if (name === "node-id" && value) {
      nodeId = safeDecode(value.replace(/\+/g, " ")).replace(/-/g, ":");
      break;
    }
  }
  return nodeId ? { fileKey, nodeId } : { fileKey };
}

function safeDecode(text: string): string {
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}

/** "Checkout — Summary (v2)" → "Checkout-Summary-v2". Figma ignores this part of the link. */
export function fileNameSlug(name: string): string {
  const slug = asciiFold(name)
    .replace(/[^A-Za-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return slug || "Untitled";
}

export function buildFigmaUrl(fileKey: string, fileName: string, nodeId: string): string {
  return `https://www.figma.com/design/${fileKey}/${fileNameSlug(fileName)}?node-id=${encodeURIComponent(nodeId.replace(/:/g, "-"))}`;
}
