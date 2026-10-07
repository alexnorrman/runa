/**
 * Runs the plugin main thread (src/code.ts) against a small fake of the Figma Plugin API, to
 * check selection listing, context capture, plugin data, the file-link fallback and font loading.
 */
import { beforeAll, describe, expect, it, vi } from "vitest";
import type { CapturedContext, MainToUi, TextLayer } from "../src/shared/messages";

type Fake = Record<string, unknown> & { id: string; name: string; type: string; parent: Fake | null; children?: Fake[] };

const MIXED = Symbol("mixed");
const posted: MainToUi[] = [];
const storage = new Map<string, unknown>();
const rootData = new Map<string, string>();
const nodes = new Map<string, Fake>();
let handler: (message: unknown) => Promise<void>;

function container(type: string, id: string, name: string, parent: Fake | null): Fake {
  const node: Fake = {
    type,
    id,
    name,
    parent,
    children: [],
    findAllWithCriteria: ({ types }: { types: string[] }) => {
      const found: Fake[] = [];
      const walk = (item: Fake) => {
        for (const child of item.children ?? []) {
          if (types.includes(child.type)) found.push(child);
          walk(child);
        }
      };
      walk(node);
      return found;
    },
  };
  parent?.children?.push(node);
  nodes.set(id, node);
  return node;
}

function text(id: string, characters: string, parent: Fake, x: number, y: number, fontSize: number | symbol = 14): Fake {
  const data = new Map<string, string>();
  const node: Fake = {
    type: "TEXT",
    id,
    name: characters,
    parent,
    characters,
    visible: true,
    hasMissingFont: false,
    width: 80.123,
    height: 20,
    fontSize,
    fontName: { family: "Inter", style: "Regular" },
    absoluteBoundingBox: { x, y, width: 80, height: 20 },
    absoluteTransform: [[1, 0, x], [0, 1, y]],
    getPluginData: (key: string) => data.get(key) ?? "",
    setPluginData: (key: string, value: string) => data.set(key, value),
    getRangeAllFontNames: () => [{ family: "Inter", style: "Regular" }, { family: "Inter", style: "Bold" }, { family: "Inter", style: "Regular" }],
    getStyledTextSegments: () => [{ fontSize: 18 }, { fontSize: 12 }],
  };
  parent.children!.push(node);
  nodes.set(id, node);
  return node;
}

const page = container("PAGE", "0:1", "Checkout", null);
const frame = container("FRAME", "1:1", "Checkout — Summary", page);
const footer = container("GROUP", "1:5", "Footer", frame);
const pay = text("1:10", "Pay now", footer, 0, 100);
text("1:11", "Total", frame, 0, 60);
text("1:12", "Checkout", frame, 0, 0);
text("1:13", "Total", frame, 200, 400); // duplicate text, further away
const loose = text("1:20", "Loose", page, 900, 900, MIXED);
Object.assign(page, { selection: [frame], on: vi.fn(), off: vi.fn() });

const figmaFake = {
  mixed: MIXED,
  fileKey: "FILE1" as string | undefined,
  showUI: vi.fn(),
  ui: {
    postMessage: (message: MainToUi) => posted.push(message),
    set onmessage(fn: (message: unknown) => Promise<void>) {
      handler = fn;
    },
  },
  currentPage: page,
  on: vi.fn(),
  notify: vi.fn(),
  root: { name: "Shop App", getPluginData: (key: string) => rootData.get(key) ?? "", setPluginData: (key: string, value: string) => rootData.set(key, value) },
  clientStorage: { getAsync: async (key: string) => storage.get(key), setAsync: async (key: string, value: unknown) => void storage.set(key, value) },
  getNodeByIdAsync: async (id: string) => nodes.get(id) ?? null,
  loadFontAsync: vi.fn(async () => undefined),
};

let nextId = 1;
async function request(kind: string, params: unknown): Promise<{ ok: boolean; result?: unknown; error?: string }> {
  const id = nextId++;
  await handler({ type: "request", id, kind, params });
  const response = posted.find((message) => message.type === "response" && message.id === id);
  return response as { ok: boolean; result?: unknown; error?: string };
}

function lastSelection(): TextLayer[] {
  const selection = [...posted].reverse().find((message) => message.type === "selection");
  return selection && selection.type === "selection" ? selection.layers : [];
}

beforeAll(async () => {
  (globalThis as Record<string, unknown>).figma = figmaFake;
  (globalThis as Record<string, unknown>).__html__ = "<html></html>";
  const modulePath = "../src/code.ts";
  await import(/* @vite-ignore */ modulePath);
});

describe("plugin main thread", () => {
  it("opens the UI with theme colours and answers ready with settings, file and selection", async () => {
    expect(figmaFake.showUI).toHaveBeenCalledWith("<html></html>", { width: 360, height: 560, themeColors: true });
    await handler({ type: "ready" });
    expect(posted[0]).toEqual({ type: "init", settings: null, file: { fileKey: "FILE1", fileName: "Shop App", fromApi: true } });
    const layers = lastSelection();
    expect(layers.map((layer) => layer.characters)).toEqual(["Pay now", "Total", "Checkout", "Total"]);
    expect(layers[0]).toMatchObject({ id: "1:10", frame: "Checkout — Summary", page: "Checkout", hasMissingFont: false });
    expect(layers[0]!.key).toBeUndefined();
  });

  it("captures the design context of a layer", async () => {
    const response = await request("capture-context", { nodeIds: ["1:10", "1:20"] });
    expect(response.ok).toBe(true);
    const [context, looseContext] = response.result as CapturedContext[];
    expect(context).toEqual({
      nodeId: "1:10",
      fileKey: "FILE1",
      fileName: "Shop App",
      page: "Checkout",
      frame: "Checkout — Summary",
      frameId: "1:1",
      path: "Checkout — Summary/Footer/Pay now",
      width: 80.12,
      height: 20,
      fontSize: 14,
      siblings: ["Total", "Checkout"],
    });
    // A text directly on the page has no frame; a mixed font size uses the first segment.
    expect(looseContext).toMatchObject({ frame: "", frameId: "", path: "Loose", fontSize: 18, siblings: [] });
  });

  it("stores and removes links as plugin data", async () => {
    expect((await request("link-nodes", { links: [{ nodeId: "1:10", key: "checkout.pay_now", keyId: "abc" }] })).ok).toBe(true);
    expect((pay.getPluginData as (key: string) => string)("runa.key")).toBe("checkout.pay_now");
    expect(lastSelection()[0]).toMatchObject({ key: "checkout.pay_now", keyId: "abc" });
    await request("unlink-nodes", { nodeIds: ["1:10"] });
    expect(lastSelection()[0]!.key).toBeUndefined();
  });

  it("loads every font of the layer before changing its text", async () => {
    expect((await request("set-text", { nodeId: "1:10", text: "Pay today" })).ok).toBe(true);
    expect(pay.characters).toBe("Pay today");
    expect(figmaFake.loadFontAsync).toHaveBeenCalledTimes(2);
    expect((await request("set-text", { nodeId: "9:99", text: "x" })).error).toMatch(/no longer exists/);
  });

  it("saves settings in client storage", async () => {
    const settings = { spreadsheet: "id", serviceAccountJson: "{}", displayName: "Alex" };
    await request("save-settings", { settings });
    expect(storage.get("runa.settings")).toEqual(settings);
  });

  it("asks for the file link when figma.fileKey is unavailable, and remembers it in the document", async () => {
    figmaFake.fileKey = undefined;
    expect((await request("capture-context", { nodeIds: ["1:10"] })).error).toBe("NEEDS_FILE_URL");
    expect((await request("set-file-url", { url: "https://example.com/x" })).ok).toBe(false);
    const saved = await request("set-file-url", { url: " https://www.figma.com/design/PASTED9/Shop-App?node-id=0-1&t=abc " });
    expect(saved.result).toEqual({ fileKey: "PASTED9", fileName: "Shop App", fromApi: false });
    expect(rootData.get("runa.fileUrl")).toBe("https://www.figma.com/design/PASTED9/Shop-App?node-id=0-1&t=abc");
    const [context] = (await request("capture-context", { nodeIds: ["1:10"] })).result as CapturedContext[];
    expect(context!.fileKey).toBe("PASTED9");
    figmaFake.fileKey = "FILE1";
  });

  it("lists at most 50 text layers", async () => {
    const big = container("FRAME", "5:1", "Big", page);
    for (let index = 0; index < 60; index++) text(`5:${index + 10}`, `Row ${index}`, big, 0, index * 20);
    (page as Record<string, unknown>).selection = [big];
    await request("refresh-selection", {});
    const selection = [...posted].reverse().find((message) => message.type === "selection");
    expect(selection).toMatchObject({ truncated: true });
    expect(lastSelection()).toHaveLength(50);
    void loose;
  });
});
