/**
 * The typed message protocol between the plugin main thread (src/code.ts: selection, nodes,
 * plugin data, client storage, fonts) and the UI iframe (src/ui: network, crypto, rendering).
 */

/** Per-user settings, kept in `figma.clientStorage` on this machine. */
export interface Settings {
  /** Google Sheets link or bare spreadsheet id. */
  spreadsheet: string;
  /** The service account key file, as JSON text. */
  serviceAccountJson: string;
  /** Written as `actor` in `_history` and `linkedBy` in `_context`. */
  displayName: string;
}

/** A text layer in the selection, as the UI lists it. */
export interface TextLayer {
  id: string;
  name: string;
  characters: string;
  /** `runa.key` plugin data, if linked. */
  key?: string;
  /** `runa.keyId` plugin data, if linked. */
  keyId?: string;
  /** Top-level frame the layer sits in ("" when none). */
  frame: string;
  page: string;
  hasMissingFont: boolean;
}

/** Design context of a layer, captured right before a link is written. */
export interface CapturedContext {
  nodeId: string;
  fileKey: string;
  fileName: string;
  page: string;
  frame: string;
  /** Node id of the top-level frame ("" when the text is not inside a frame). */
  frameId: string;
  path: string;
  width: number;
  height: number;
  fontSize?: number;
  /** Other texts in the same top-level frame, nearest first (at most 10). */
  siblings: string[];
}

export interface FileInfo {
  /** The file key when known (`figma.fileKey`, or parsed from the link the user pasted). */
  fileKey: string | null;
  fileName: string;
  /** True when the key came from `figma.fileKey` (no need to ask for the link). */
  fromApi: boolean;
}

export interface NodeLink {
  nodeId: string;
  key: string;
  keyId: string;
}

/** Requests the UI makes to the main thread, and what each one answers. */
export interface MainRequests {
  "save-settings": { params: { settings: Settings }; result: null };
  "capture-context": { params: { nodeIds: string[] }; result: CapturedContext[] };
  "link-nodes": { params: { links: NodeLink[] }; result: null };
  "unlink-nodes": { params: { nodeIds: string[] }; result: null };
  "set-text": { params: { nodeId: string; text: string }; result: null };
  "set-file-url": { params: { url: string }; result: FileInfo };
  "refresh-selection": { params: Record<string, never>; result: null };
  notify: { params: { message: string; error?: boolean }; result: null };
}

export type RequestKind = keyof MainRequests;

export type UiToMain =
  | { type: "ready" }
  | { [K in RequestKind]: { type: "request"; id: number; kind: K; params: MainRequests[K]["params"] } }[RequestKind];

export type MainToUi =
  | { type: "init"; settings: Settings | null; file: FileInfo }
  | { type: "selection"; layers: TextLayer[]; truncated: boolean; selectionCount: number }
  | { type: "file"; file: FileInfo }
  | { type: "response"; id: number; ok: true; result: unknown }
  | { type: "response"; id: number; ok: false; error: string };

/** Plugin data keys on text nodes and on the document. */
export const PLUGIN_DATA = {
  key: "runa.key",
  keyId: "runa.keyId",
  fileUrl: "runa.fileUrl",
} as const;

export const SETTINGS_STORAGE_KEY = "runa.settings";
export const MAX_LAYERS = 50;
