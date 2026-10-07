# Runa for Figma

The Figma plugin for [Runa](../docs/PLAN.md). It links Figma text layers to string keys in a Runa
Google Sheet and records where each key is used in the design. It only works with the
**source (main) language**: other languages, translation, review and language management live in
the Runa Mac app.

The plugin reads and writes the sheet exactly as described in
[`docs/SHEET_FORMAT.md`](../docs/SHEET_FORMAT.md), the same contract the Mac app and the CLI use.

## What it does

- **Lists the text layers in your selection** (select frames or groups to list the text inside
  them, up to 50). Each row has a status dot:
  - hollow: not linked
  - green: linked, and the Figma text matches the sheet's source text
  - yellow: drift, the Figma text and the sheet's source text differ
  - red: missing, the linked key is no longer in the sheet
  - grey: linked, but the sheet is not loaded yet

  Placeholders count as matching: a layer reading "3 items" matches `{count:int} items`.
- **Suggests a key** from the top-level frame and the text, in dot notation with snake_case
  segments: frame "Checkout — Summary" and text "Pay now" give `checkout_summary.pay_now`
  (ASCII only, at most four words of the text, `_2`, `_3`… when the name is taken). You can edit it.
- **Searches existing keys** by name and source text (fuzzy, top 8; ↑/↓ to move, Enter to link,
  Esc to clear).
- **Create** a key from a layer: a new random UUID, the layer's text as the source-language value,
  an optional description for translators and the layer's Figma link. Select several unlinked
  layers (checkboxes) to create all their keys at once.
- **Link** a layer to an existing key, or **Update design context** of a linked layer.
- **Push** the Figma text to the sheet when they differ (plain keys only; plural keys are edited in
  the Runa app), or **Pull** the sheet's text into the layer.
- **Unlink** removes the link from the layer only; the sheet is not changed.

The link is stored on the layer as plugin data (`runa.key` and `runa.keyId`), so it travels with
the file and every Runa user sees it.

### What gets written

Every action is **one** `spreadsheets.batchUpdate` call, which Google applies atomically, built
from a fresh read of the sheet made right before writing. Text is written with `stringValue`, so
values starting with `=` stay text.

| Action | `strings` | `_context` | `_status` | `_history` (note `figma`) |
|---|---|---|---|---|
| Create | appends the key row (`_id`, `key`, `description`, source text, `figma`) | appends the link's row | | `add-key`, `link-figma` |
| Link / Update design context | adds the URL to the key's `figma` cell (first row, one per line); writes the derived id into a blank `_id` | updates the row for this (key, URL), or appends it | | `link-figma` |
| Push | sets the source-language cell; writes the derived id into a blank `_id` | | records which source text existing translations belong to, so the Mac app flags them for review | `set-value` with before and after |

Push refuses to write when the sheet's value changed since the plugin loaded it ("changed in the
sheet since you loaded it") and reloads instead. Create refuses key names that already exist.

Each link captures the `_context` columns: `url`, `fileKey`, `nodeId` (`12:34`), `page`, `frame`
(the top-level frame under the page), `path` (layer names from that frame down to the text, joined
with `/`), `width`, `height`, `fontSize` (the first one if mixed), `siblings` (up to 10 other texts
in the same frame, nearest first, each at most 200 characters, as JSON), `linkedAt` (UTC),
`linkedBy` (your name) and `frameId` (the top-level frame's node id, which the Mac app renders as a
screenshot for translators). Links look like
`https://www.figma.com/design/<fileKey>/<file-name>?node-id=12-34`.

## Before you start

1. **Set the sheet up with the Runa Mac app.** The plugin needs the `strings` tab with `_id` and
   `figma` columns and the hidden `_context` and `_history` tabs. If they are missing it says so
   and only reads; it never creates tabs itself.
2. **A Google service account key.** Runa signs in to Google as a service account, so there is no
   Google login and nothing hosted by Runa:
   1. In the [Google Cloud console](https://console.cloud.google.com/), create (or pick) a project
      and enable the **Google Sheets API**.
   2. Create a **service account** (IAM & Admin → Service accounts) and add a **JSON key** to it.
      The downloaded file is the key. You can use the same key as the Mac app.
   3. **Share the sheet with the service account's email** (`…@….iam.gserviceaccount.com`) as an
      **Editor**, like sharing it with a colleague. The plugin shows the address in Settings.

## Install in Figma desktop

```sh
cd figma-plugin
npm install
npm run build
```

Then in the Figma desktop app: **Plugins → Development → Import plugin from manifest…** and pick
`figma-plugin/manifest.json`. Run it from **Plugins → Development → Runa**.

`npm run watch` rebuilds `dist/` on every change; re-run the plugin in Figma to pick it up.

The manifest's `id` (`runa-strings`) is a placeholder for local development. Figma assigns a real id
when a plugin is published; put that id in `manifest.json` then.

## Settings

Open with the gear icon. Stored per user and per computer with `figma.clientStorage`; nothing is
written to the Figma file.

- **Google Sheet**: the sheet's link from the address bar, or its id.
- **Your name**: written as `actor` in `_history` and `linkedBy` in `_context`, because every
  write arrives at Google as the service account.
- **Service account key**: paste the JSON or choose the file. It must have
  `"type": "service_account"`, `client_email` and `private_key`. The service account's email is
  shown so you know whom to share the sheet with.
- **Test connection** signs in, reads the sheet and reports what it found.

## The file link

A layer's link needs the Figma file's key. The manifest sets `"enablePrivatePluginApi": true`, so
`figma.fileKey` is available when the plugin runs as a development or private (organization)
plugin. When it is not (for example a public community plugin), the plugin asks once per file for
the file's link (**Share → Copy link**) and stores it in the document's plugin data
(`runa.fileUrl`), so other people using the plugin on that file are not asked again.

## How it is built

- `src/code.ts`: the plugin main thread. Selection, node inspection and context capture, plugin
  data, `figma.clientStorage`, font loading for Pull. No network.
- `src/ui/`: the UI iframe (plain DOM, no framework). All network calls and crypto happen here.
  `app.ts` holds state, actions and rendering; `session.ts` a connection to one sheet;
  `bridge.ts` the typed request/response messaging with the main thread.
- `src/shared/messages.ts`: the typed message protocol between the two.
- `src/sheets/`: the sheet contract.
  `hash.ts` (text hash and derived ids), `sha256.ts`, `locale.ts` (locale column detection),
  `layout.ts` (tabs into a model), `writer.ts` (pure functions that build the batchUpdate
  requests), `api.ts` (metadata, `values:batchGet`, `batchUpdate`, errors), `auth.ts`
  (service-account JWT and token cache), `rsa.ts` (RS256 signing), `repository.ts` (reads).
- `src/core/`: key suggestion, fuzzy search and drift detection.

RS256 signing uses WebCrypto when the iframe has `crypto.subtle`, and otherwise a dependency-free
fallback (PKCS#8 DER parsing and BigInt modular exponentiation). PKCS#1 v1.5 signatures are
deterministic, and the tests check that both paths produce identical bytes.

```sh
npm test           # vitest
npm run typecheck  # strict TypeScript for the UI/sheets code and, separately, the main thread
npm run build      # dist/code.js and a single self-contained dist/ui.html
npm run watch
```

## Limitations

- Source language only, by design. Plural keys can be linked and pulled but not pushed; edit
  their forms in the Runa app.
- Writes need a sheet set up by the Runa Mac app (`_id` and `figma` columns, `_context` and
  `_history` tabs).
- At most 50 text layers are listed per selection.
- Pull replaces the whole text of the layer; mixed styles inside the layer collapse to the first
  character's style (Figma's behaviour when setting `characters`). Layers with missing fonts
  cannot be pulled into.
- Text is compared exactly (apart from Figma's soft line breaks and placeholders), so a trailing
  space counts as drift.
- Unlinking or re-linking a layer does not remove its old link from the sheet.
- The service account key is stored in Figma's client storage on this computer, unencrypted like
  any other plugin data. Delete the key in the Google Cloud console to revoke it; removing the
  service account from the sheet's sharing cuts off every client at once.
- Re-reading the whole sheet before each write is simple and safe but grows with the sheet; very
  large sheets (tens of thousands of rows) will feel slower.
