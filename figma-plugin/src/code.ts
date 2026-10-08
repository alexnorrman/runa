/**
 * Runa plugin main thread: selection, node inspection, plugin data, client storage, fonts.
 * All network access, crypto and rendering live in the UI iframe (src/ui).
 */
import { parseFigmaUrl } from "./shared/figma-url";
import {
  MAX_LAYERS, PLUGIN_DATA, SETTINGS_STORAGE_KEY,
  type CapturedContext, type FileInfo, type MainRequests, type MainToUi, type RequestKind, type Settings, type TextLayer, type UiToMain,
} from "./shared/messages";

figma.showUI(__html__, { width: 360, height: 560, themeColors: true });

function post(message: MainToUi): void {
  figma.ui.postMessage(message);
}

// MARK: file

function fileInfo(): FileInfo {
  const apiKey = typeof figma.fileKey === "string" && figma.fileKey.length > 0 ? figma.fileKey : null;
  if (apiKey) return { fileKey: apiKey, fileName: figma.root.name, fromApi: true };
  const stored = figma.root.getPluginData(PLUGIN_DATA.fileUrl);
  const parsed = stored ? parseFigmaUrl(stored) : undefined;
  return { fileKey: parsed ? parsed.fileKey : null, fileName: figma.root.name, fromApi: false };
}

// MARK: node inspection

function pageOf(node: BaseNode): PageNode | null {
  let current: BaseNode | null = node;
  while (current && current.type !== "PAGE") current = current.parent;
  return current && current.type === "PAGE" ? current : null;
}

/** Ancestors from the node's parent up to (not including) the page. */
function ancestors(node: SceneNode): SceneNode[] {
  const list: SceneNode[] = [];
  let current = node.parent;
  while (current && current.type !== "PAGE" && current.type !== "DOCUMENT") {
    list.push(current as SceneNode);
    current = current.parent;
  }
  return list;
}

/** The top-level frame under the page: the outermost ancestor that is not a section. */
function topFrame(node: SceneNode): SceneNode | null {
  const chain = ancestors(node);
  for (let index = chain.length - 1; index >= 0; index--) {
    const candidate = chain[index]!;
    if (candidate.type !== "SECTION") return candidate;
  }
  return null;
}

function link(node: TextNode): { key?: string; keyId?: string } {
  const key = node.getPluginData(PLUGIN_DATA.key);
  const keyId = node.getPluginData(PLUGIN_DATA.keyId);
  const result: { key?: string; keyId?: string } = {};
  if (key) result.key = key;
  if (keyId) result.keyId = keyId;
  return result;
}

function describe(node: TextNode): TextLayer {
  const frame = topFrame(node);
  const page = pageOf(node);
  const size = node.hasMissingFont ? undefined : fontSize(node);
  return {
    id: node.id,
    name: node.name,
    characters: node.characters,
    ...link(node),
    frame: frame ? frame.name : "",
    page: page ? page.name : "",
    hasMissingFont: node.hasMissingFont,
    ...(size === undefined ? {} : { fontSize: round(size) }),
    containers: ancestors(node).slice(0, 3).map((ancestor) => ancestor.name),
  };
}

/** Text layers in the selection; frames and groups contribute their text descendants. */
function selectedTextNodes(): { nodes: TextNode[]; truncated: boolean } {
  const nodes: TextNode[] = [];
  const seen: { [id: string]: true } = {};
  let truncated = false;
  const add = (node: TextNode) => {
    if (seen[node.id]) return;
    if (nodes.length >= MAX_LAYERS) {
      truncated = true;
      return;
    }
    seen[node.id] = true;
    nodes.push(node);
  };
  for (const node of figma.currentPage.selection) {
    if (truncated) break;
    if (node.type === "TEXT") add(node);
    else if ("findAllWithCriteria" in node) {
      for (const text of node.findAllWithCriteria({ types: ["TEXT"] })) {
        add(text);
        if (truncated) break;
      }
    }
  }
  return { nodes, truncated };
}

let listedIds: { [id: string]: true } = {};

function sendSelection(): void {
  const { nodes, truncated } = selectedTextNodes();
  listedIds = {};
  for (const node of nodes) listedIds[node.id] = true;
  post({ type: "selection", layers: nodes.map(describe), truncated, selectionCount: figma.currentPage.selection.length });
}

function round(value: number): number {
  return Math.round(value * 100) / 100;
}

function center(node: SceneNode): { x: number; y: number } {
  const box = "absoluteBoundingBox" in node ? node.absoluteBoundingBox : null;
  if (box) return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
  const transform = node.absoluteTransform;
  return { x: transform[0][2] + node.width / 2, y: transform[1][2] + node.height / 2 };
}

const MAX_SIBLING_SCAN = 1000;

/** Up to 10 other texts in the same frame, nearest first, no duplicates, no blanks. */
function siblingTexts(node: TextNode, scope: SceneNode | null, cache: { [id: string]: TextNode[] }): string[] {
  if (!scope || !("findAllWithCriteria" in scope)) return [];
  let texts = cache[scope.id];
  if (!texts) {
    texts = scope.findAllWithCriteria({ types: ["TEXT"] }).slice(0, MAX_SIBLING_SCAN);
    cache[scope.id] = texts;
  }
  const origin = center(node);
  const own = node.characters.trim();
  const candidates = texts
    .filter((text) => text.id !== node.id && text.visible && text.characters.trim().length > 0 && text.characters.trim() !== own)
    .map((text) => {
      const point = center(text);
      return { text: text.characters, distance: Math.hypot(point.x - origin.x, point.y - origin.y) };
    })
    .sort((a, b) => a.distance - b.distance);
  const result: string[] = [];
  for (const candidate of candidates) {
    if (result.indexOf(candidate.text) >= 0) continue;
    result.push(candidate.text);
    if (result.length === 10) break;
  }
  return result;
}

function fontSize(node: TextNode): number | undefined {
  if (node.fontSize !== figma.mixed) return node.fontSize;
  const segments = node.getStyledTextSegments(["fontSize"]);
  return segments.length > 0 ? segments[0]!.fontSize : undefined;
}

async function textNode(nodeId: string): Promise<TextNode> {
  const node = await figma.getNodeByIdAsync(nodeId);
  if (!node || node.type !== "TEXT") throw new Error("That text layer no longer exists. Select it again.");
  return node;
}

async function captureContexts(nodeIds: string[]): Promise<CapturedContext[]> {
  const file = fileInfo();
  if (!file.fileKey) throw new Error("NEEDS_FILE_URL");
  const cache: { [id: string]: TextNode[] } = {};
  const contexts: CapturedContext[] = [];
  for (const nodeId of nodeIds) {
    const node = await textNode(nodeId);
    const frame = topFrame(node);
    const page = pageOf(node);
    const chain = ancestors(node).reverse();
    const start = frame ? chain.indexOf(frame) : chain.length;
    const path = chain
      .slice(start < 0 ? chain.length : start)
      .map((item) => item.name)
      .concat(node.name)
      .join("/");
    const context: CapturedContext = {
      nodeId: node.id,
      fileKey: file.fileKey,
      fileName: file.fileName,
      page: page ? page.name : "",
      frame: frame ? frame.name : "",
      frameId: frame ? frame.id : "",
      path,
      width: round(node.width),
      height: round(node.height),
      siblings: siblingTexts(node, frame ?? (node.parent && node.parent.type !== "PAGE" ? (node.parent as SceneNode) : null), cache),
    };
    const size = fontSize(node);
    if (size !== undefined) context.fontSize = round(size);
    contexts.push(context);
  }
  return contexts;
}

async function setText(nodeId: string, text: string): Promise<void> {
  const node = await textNode(nodeId);
  if (node.hasMissingFont) throw new Error("This layer uses a font that is not installed, so its text cannot be changed.");
  const fonts: FontName[] =
    node.characters.length > 0
      ? node.getRangeAllFontNames(0, node.characters.length)
      : node.fontName !== figma.mixed
        ? [node.fontName]
        : [];
  const unique: { [name: string]: FontName } = {};
  for (const font of fonts) unique[`${font.family}\u0000${font.style}`] = font;
  await Promise.all(Object.keys(unique).map((name) => figma.loadFontAsync(unique[name]!)));
  node.characters = text;
}

// MARK: requests

type Handlers = { [K in RequestKind]: (params: MainRequests[K]["params"]) => Promise<MainRequests[K]["result"]> };

const handlers: Handlers = {
  "save-settings": async ({ settings }) => {
    await figma.clientStorage.setAsync(SETTINGS_STORAGE_KEY, settings);
    return null;
  },
  "capture-context": async ({ nodeIds }) => captureContexts(nodeIds),
  "link-nodes": async ({ links }) => {
    for (const item of links) {
      const node = await textNode(item.nodeId);
      node.setPluginData(PLUGIN_DATA.key, item.key);
      node.setPluginData(PLUGIN_DATA.keyId, item.keyId);
    }
    sendSelection();
    return null;
  },
  "unlink-nodes": async ({ nodeIds }) => {
    for (const nodeId of nodeIds) {
      const node = await textNode(nodeId);
      node.setPluginData(PLUGIN_DATA.key, "");
      node.setPluginData(PLUGIN_DATA.keyId, "");
    }
    sendSelection();
    return null;
  },
  "set-text": async ({ nodeId, text }) => {
    await setText(nodeId, text);
    sendSelection();
    return null;
  },
  "set-file-url": async ({ url }) => {
    const parsed = parseFigmaUrl(url);
    if (!parsed) throw new Error("That is not a Figma file link. In Figma, use Share → Copy link and paste it here.");
    figma.root.setPluginData(PLUGIN_DATA.fileUrl, url.trim());
    const file = fileInfo();
    post({ type: "file", file });
    return file;
  },
  "refresh-selection": async () => {
    sendSelection();
    return null;
  },
  notify: async ({ message, error }) => {
    figma.notify(message, error ? { error: true } : undefined);
    return null;
  },
};

figma.ui.onmessage = async (message: UiToMain) => {
  if (message.type === "ready") {
    const stored = (await figma.clientStorage.getAsync(SETTINGS_STORAGE_KEY)) as Settings | undefined;
    post({ type: "init", settings: stored ?? null, file: fileInfo() });
    sendSelection();
    return;
  }
  if (message.type !== "request") return;
  try {
    const handler = handlers[message.kind] as (params: unknown) => Promise<unknown>;
    const result = await handler(message.params);
    post({ type: "response", id: message.id, ok: true, result });
  } catch (error) {
    post({ type: "response", id: message.id, ok: false, error: error instanceof Error ? error.message : String(error) });
  }
};

// MARK: events

let selectionTimer: number | undefined;
function scheduleSelection(delay: number): void {
  if (selectionTimer !== undefined) clearTimeout(selectionTimer);
  selectionTimer = setTimeout(() => {
    selectionTimer = undefined;
    sendSelection();
  }, delay);
}

function onNodeChange(event: NodeChangeEvent): void {
  for (const change of event.nodeChanges) {
    if (listedIds[change.id]) {
      scheduleSelection(250);
      return;
    }
  }
}

let watchedPage: PageNode = figma.currentPage;
watchedPage.on("nodechange", onNodeChange);

figma.on("selectionchange", () => scheduleSelection(40));
figma.on("currentpagechange", () => {
  watchedPage.off("nodechange", onNodeChange);
  watchedPage = figma.currentPage;
  watchedPage.on("nodechange", onNodeChange);
  scheduleSelection(0);
});
