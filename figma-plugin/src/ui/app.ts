/**
 * The plugin UI: state, actions and rendering. All network calls happen here (the iframe), the
 * main thread only touches the document. Rendering rebuilds small regions and restores focus.
 */
import { linkState, type KeyLike, type LinkInfo, type LinkState } from "../core/drift";
import { search, type SearchItem } from "../core/fuzzy";
import { keyNameProblem, suggestKey } from "../core/keys";
import { spreadsheetIdFrom } from "../sheets/api";
import { parseServiceAccount } from "../sheets/auth";
import { randomUuid } from "../sheets/hash";
import { sourceText, type KeyEntry, type SheetModel } from "../sheets/layout";
import { localeDisplayName } from "../sheets/locale";
import { SheetError } from "../sheets/types";
import { buildCreate, buildLink, buildPush, findKey, type CreateItem, type FigmaContextInput, type WriteContext } from "../sheets/writer";
import { buildFigmaUrl } from "../shared/figma-url";
import type { CapturedContext, FileInfo, MainToUi, Settings, TextLayer } from "../shared/messages";
import { normalizeLineBreaks } from "../shared/text";
import { Bridge } from "./bridge";
import { h, icon, mark, replaceChildren } from "./dom";
import { SheetSession } from "./session";

type BannerKind = "error" | "warning" | "info" | "success";

interface Banner {
  kind: BannerKind;
  text: string;
  action?: { label: string; run: () => void };
}

interface Draft {
  key: string;
  /** False while the key is still the suggestion (it then follows the text and the sheet). */
  edited: boolean;
  description: string;
}

interface KeyItem extends SearchItem {
  entry: KeyEntry;
}

const STATE_LABEL: Record<LinkState, string> = {
  unlinked: "Not linked",
  linked: "Linked",
  drift: "Text differs from the sheet",
  missing: "Key not in the sheet",
  unknown: "Linked (sheet not loaded)",
};

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function singleLine(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

function timeLabel(date: Date): string {
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

export class App {
  private readonly bridge = new Bridge();
  private view: "main" | "settings" = "main";
  private settings: Settings | null = null;
  private session: SheetSession | null = null;
  private file: FileInfo = { fileKey: null, fileName: "", fromApi: false };
  private layers: TextLayer[] = [];
  private truncated = false;
  private model: SheetModel | null = null;
  private keyItems: KeyItem[] = [];
  private loading = false;
  private loadError: string | null = null;
  private loadedAt: Date | null = null;
  private activeId: string | null = null;
  private readonly checked = new Set<string>();
  private readonly drafts = new Map<string, Draft>();
  private query = "";
  private resultIndex = 0;
  private busy: string | null = null;
  private banner: Banner | null = null;
  private bannerTimer: number | undefined;
  private pendingFileAction: (() => Promise<void>) | null = null;
  private initialized = false;

  private readonly header = h("div", { class: "header" });
  private readonly banners = h("div", { class: "banners" });
  private readonly mainView = h("div", { class: "view" });
  private readonly settingsView = h("div", { class: "view hidden" });
  private readonly footer = h("div", { class: "footer" });
  private panelSignature = "";

  constructor(private readonly root: HTMLElement) {
    replaceChildren(root, this.header, this.banners, this.mainView, this.settingsView, this.footer);
    this.bridge.onMessage((message) => this.receive(message));
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && this.view === "settings" && this.settings) {
        event.preventDefault();
        this.showMain();
      }
    });
    this.render();
    this.bridge.send({ type: "ready" });
  }

  // MARK: messages from the main thread

  private receive(message: MainToUi): void {
    switch (message.type) {
      case "init":
        this.initialized = true;
        this.file = message.file;
        this.applySettings(message.settings, true);
        if (!message.settings) this.showSettings();
        break;
      case "selection":
        this.layers = message.layers;
        this.truncated = message.truncated;
        for (const id of [...this.checked]) {
          if (!this.layers.some((layer) => layer.id === id && this.stateOf(layer) === "unlinked")) this.checked.delete(id);
        }
        if (!this.activeId || !this.layers.some((layer) => layer.id === this.activeId)) {
          this.activeId = this.layers[0]?.id ?? null;
          this.query = "";
          this.resultIndex = 0;
        }
        break;
      case "file":
        this.file = message.file;
        break;
      case "response":
        return;
    }
    this.render();
  }

  // MARK: settings and loading

  private applySettings(settings: Settings | null, load: boolean): void {
    this.settings = settings;
    this.session = null;
    if (!settings) return;
    const result = SheetSession.from(settings);
    if (!result.ok) {
      this.showBanner({ kind: "error", text: `Settings: ${result.error}`, action: { label: "Open settings", run: () => this.showSettings() } });
      return;
    }
    this.session = result.session;
    if (load) void this.reload();
  }

  private async reload(): Promise<void> {
    if (!this.session || this.loading) return;
    this.loading = true;
    this.render();
    try {
      this.setModel(await this.session.load());
      this.loadError = null;
      if (this.banner?.kind === "error" && this.banner.text.startsWith("Could not load")) this.banner = null;
    } catch (error) {
      this.loadError = messageOf(error);
      this.showBanner({ kind: "error", text: `Could not load the sheet. ${this.loadError}`, action: { label: "Retry", run: () => void this.reload() } });
    } finally {
      this.loading = false;
      this.render();
    }
  }

  private setModel(model: SheetModel): void {
    this.model = model;
    this.loadedAt = new Date();
    this.keyItems = model.keys.map((entry) => ({ key: entry.key, text: sourceText(entry), entry }));
    // Suggestions that were never edited follow the new key list.
    for (const [id, draft] of this.drafts) if (!draft.edited) this.drafts.delete(id);
  }

  // MARK: derived state

  private entryFor(link: LinkInfo): KeyEntry | undefined {
    if (!this.model) return undefined;
    const ref: { keyId?: string; key?: string } = {};
    if (link.keyId) ref.keyId = link.keyId;
    if (link.key) ref.key = link.key;
    return findKey(this.model, ref);
  }

  private stateOf(layer: TextLayer): LinkState {
    const toKeyLike = (link: LinkInfo): KeyLike | undefined => {
      const entry = this.entryFor(link);
      return entry && { id: entry.id, key: entry.key, forms: Object.values(entry.source).filter((text): text is string => !!text) };
    };
    const link: LinkInfo = {};
    if (layer.key) link.key = layer.key;
    if (layer.keyId) link.keyId = layer.keyId;
    return linkState(layer.characters, link, toKeyLike, !!this.model);
  }

  private takenKeys(): Set<string> {
    return new Set(this.model ? this.model.keys.map((entry) => entry.key) : []);
  }

  private draftFor(layer: TextLayer, taken: Set<string> = this.takenKeys()): Draft {
    let draft = this.drafts.get(layer.id);
    if (!draft) {
      const input: { text: string; frame?: string; page?: string; layerName?: string } = { text: layer.characters, layerName: layer.name };
      if (layer.frame) input.frame = layer.frame;
      if (layer.page) input.page = layer.page;
      draft = { key: suggestKey(input, taken), edited: false, description: "" };
      this.drafts.set(layer.id, draft);
    }
    return draft;
  }

  /** Why writing is not possible right now, or null. */
  private writeBlocker(): string | null {
    if (!this.session) return "Connect a sheet in Settings first.";
    if (!this.model) return this.loading ? "Loading the sheet…" : "Load the sheet first.";
    if (this.model.setupIssues.length > 0) return "Set the sheet up in the Runa Mac app first.";
    return null;
  }

  private writeContext(): WriteContext {
    return { actor: this.settings?.displayName.trim() || "Figma", now: new Date(), note: "figma" };
  }

  // MARK: actions

  private async run(label: string, action: () => Promise<void>): Promise<void> {
    if (this.busy) return;
    this.busy = label;
    this.banner = this.banner?.kind === "error" || this.banner?.kind === "warning" ? null : this.banner;
    this.render();
    try {
      await action();
    } catch (error) {
      if (error instanceof SheetError && error.code === "key-missing") void this.reload();
      this.showBanner({ kind: "error", text: messageOf(error) });
    } finally {
      this.busy = null;
      this.render();
    }
  }

  /** Captures design context; asks for the file link first when the file key is unknown. */
  private async contexts(nodeIds: string[], retry: () => Promise<void>): Promise<FigmaContextInput[] | null> {
    if (!this.file.fileKey) {
      this.pendingFileAction = retry;
      return null;
    }
    let captured: CapturedContext[];
    try {
      captured = await this.bridge.request("capture-context", { nodeIds });
    } catch (error) {
      if (messageOf(error) === "NEEDS_FILE_URL") {
        this.pendingFileAction = retry;
        return null;
      }
      throw error;
    }
    return captured.map((context) => {
      const input: FigmaContextInput = {
        url: buildFigmaUrl(context.fileKey, context.fileName, context.nodeId),
        fileKey: context.fileKey,
        nodeId: context.nodeId,
        page: context.page,
        frame: context.frame,
        frameId: context.frameId,
        path: context.path,
        width: context.width,
        height: context.height,
        siblings: context.siblings,
      };
      if (context.fontSize !== undefined) input.fontSize = context.fontSize;
      return input;
    });
  }

  private notify(message: string): void {
    void this.bridge.request("notify", { message }).catch(() => undefined);
  }

  private create(layers: TextLayer[]): Promise<void> {
    const label = layers.length === 1 ? "Creating key…" : `Creating ${layers.length} keys…`;
    return this.run(label, async () => {
      const session = this.session;
      const blocker = this.writeBlocker();
      if (!session || blocker) throw new Error(blocker ?? "Not connected.");
      const taken = this.takenKeys();
      const names = new Set<string>();
      for (const layer of layers) {
        const draft = this.draftFor(layer, taken);
        const key = draft.key.trim();
        const problem = keyNameProblem(key);
        if (problem) throw new Error(layers.length > 1 ? `${key || "(empty)"}: ${problem}` : problem);
        if (names.has(key)) throw new Error(`Two layers would get the key "${key}". Give each a different name.`);
        if (!normalizeLineBreaks(layer.characters)) throw new Error(`The layer "${layer.name}" has no text.`);
        names.add(key);
      }
      const contexts = await this.contexts(
        layers.map((layer) => layer.id),
        () => this.create(layers),
      );
      if (!contexts) return;
      const items: CreateItem[] = layers.map((layer, index) => {
        const draft = this.draftFor(layer, taken);
        const item: CreateItem = { id: randomUuid(), key: draft.key.trim(), text: normalizeLineBreaks(layer.characters), context: contexts[index]! };
        if (draft.description.trim()) item.description = draft.description.trim();
        return item;
      });
      const fresh = await session.readForWrite();
      const requests = buildCreate(fresh, items, this.writeContext());
      await session.write(requests);
      await this.bridge.request("link-nodes", { links: items.map((item, index) => ({ nodeId: layers[index]!.id, key: item.key, keyId: item.id })) });
      for (const layer of layers) {
        this.drafts.delete(layer.id);
        this.checked.delete(layer.id);
      }
      this.notify(items.length === 1 ? `Created ${items[0]!.key}` : `Created ${items.length} keys`);
      await this.reload();
    });
  }

  private link(layer: TextLayer, entry: KeyEntry, label = "Linking…"): Promise<void> {
    return this.run(label, async () => {
      const session = this.session;
      const blocker = this.writeBlocker();
      if (!session || blocker) throw new Error(blocker ?? "Not connected.");
      const contexts = await this.contexts([layer.id], () => this.link(layer, entry, label));
      if (!contexts) return;
      const fresh = await session.readForWrite();
      const result = buildLink(fresh, { keyId: entry.id, key: entry.key, context: contexts[0]! }, this.writeContext());
      await session.write(result.requests);
      await this.bridge.request("link-nodes", { links: [{ nodeId: layer.id, key: result.entry.key, keyId: result.entry.id }] });
      this.query = "";
      this.resultIndex = 0;
      this.notify(label === "Linking…" ? `Linked to ${result.entry.key}` : `Updated context for ${result.entry.key}`);
      await this.reload();
    });
  }

  private push(layer: TextLayer, entry: KeyEntry): Promise<void> {
    return this.run("Pushing text…", async () => {
      const session = this.session;
      const blocker = this.writeBlocker();
      if (!session || blocker) throw new Error(blocker ?? "Not connected.");
      const fresh = await session.readForWrite();
      const result = buildPush(fresh, { keyId: entry.id, key: entry.key, baseText: sourceText(entry), newText: normalizeLineBreaks(layer.characters) }, this.writeContext());
      if (result.kind === "conflict") {
        this.setModel(fresh);
        this.showBanner({
          kind: "warning",
          text: `"${entry.key}" changed in the sheet since you loaded it. Nothing was written; review the new text and try again.`,
        });
        return;
      }
      if (result.kind === "write") {
        await session.write(result.requests);
        this.notify(`Updated ${entry.key}`);
      } else {
        this.notify(`${entry.key} is already up to date`);
      }
      if (layer.keyId !== result.entry.id || layer.key !== result.entry.key) {
        await this.bridge.request("link-nodes", { links: [{ nodeId: layer.id, key: result.entry.key, keyId: result.entry.id }] });
      }
      await this.reload();
    });
  }

  private pull(layer: TextLayer, entry: KeyEntry): Promise<void> {
    return this.run("Updating layer…", async () => {
      await this.bridge.request("set-text", { nodeId: layer.id, text: sourceText(entry) });
      this.notify(`Text updated from ${entry.key}`);
    });
  }

  private unlink(layer: TextLayer): Promise<void> {
    return this.run("Unlinking…", async () => {
      await this.bridge.request("unlink-nodes", { nodeIds: [layer.id] });
      this.drafts.delete(layer.id);
    });
  }

  private async saveFileUrl(url: string, hint: HTMLElement): Promise<void> {
    try {
      this.file = await this.bridge.request("set-file-url", { url });
    } catch (error) {
      hint.textContent = messageOf(error);
      hint.className = "hint error";
      return;
    }
    const pending = this.pendingFileAction;
    this.pendingFileAction = null;
    this.render();
    if (pending) await pending();
  }

  // MARK: rendering

  private showBanner(banner: Banner): void {
    this.banner = banner;
    if (this.bannerTimer !== undefined) clearTimeout(this.bannerTimer);
    if (banner.kind === "success" || banner.kind === "info") {
      this.bannerTimer = window.setTimeout(() => {
        if (this.banner === banner) {
          this.banner = null;
          this.render();
        }
      }, 4000);
    }
    this.render();
  }

  private showSettings(): void {
    this.view = "settings";
    this.buildSettings();
    this.render();
    window.setTimeout(() => this.settingsView.querySelector<HTMLInputElement>("input")?.focus(), 0);
  }

  private showMain(): void {
    this.view = "main";
    this.panelSignature = "";
    this.render();
  }

  render(): void {
    this.renderHeader();
    this.renderBanners();
    this.mainView.classList.toggle("hidden", this.view !== "main");
    this.settingsView.classList.toggle("hidden", this.view !== "settings");
    if (this.view === "main") this.renderMain();
    this.renderFooter();
  }

  private renderHeader(): void {
    const model = this.model;
    let subtitle = "Not connected";
    if (model) subtitle = `${model.keys.length} ${model.keys.length === 1 ? "key" : "keys"} · source ${localeDisplayName(model.sourceLocale)} (${model.sourceLocale})`;
    else if (this.loading) subtitle = "Loading sheet…";
    else if (this.loadError) subtitle = "Could not load the sheet";
    else if (this.session) subtitle = "Sheet not loaded";
    const refresh = h(
      "button",
      {
        class: `icon-button${this.loading ? " spinning" : ""}`,
        title: "Refresh from the sheet",
        "aria-label": "Refresh",
        disabled: !this.session || this.loading || this.view === "settings",
        onclick: () => {
          void this.bridge.request("refresh-selection", {});
          void this.reload();
        },
      },
      icon("refresh"),
    );
    const settings = h(
      "button",
      {
        class: "icon-button",
        title: this.view === "settings" ? "Close settings" : "Settings",
        "aria-label": this.view === "settings" ? "Close settings" : "Settings",
        disabled: this.view === "settings" && !this.settings,
        onclick: () => (this.view === "settings" ? (this.settings ? this.showMain() : undefined) : this.showSettings()),
      },
      icon(this.view === "settings" ? "close" : "settings"),
    );
    replaceChildren(
      this.header,
      mark(18),
      h("div", { class: "titles" }, h("div", { class: "title" }, model?.projectName ?? "Runa"), h("div", { class: "subtitle" }, subtitle)),
      refresh,
      settings,
    );
  }

  private renderBanners(): void {
    const items: Banner[] = [];
    if (this.model && this.model.setupIssues.length > 0 && this.view === "main") {
      items.push({
        kind: "warning",
        text: `This sheet is missing ${this.model.setupIssues.join(", ")}. Open it once in the Runa Mac app to set it up, then refresh. Until then the plugin can only read.`,
      });
    }
    if (this.banner) items.push(this.banner);
    const dotClass: Record<BannerKind, string> = { error: "missing", warning: "drift", info: "unknown", success: "linked" };
    replaceChildren(
      this.banners,
      items.map((banner) =>
        h(
          "div",
          { class: "banner", role: banner.kind === "error" ? "alert" : "status" },
          h("span", { class: `dot ${dotClass[banner.kind]}` }),
          h("div", { class: "message" }, banner.text),
          banner.action && h("button", { class: "link-button banner-action", onclick: banner.action.run }, banner.action.label),
          banner === this.banner &&
            h(
              "button",
              {
                class: "icon-button",
                "aria-label": "Dismiss",
                onclick: () => {
                  this.banner = null;
                  this.render();
                },
              },
              icon("close", 12),
            ),
        ),
      ),
    );
  }

  private renderFooter(): void {
    const left = this.busy
      ? h("span", { class: "busy" }, h("span", { class: "spinner" }), this.busy)
      : this.loading
        ? h("span", { class: "busy" }, h("span", { class: "spinner" }), "Loading sheet…")
        : h("span", null, this.loadedAt ? `Loaded ${timeLabel(this.loadedAt)}` : this.session ? "" : "Runa");
    const right = h("span", null, this.settings?.displayName ? `as ${this.settings.displayName}` : "");
    replaceChildren(this.footer, left, right);
  }

  private renderMain(): void {
    if (!this.initialized) {
      replaceChildren(this.mainView);
      this.panelSignature = "";
      return;
    }
    if (!this.settings) {
      this.panelSignature = "";
      replaceChildren(
        this.mainView,
        h(
          "div",
          { class: "empty" },
          mark(28),
          h("div", { class: "empty-title" }, "Connect a Google Sheet"),
          h("div", { class: "empty-body" }, "Runa keeps your strings in a Google Sheet. Add the sheet's link and a service account key to start linking text layers."),
          h("button", { class: "button primary", onclick: () => this.showSettings() }, "Open settings"),
        ),
      );
      return;
    }
    const signature = this.mainSignature();
    if (signature === this.panelSignature) return;
    this.panelSignature = signature;
    preserveFocus(() => replaceChildren(this.mainView, this.renderSelectionHead(), this.renderLayers(), this.renderPanel()));
  }

  /** Everything the main view shows; it is rebuilt only when this changes. */
  private mainSignature(): string {
    return JSON.stringify([
      this.layers.map((layer) => [layer.id, layer.characters, layer.key, layer.keyId, this.stateOf(layer)]),
      this.activeId,
      [...this.checked],
      this.busy,
      this.loadedAt?.getTime(),
      this.loading,
      this.model?.setupIssues.length,
      this.file.fileKey,
      !!this.pendingFileAction,
      this.truncated,
    ]);
  }

  private renderSelectionHead(): HTMLElement {
    const unlinked = this.layers.filter((layer) => this.stateOf(layer) === "unlinked");
    const count = this.layers.length;
    const label = count === 0 ? "Selection" : `${count}${this.truncated ? "+" : ""} text ${count === 1 ? "layer" : "layers"}`;
    let toggle: HTMLElement | null = null;
    if (unlinked.length >= 2) {
      const allChecked = unlinked.every((layer) => this.checked.has(layer.id));
      toggle = h(
        "button",
        {
          class: "link-button",
          onclick: () => {
            if (allChecked) this.checked.clear();
            else for (const layer of unlinked) this.checked.add(layer.id);
            this.render();
          },
        },
        allChecked ? "Clear selection" : `Select ${unlinked.length} unlinked`,
      );
    }
    return h("div", { class: "section-head" }, h("span", { class: "count" }, label, this.truncated ? " (first 50)" : ""), toggle);
  }

  private renderLayers(): HTMLElement {
    const list = h("div", { class: "layers", role: "list" });
    const showChecks = this.layers.filter((layer) => this.stateOf(layer) === "unlinked").length >= 2;
    for (const layer of this.layers) {
      const state = this.stateOf(layer);
      const entry = this.entryFor(layer);
      const text = singleLine(layer.characters);
      let check: HTMLElement | null = null;
      if (showChecks) {
        check =
          state === "unlinked"
            ? h("input", {
                type: "checkbox",
                class: "checkbox",
                "aria-label": "Include in batch create",
                checked: this.checked.has(layer.id),
                onclick: (event: MouseEvent) => {
                  event.stopPropagation();
                  if (this.checked.has(layer.id)) this.checked.delete(layer.id);
                  else this.checked.add(layer.id);
                  this.render();
                },
              })
            : h("span", { class: "checkbox-spacer" });
      }
      const select = () => {
        if (this.activeId === layer.id && this.checked.size === 0) return;
        this.activeId = layer.id;
        this.checked.clear();
        this.query = "";
        this.resultIndex = 0;
        this.render();
      };
      list.appendChild(
        h(
          "div",
          {
            class: `layer${layer.id === this.activeId && this.checked.size === 0 ? " active" : ""}`,
            role: "listitem",
            tabindex: 0,
            "data-focus-id": `layer-${layer.id}`,
            title: layer.characters,
            onclick: select,
            onkeydown: (event: KeyboardEvent) => {
              if (event.key === "Enter" || event.key === " ") {
                event.preventDefault();
                select();
              } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                event.preventDefault();
                const sibling = (event.key === "ArrowDown" ? (event.currentTarget as HTMLElement).nextElementSibling : (event.currentTarget as HTMLElement).previousElementSibling) as HTMLElement | null;
                sibling?.focus();
              }
            },
          },
          check,
          h("span", { class: `dot ${state}`, title: STATE_LABEL[state] }),
          h("span", { class: "text" }, text || layer.name),
          h("span", { class: `key${state === "unlinked" ? " unlinked" : ""}` }, state === "unlinked" ? "Not linked" : (entry?.key ?? layer.key ?? "")),
        ),
      );
    }
    return list;
  }

  private renderPanel(): HTMLElement {
    if (this.layers.length === 0) {
      return h(
        "div",
        { class: "empty" },
        h("div", { class: "empty-title" }, "Select text to link"),
        h("div", { class: "empty-body" }, "Select text layers, or a frame to see the text inside it. Each layer can be linked to a string key in the sheet."),
      );
    }
    const panel = h("div", { class: "panel" });
    if (this.pendingFileAction) panel.appendChild(this.renderFilePrompt());
    if (this.checked.size > 0) {
      panel.appendChild(this.renderBatch());
      return panel;
    }
    const layer = this.layers.find((candidate) => candidate.id === this.activeId);
    if (!layer) return panel;
    const state = this.stateOf(layer);
    const entry = this.entryFor(layer);
    switch (state) {
      case "unlinked":
        panel.append(...this.renderUnlinked(layer));
        break;
      case "linked":
        if (entry) panel.append(...this.renderLinked(layer, entry));
        break;
      case "drift":
        if (entry) panel.append(...this.renderDrift(layer, entry));
        break;
      case "missing":
        panel.append(...this.renderMissing(layer));
        break;
      case "unknown":
        panel.append(...this.renderUnknown(layer));
        break;
    }
    return panel;
  }

  private title(state: LinkState, extra?: HTMLElement | null): HTMLElement {
    return h("div", { class: "panel-title" }, h("span", { class: `dot ${state}` }), h("span", null, STATE_LABEL[state]), h("span", { class: "spacer" }), extra);
  }

  private unlinkButton(layer: TextLayer): HTMLElement {
    return h("button", { class: "button ghost", disabled: !!this.busy, title: "Remove the link from this layer (the sheet is not changed)", onclick: () => void this.unlink(layer) }, "Unlink");
  }

  private renderFilePrompt(): HTMLElement {
    const hint = h("div", { class: "hint" }, "Only needed once per file.");
    const input = h("input", {
      class: "input",
      placeholder: "https://www.figma.com/design/…",
      "data-focus-id": "file-url",
      onkeydown: (event: KeyboardEvent) => {
        if (event.key === "Enter") void this.saveFileUrl(input.value, hint);
        if (event.key === "Escape") {
          this.pendingFileAction = null;
          this.render();
        }
      },
    });
    window.setTimeout(() => input.focus(), 0);
    return h(
      "div",
      { class: "card" },
      h("div", { class: "card-title" }, "Paste this file's link"),
      h("p", { class: "prose" }, "Runa stores a link to each layer so translators can see the design. Figma does not tell plugins the file's address, so copy it with Share → Copy link and paste it here."),
      input,
      hint,
      h(
        "div",
        { class: "row end" },
        h("button", { class: "button ghost", onclick: () => ((this.pendingFileAction = null), this.render()) }, "Cancel"),
        h("button", { class: "button primary", onclick: () => void this.saveFileUrl(input.value, hint) }, "Save link"),
      ),
    );
  }

  private renderUnlinked(layer: TextLayer): HTMLElement[] {
    const draft = this.draftFor(layer);
    const blocker = this.writeBlocker();
    const hint = h("div", { class: "hint" }, blocker ?? "Enter to create · Esc resets the suggestion");
    const createButton = h(
      "button",
      { class: "button primary", disabled: !!this.busy || !!blocker, onclick: () => void this.create([layer]) },
      "Create key",
      h("span", { class: "kbd" }, "↵"),
    );
    const validate = () => {
      const problem = draft.key.trim() ? keyNameProblem(draft.key.trim()) : "Enter a key name.";
      const exists = this.model?.byName.has(draft.key.trim());
      keyInput.classList.toggle("invalid", !!problem || !!exists);
      if (problem || exists) {
        hint.className = "hint error";
        hint.textContent = problem ?? "A key with this name exists. Link to it below, or pick another name.";
      } else {
        hint.className = "hint";
        hint.textContent = blocker ?? "Enter to create · Esc resets the suggestion";
      }
      createButton.toggleAttribute("disabled", !!this.busy || !!blocker || !!problem || !!exists);
    };
    const keyInput = h("input", {
      class: "input mono",
      value: draft.key,
      spellcheck: "false",
      autocomplete: "off",
      "aria-label": "Key name",
      "data-focus-id": `key-${layer.id}`,
      disabled: !!this.busy,
      oninput: () => {
        draft.key = keyInput.value;
        draft.edited = true;
        validate();
      },
      onkeydown: (event: KeyboardEvent) => {
        if (event.key === "Enter" && !createButton.hasAttribute("disabled")) {
          event.preventDefault();
          void this.create([layer]);
        } else if (event.key === "Escape") {
          event.preventDefault();
          this.drafts.delete(layer.id);
          const fresh = this.draftFor(layer);
          fresh.description = draft.description;
          this.panelSignature = "";
          this.render();
        }
      },
    });
    const description = h("input", {
      class: "input",
      value: draft.description,
      placeholder: "Optional: where and how this text is used",
      "aria-label": "Description",
      "data-focus-id": `description-${layer.id}`,
      disabled: !!this.busy,
      oninput: () => {
        draft.description = description.value;
      },
      onkeydown: (event: KeyboardEvent) => {
        if (event.key === "Enter" && !createButton.hasAttribute("disabled")) {
          event.preventDefault();
          void this.create([layer]);
        } else if (event.key === "Escape") {
          description.value = "";
          draft.description = "";
        }
      },
    });
    validate();
    return [
      this.title("unlinked"),
      h("div", { class: "quote" }, layer.characters || layer.name),
      h("div", { class: "field" }, h("label", { class: "label" }, "New key"), keyInput, hint),
      h("div", { class: "field" }, h("label", { class: "label" }, "Description for translators"), description),
      h("div", { class: "row end" }, createButton),
      h("div", { class: "divider" }, "or link an existing key"),
      ...this.renderSearch(layer),
    ];
  }

  private renderSearch(layer: TextLayer): HTMLElement[] {
    const results = h("div", { class: "results", role: "listbox" });
    const blocker = this.writeBlocker();
    const draw = () => {
      const matches = search(this.keyItems, this.query, 8);
      this.resultIndex = Math.min(this.resultIndex, Math.max(matches.length - 1, 0));
      replaceChildren(
        results,
        matches.map((match, index) =>
          h(
            "button",
            {
              class: `result${index === this.resultIndex ? " selected" : ""}`,
              role: "option",
              "aria-selected": index === this.resultIndex ? "true" : "false",
              disabled: !!this.busy || !!blocker,
              onclick: () => void this.link(layer, match.item.entry),
              onmousemove: () => {
                if (this.resultIndex !== index) {
                  this.resultIndex = index;
                  draw();
                }
              },
            },
            h("span", { class: "result-key" }, match.item.key),
            h("span", { class: "result-text" }, singleLine(match.item.text) || "No source text"),
          ),
        ),
      );
      empty.classList.toggle("hidden", !(this.query.trim() && matches.length === 0));
      empty.textContent = `No keys match "${this.query.trim()}".`;
      return matches;
    };
    const empty = h("div", { class: "no-results hidden" });
    const input = h("input", {
      class: "input",
      type: "search",
      value: this.query,
      placeholder: this.model ? `Search ${this.model.keys.length} keys by name or text` : "Load the sheet to search keys",
      spellcheck: "false",
      autocomplete: "off",
      "aria-label": "Search keys",
      "data-focus-id": `search-${layer.id}`,
      disabled: !this.model,
      oninput: () => {
        this.query = input.value;
        this.resultIndex = 0;
        draw();
      },
      onkeydown: (event: KeyboardEvent) => {
        const matches = search(this.keyItems, this.query, 8);
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault();
          if (matches.length === 0) return;
          const step = event.key === "ArrowDown" ? 1 : -1;
          this.resultIndex = (this.resultIndex + step + matches.length) % matches.length;
          draw();
          results.children[this.resultIndex]?.scrollIntoView({ block: "nearest" });
        } else if (event.key === "Enter") {
          event.preventDefault();
          const match = matches[this.resultIndex];
          if (match && !this.busy && !blocker) void this.link(layer, match.item.entry);
        } else if (event.key === "Escape") {
          if (this.query) {
            event.preventDefault();
            event.stopPropagation();
            this.query = "";
            input.value = "";
            this.resultIndex = 0;
            draw();
          }
        }
      },
    });
    draw();
    return [h("div", { class: "search" }, icon("search", 14), input), results, empty];
  }

  private renderLinked(layer: TextLayer, entry: KeyEntry): HTMLElement[] {
    const blocker = this.writeBlocker();
    const links = entry.figmaUrls.length;
    return [
      this.title("linked", this.unlinkButton(layer)),
      h(
        "dl",
        { class: "meta" },
        h("dt", null, "Key"),
        h("dd", null, h("span", { class: "key-name" }, entry.key)),
        h("dt", null, `Text (${this.model?.sourceLocale ?? ""})`),
        h("dd", null, sourceText(entry) || "No source text"),
        entry.description && [h("dt", null, "Description"), h("dd", null, entry.description)],
        h("dt", null, "Figma links"),
        h("dd", null, links === 0 ? "None yet" : `${links} ${links === 1 ? "layer" : "layers"}`),
        entry.isPlural && [h("dt", null, "Plural"), h("dd", null, "Forms are edited in the Runa app")],
      ),
      h(
        "div",
        { class: "row" },
        h(
          "button",
          {
            class: "button",
            disabled: !!this.busy || !!blocker,
            title: "Write this layer's link, size, path and nearby texts to the sheet again",
            onclick: () => void this.link(layer, entry, "Updating context…"),
          },
          icon("link", 14),
          "Update design context",
        ),
      ),
    ];
  }

  private renderDrift(layer: TextLayer, entry: KeyEntry): HTMLElement[] {
    const blocker = this.writeBlocker();
    const locale = this.model?.sourceLocale ?? "";
    const pushBlocked = entry.isPlural ? "Plural keys are edited in the Runa app." : blocker;
    return [
      this.title("drift", this.unlinkButton(layer)),
      h("div", { class: "key-name" }, entry.key),
      h("div", null, h("div", { class: "quote-label" }, "In Figma"), h("div", { class: "quote" }, layer.characters)),
      h("div", null, h("div", { class: "quote-label" }, `In the sheet (${locale})`), h("div", { class: "quote" }, sourceText(entry) || "Empty")),
      h(
        "div",
        { class: "row wrap" },
        h(
          "button",
          {
            class: "button primary",
            disabled: !!this.busy || !!pushBlocked,
            title: pushBlocked ?? "Write the Figma text to the sheet",
            onclick: () => void this.push(layer, entry),
          },
          icon("arrowUp", 14),
          "Push to sheet",
        ),
        h(
          "button",
          {
            class: "button",
            disabled: !!this.busy || layer.hasMissingFont || !sourceText(entry),
            title: layer.hasMissingFont ? "This layer uses a font that is not installed" : "Replace the layer's text with the sheet's",
            onclick: () => void this.pull(layer, entry),
          },
          icon("arrowDown", 14),
          "Pull into Figma",
        ),
      ),
      pushBlocked
        ? h("div", { class: "hint" }, pushBlocked)
        : h("div", { class: "hint" }, "Push writes the Figma text to the sheet; translations are flagged for review. Pull replaces the layer's text."),
    ];
  }

  private renderMissing(layer: TextLayer): HTMLElement[] {
    return [
      this.title("missing", this.unlinkButton(layer)),
      h("p", { class: "prose" }, `This layer is linked to "${layer.key ?? layer.keyId ?? ""}", which is no longer in the sheet. Link it to another key or unlink it.`),
      ...this.renderSearch(layer),
    ];
  }

  private renderUnknown(layer: TextLayer): HTMLElement[] {
    return [
      this.title("unknown", this.unlinkButton(layer)),
      h("div", { class: "key-name" }, layer.key ?? layer.keyId ?? ""),
      h("p", { class: "prose" }, this.loading ? "Loading the sheet…" : "Load the sheet to check this link."),
    ];
  }

  private renderBatch(): HTMLElement {
    const layers = this.layers.filter((layer) => this.checked.has(layer.id));
    const taken = this.takenKeys();
    for (const layer of layers) {
      const draft = this.draftFor(layer, taken);
      // Keep suggestions unique within the batch.
      if (!draft.edited && taken.has(draft.key)) {
        this.drafts.delete(layer.id);
      }
      taken.add(this.draftFor(layer, taken).key);
    }
    const blocker = this.writeBlocker();
    const hint = h("div", { class: "hint" }, blocker ?? "Each layer's text becomes the source text of its key.");
    const createButton = h(
      "button",
      { class: "button primary", disabled: !!this.busy || !!blocker, onclick: () => void this.create(layers) },
      `Create ${layers.length} ${layers.length === 1 ? "key" : "keys"}`,
      h("span", { class: "kbd" }, "↵"),
    );
    const inputs: HTMLInputElement[] = [];
    const validate = () => {
      const seen = new Set<string>();
      let message: string | null = null;
      layers.forEach((layer, index) => {
        const key = this.draftFor(layer).key.trim();
        const problem = keyNameProblem(key) ?? (this.model?.byName.has(key) ? `"${key}" already exists.` : undefined) ?? (seen.has(key) ? `"${key}" is used twice.` : undefined);
        seen.add(key);
        inputs[index]?.classList.toggle("invalid", !!problem);
        if (problem && !message) message = problem;
      });
      hint.className = message ? "hint error" : "hint";
      hint.textContent = message ?? blocker ?? "Each layer's text becomes the source text of its key.";
      createButton.toggleAttribute("disabled", !!this.busy || !!blocker || !!message);
    };
    const rows = layers.map((layer) => {
      const draft = this.draftFor(layer);
      const input = h("input", {
        class: "input mono",
        value: draft.key,
        spellcheck: "false",
        autocomplete: "off",
        "aria-label": `Key for ${singleLine(layer.characters)}`,
        "data-focus-id": `batch-${layer.id}`,
        disabled: !!this.busy,
        oninput: () => {
          draft.key = input.value;
          draft.edited = true;
          validate();
        },
        onkeydown: (event: KeyboardEvent) => {
          if (event.key === "Enter" && !createButton.hasAttribute("disabled")) {
            event.preventDefault();
            void this.create(layers);
          } else if (event.key === "Escape") {
            event.preventDefault();
            this.checked.clear();
            this.render();
          }
        },
      });
      inputs.push(input);
      return h("div", { class: "batch-row" }, h("span", { class: "text", title: layer.characters }, singleLine(layer.characters) || layer.name), input);
    });
    validate();
    return h(
      "div",
      { class: "stack" },
      h(
        "div",
        { class: "panel-title" },
        h("span", { class: "dot unlinked" }),
        h("span", null, `Create ${layers.length} ${layers.length === 1 ? "key" : "keys"}`),
        h("span", { class: "spacer" }),
        h("button", { class: "button ghost", onclick: () => (this.checked.clear(), this.render()) }, "Cancel"),
      ),
      ...rows,
      hint,
      h("div", { class: "row end" }, createButton),
    );
  }

  // MARK: settings

  private buildSettings(): void {
    const current = this.settings;
    const sheetInput = h("input", {
      class: "input",
      value: current?.spreadsheet ?? "",
      placeholder: "https://docs.google.com/spreadsheets/d/…",
      spellcheck: "false",
      "aria-label": "Google Sheet link",
    });
    const nameInput = h("input", { class: "input", value: current?.displayName ?? "", placeholder: "For example Alex Norrman", "aria-label": "Your name" });
    const keyInput = h("textarea", {
      class: "textarea",
      placeholder: '{ "type": "service_account", "client_email": "…", "private_key": "…" }',
      spellcheck: "false",
      "aria-label": "Service account key JSON",
    });
    keyInput.value = current?.serviceAccountJson ?? "";
    const keyStatus = h("div");
    const status = h("div", { class: "hint" });
    const fileInput = h("input", {
      type: "file",
      accept: ".json,application/json",
      class: "hidden",
      onchange: async () => {
        const file = fileInput.files?.[0];
        if (!file) return;
        keyInput.value = await file.text();
        fileInput.value = "";
        updateKeyStatus();
      },
    });

    const updateKeyStatus = () => {
      const text = keyInput.value.trim();
      if (!text) {
        replaceChildren(keyStatus, h("div", { class: "hint" }, "Paste the JSON key, or choose the file you downloaded."));
        return;
      }
      const parsed = parseServiceAccount(text);
      if (!parsed.ok) {
        replaceChildren(keyStatus, h("div", { class: "hint error" }, parsed.error));
        return;
      }
      const email = parsed.account.client_email;
      replaceChildren(
        keyStatus,
        h("div", { class: "hint" }, "Share the sheet with this address as an editor:"),
        h(
          "div",
          { class: "account" },
          h("span", { class: "email" }, email),
          h(
            "button",
            {
              class: "icon-button",
              title: "Copy email",
              "aria-label": "Copy email",
              onclick: () => {
                copyText(email);
                this.notify("Email copied");
              },
            },
            icon("copy", 14),
          ),
        ),
      );
    };
    keyInput.addEventListener("input", updateKeyStatus);
    updateKeyStatus();

    const values = (): Settings => ({
      spreadsheet: sheetInput.value.trim(),
      serviceAccountJson: keyInput.value.trim(),
      displayName: nameInput.value.trim(),
    });
    const problem = (settings: Settings): string | null => {
      if (!spreadsheetIdFrom(settings.spreadsheet)) return "Paste the Google Sheet's link (or its id).";
      const parsed = parseServiceAccount(settings.serviceAccountJson);
      if (!parsed.ok) return parsed.error;
      return null;
    };
    const setStatus = (text: string, kind: "" | "error" | "ok" = "") => {
      status.textContent = text;
      status.className = `hint${kind ? ` ${kind}` : ""}`;
    };

    const testButton = h("button", { class: "button" }, "Test connection");
    testButton.addEventListener("click", async () => {
      const settings = values();
      const issue = problem(settings);
      if (issue) return setStatus(issue, "error");
      const result = SheetSession.from(settings);
      if (!result.ok) return setStatus(result.error, "error");
      testButton.setAttribute("disabled", "");
      setStatus("Connecting…");
      try {
        const model = await result.session.load();
        const setup = model.setupIssues.length > 0 ? ` Missing ${model.setupIssues.join(", ")}: set it up in the Runa Mac app.` : "";
        setStatus(`Connected to "${model.spreadsheetTitle}": ${model.keys.length} keys, source ${model.sourceLocale}.${setup}`, setup ? "error" : "ok");
      } catch (error) {
        setStatus(messageOf(error), "error");
      } finally {
        testButton.removeAttribute("disabled");
      }
    });

    const save = async () => {
      const settings = values();
      const issue = problem(settings) ?? (settings.displayName ? null : "Enter your name; it is written to the sheet's history.");
      if (issue) return setStatus(issue, "error");
      try {
        await this.bridge.request("save-settings", { settings });
      } catch (error) {
        return setStatus(messageOf(error), "error");
      }
      const changedSheet = this.settings?.spreadsheet !== settings.spreadsheet || this.settings?.serviceAccountJson !== settings.serviceAccountJson;
      if (changedSheet) {
        this.model = null;
        this.loadedAt = null;
        this.keyItems = [];
        this.loadError = null;
      }
      this.banner = null;
      this.applySettings(settings, changedSheet || !this.model);
      this.showMain();
    };
    const saveButton = h("button", { class: "button primary", onclick: () => void save() }, "Save");
    for (const input of [sheetInput, nameInput]) {
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") void save();
      });
    }

    replaceChildren(
      this.settingsView,
      h(
        "div",
        { class: "settings" },
        h("div", { class: "field" }, h("label", { class: "label" }, "Google Sheet"), sheetInput, h("div", { class: "hint" }, "The sheet's link from the address bar. Set the sheet up in the Runa Mac app first.")),
        h("div", { class: "field" }, h("label", { class: "label" }, "Your name"), nameInput, h("div", { class: "hint" }, "Written to the sheet's history next to your changes.")),
        h(
          "div",
          { class: "field" },
          h(
            "div",
            { class: "row" },
            h("label", { class: "label" }, "Service account key"),
            h("span", { class: "spacer" }),
            h("button", { class: "link-button", onclick: () => fileInput.click() }, "Choose JSON file…"),
          ),
          keyInput,
          fileInput,
          keyStatus,
        ),
        h(
          "p",
          { class: "prose" },
          "Runa signs in to Google as a service account, so there is no Google login. Create one in the Google Cloud console with the Sheets API enabled, download its JSON key, and share the sheet with its email as an editor. The key is stored only on this computer, in Figma's plugin storage.",
        ),
        h("div", { class: "row" }, testButton, h("span", { class: "spacer" }), this.settings ? h("button", { class: "button ghost", onclick: () => this.showMain() }, "Cancel") : null, saveButton),
        status,
      ),
    );
  }
}

/** Focus that could not be restored because its element was disabled (while an action ran). */
let deferredFocus: string | null = null;

/** Rebuilds DOM while keeping keyboard focus and the caret on the element with the same data-focus-id. */
function preserveFocus(rebuild: () => void): void {
  const active = document.activeElement as HTMLElement | null;
  const id = active?.dataset?.focusId ?? (!active || active === document.body ? deferredFocus : null);
  let start: number | null = null;
  let end: number | null = null;
  if (active instanceof HTMLInputElement && active.type !== "checkbox") {
    try {
      start = active.selectionStart;
      end = active.selectionEnd;
    } catch {
      start = end = null;
    }
  }
  rebuild();
  if (!id) return;
  const next = document.querySelector<HTMLElement>(`[data-focus-id="${CSS.escape(id)}"]`);
  if (next && (next as HTMLInputElement).disabled) {
    deferredFocus = id;
    return;
  }
  deferredFocus = null;
  if (!next) return;
  next.focus();
  if (next instanceof HTMLInputElement && start !== null && end !== null) {
    try {
      next.setSelectionRange(start, end);
    } catch {
      // Some input types do not support selection.
    }
  }
}

function copyText(text: string): void {
  const fallback = () => {
    const area = h("textarea", { class: "hidden-copy" });
    area.value = text;
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    try {
      document.execCommand("copy");
    } finally {
      area.remove();
    }
  };
  if (navigator.clipboard?.writeText) navigator.clipboard.writeText(text).catch(fallback);
  else fallback();
}
