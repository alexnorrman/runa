# Runa — product and architecture plan

_Status: v2, 2026-10-07. Updated with Alex's answers to the v1 questions. Remaining small
decisions are in section 16. Implementation status is in section 0._

---

## 0. Implementation status (2026-10-07)

| Area | State |
|---|---|
| Core model, placeholders, CLDR plurals | Done, tested |
| Formats: String Catalog, .strings/.stringsdict, Android XML, i18next, ICU (export and import) | Done, round-trip tested; String Catalog output verified byte-identical against Xcode's `xcstringstool` |
| Import planner with conflict buckets | Done, tested; UI in the app and `runa import` |
| Backends: local JSON, Google Sheets (service account, atomic batch writes, per-cell conflicts, history) | Done; one contract test suite runs against both. Google Sheets is tested against an in-memory twin of the API; **not yet run against a live sheet** |
| AI: Claude, OpenAI, Gemini, OpenAI-compatible; validation and one retry | Done, tested with recorded request shapes; **not yet run against live APIs** |
| `runa` CLI and MCP server | Done; exercised end to end against a local project |
| Runa for Mac | Done: keys, inspector, languages, review, activity, import, export, translate, settings, onboarding, command palette. Visually checked in light and dark |
| Figma plugin | See figma-plugin/README.md |
| Distribution | CI and release workflows written; **untested until pushed to GitHub**. Sparkle updates, Homebrew tap, Figma Community listing and the GitHub backend are not started |

Deviations from the plan below: the app caches snapshots as JSON files instead of SwiftData
(simpler, same behaviour), and the glossary and style guides are stored per Mac rather than in
the sheet. The `_context` tab gained a `frameId` column so the app can screenshot the whole frame.

Runa is a local-first **Mac app** for managing UI strings across iOS, Android and web.
Strings live in a backend the user owns (Google Sheets first), a **Figma plugin** attaches a
string key and a design link to text layers in the main language, a **CLI with an MCP server**
pulls strings into codebases, and a cloud **AI provider of the user's choice** (Claude first)
drafts translations using the design context. Runa is a personal open-source project published
on GitHub for others to clone, build or download. Nothing is hosted by us and no accounts are
created with us: users bring their own Google sheet and their own AI API key.

---

## 1. Guiding decisions

1. **No server of ours, no accounts with us.** The backend the user picks is the only server.
   Everything else runs in the Mac app, inside the Figma plugin sandbox, or in the user's shell
   and CI. Credentials are always the user's own.
2. **One canonical string model.** String Catalogs, `strings.xml` and web JSON are projections
   of it, produced by converters with golden-file tests. Nothing platform-specific is stored.
3. **Two codebases, not three.** Swift for the app and the CLI/MCP binary (they share
   `RunaCore`), TypeScript for the Figma plugin (a thin backend client, no converters).
4. **Backend is not delivery.** A _backend_ is where truth lives. A _target_ is a platform file
   developers consume. The CLI or MCP writes targets into a repo; the developer commits as usual.
5. **Humans approve AI output.** Machine translations land as `machine` status and only become
   `approved` after someone reviews them in the app.
6. **The Figma plugin only knows the main language.** All languages, coverage warnings, AI
   translation and language management live in the Mac app.

---

## 2. System overview

```
 Figma plugin (TS, main language + design link) ──┐
                                                  ├──►  Backend: Google Sheet | local JSON | GitHub repo (later)
 runa CLI / runa mcp (Swift, in repo or CI) ──────┤                               ▲
        │                                         │                               │
        ▼                                         └──────────────────────── Runa for Mac (SwiftUI)
 Localizable.xcstrings                                                            │
 res/values-*/strings.xml                                                         ├── AI provider: Claude | OpenAI | Gemini | OpenAI-compatible
 locales/*.json                                                                   └── Figma REST (thumbnails for context)
```

---

## 3. Canonical model (`RunaCore`)

```
Project        id, name, sourceLocale, locales[], placeholderStyle, glossary[], styleGuide
StringKey      id (UUID), key, description, tags[], platforms[ios|android|web]?, isPlural,
               placeholders[], contexts[FigmaContext], createdAt, updatedAt
Translation    keyId, locale, value | pluralForms{zero,one,two,few,many,other},
               status: missing|machine|needsReview|approved, updatedAt, updatedBy
Placeholder    name, type: string|int|decimal, index (for positional formats)
FigmaContext   fileKey, nodeId, pageName, frameName, nodePath, url,
               box{w,h,fontSize} (fit budget), siblingTexts[], linkedAt
HistoryEntry   ts, actor, action, keyId, key, locale?, before?, after?
```

**Keys.** Dot-notation `screen.element.purpose` (`checkout.summary.title`). Converters adapt:
Android replaces `.` with `_` (dots are illegal in resource names); i18next can nest on dots or
stay flat (per target); String Catalogs accept any key.

**Placeholders.** Canonical form is named and typed: `{name}`, `{count:int}`, `{price:decimal}`.
Converters emit `%@` / `%lld` / `%.2f` for String Catalogs, `%1$s` / `%1$d` / `%1$.2f` for Android
(positional index by order of first appearance), `{{name}}` for i18next or `{name}` for ICU.
Round trips are tested in both directions because import (section 9) depends on them.

**Plurals.** CLDR categories per locale. Converters produce `variations.plural` in
`.xcstrings`, `<plurals>` in Android, `key_one` / `key_other` or an ICU plural message for web.
The app knows which categories a locale needs via ICU plural rules, so adding Polish or Arabic
automatically asks for `few` / `many`.

**Row identity.** Every key carries a UUID in addition to its name, so renames and row
reordering in a sheet never orphan translations, history or Figma links.

---

## 4. Backends

### 4.1 Protocol

```swift
public protocol StringsBackend: Sendable {
    var id: BackendID { get }
    var capabilities: BackendCapabilities { get }   // history, statusColumn, comments
    func pull() async throws -> Snapshot             // whole project; datasets are small
    func push(_ changes: ChangeSet, basedOn: Snapshot) async throws -> PushResult  // reports conflicts
    func addLocale(_ locale: LocaleCode) async throws
    func removeLocale(_ locale: LocaleCode) async throws
}
```

`ChangeSet` is a list of intents: `upsertKey`, `renameKey`, `deleteKey`, `setTranslation`,
`setStatus`, `setContext`. Intent-based pushes are what make cell-level conflict detection,
history and the import flow possible.

One contract test suite runs against every provider. `LocalJSON` runs it on every CI build;
`GoogleSheets` runs it live when a service-account env var is present.

### 4.2 Providers

| Provider | Phase | Notes |
|---|---|---|
| Google Sheets | 1 | Primary. Translators can edit the sheet directly. |
| Local JSON file | 1 | A `.runa.json` on disk or in iCloud Drive. Zero setup, demos, tests. |
| GitHub repository | later | Canonical JSON committed in a repo; a push becomes a commit. Attractive for dev-only teams. |
| Lokalise / Crowdin / Phrase, Supabase, Airtable, Notion | later, on demand | The protocol is designed so each is one file. |

### 4.3 Google Sheets as a backend: precedent

This is a well-trodden pattern. Open-source localization tools that use a Google Sheet as the
source of truth with a service account include
[goloc](https://github.com/walkline/goloc) (Android, iOS, JSON),
[ACKLocalization](https://github.com/jmarek41/ACKLocalization) (iOS),
[sheet_loader_localization](https://pub.dev/packages/sheet_loader_localization) (Flutter),
[sheetspeare](https://github.com/mogharsallah/sheetspeare) and
[loc-sync](https://github.com/larsiusprime/loc-sync) (sheet to git sync). Runa's difference is
the Mac UI, the Figma link, the AI drafts and the MCP server; the storage pattern itself is
proven.

### 4.4 Sheet layout

Tab `strings` (wide, human-friendly, what translators see):

| id (hidden) | key | description | tags | platforms | plural | figma | en | sv | de | … |
|---|---|---|---|---|---|---|---|---|---|---|

- Plural keys use one row per CLDR category, with the `plural` column set to `one`, `other`, etc.
- `figma` holds one Figma node URL per line; richer context goes in a hidden `_context` tab
  keyed by `id` (frame name, node path, box size, sibling texts).
- Hidden `_status` tab in long format (`id | locale | status | updatedAt | updatedBy`).
- Hidden `_history` tab, append-only (see section 5).
- Hidden `_meta` tab: `schemaVersion`, `sourceLocale`, `placeholderStyle`. The locale list is
  the header row, so **adding a language is adding a column**. The app does it with
  `appendDimension`; translators can also do it by hand and the app picks it up on the next pull.

Writes use `values.batchUpdate` on exact cells. Row and column positions are resolved from a
fresh `values.get` immediately before writing, because other people insert rows. New keys use
`values.append`; deletes use `deleteDimension`. Conflicts are detected per cell: if the remote
value differs from what the app pulled last time, the app shows both and asks.

A **template sheet** ("Make a copy" link in the README) ships with the tabs, header row,
protected ranges for the hidden tabs, and a sample key.

### 4.5 Authentication: service account, by design

Runa is a personal open-source project, not a Google Workspace product. That rules out the
"Sign in with Google" button for a practical reason: the Sheets scope is classed as _sensitive_,
so an OAuth client embedded in a distributable app must pass Google's verification process
(privacy policy, homepage, demo video, review time) and until then is capped at 100 users with
tokens that expire after seven days. Every user running their own OAuth client is worse.

So the Google Sheets provider authenticates with a **service account** everywhere:

| Client | How the credential gets there |
|---|---|
| Mac app | Setup wizard: create a Google Cloud project, enable the Sheets API, create a service account, download its JSON key, drop it on the app. Stored in the Keychain. The app shows the service account's email so the user can share the sheet with it like with a colleague, then runs **Test connection**. |
| CLI / MCP | Path to the same JSON via `runa.yml` or `RUNA_GOOGLE_CREDENTIALS`, or written by the Mac app's "Install command line tool" into `~/Library/Application Support/Runa/credentials/` with `0600` permissions. |
| Figma plugin | Pasted once into the plugin's settings, stored in `figma.clientStorage` (per user, per machine). JWT signed with WebCrypto in the plugin iframe. |

Signing in Swift uses `swift-crypto`'s RSA support so the same code runs in the app and in
the CLI on Linux. Because every write arrives as the service account, Runa writes the user's
display name (set once in Settings) into `_status.updatedBy` and `_history.actor` itself.

Rotation and revocation: delete the key in the Google Cloud console and drop a new one on the
app. Removing the service account from the sheet's sharing list cuts all clients off at once.

Fallback if the Figma iframe cannot reach the Sheets API (CORS is to be confirmed in the
phase 0 spike): a Google Apps Script web app bound to the sheet, deployed by the user from the
sheet's own menu. Still Google-hosted, still nothing of ours.

---

## 5. Versioning and history

Three layers, each cheap, together enough. Branching and snapshots are overkill for this backend
and are deliberately left out.

1. **Google's own version history** (File → Version history in Sheets) is the disaster-recovery
   layer. Whole-sheet restore, every cell, by the owner, no code needed. Runa's README points at
   it. Its only gap is that every edit from Runa shows as the service account, which layer 2
   fixes.
2. **The `_history` tab** is Runa's per-key history. Append-only rows
   `ts | actor | action | keyId | key | locale | before | after`, written by every push in the
   same batch as the change. The app shows a timeline per key and an **Activity** view per
   project, and offers **Restore this value**, which is simply a new change (so it is itself
   recorded). Imports and AI drafts are tagged with their action so you can see where a value
   came from. The tab grows by one row per change; a "Compact history older than N months"
   action exports the old rows to a JSON file and deletes them.
3. **Git on the consumer side** answers "what shipped in release 3.2". `runa pull` writes the
   platform files and the developer commits them, so every release's exact strings are in the
   repo history already.

Separately, `_meta.schemaVersion` versions the **sheet layout** so a future Runa can migrate
old sheets (add a tab, rename a column) with a one-click migration and a backup copy first.

---

## 6. Delivery: CLI and MCP in one binary

One Swift executable, `runa`, sharing `RunaCore` with the app. The developer runs it in a repo
and commits the result; Runa never touches git.

**Config: `runa.yml` committed in the repo**

```yaml
backend:
  type: google-sheets
  spreadsheetId: 1AbC…
  credentials: ${RUNA_GOOGLE_CREDENTIALS}      # or a path; never committed
sourceLocale: en
targets:
  - type: xcstrings
    path: ios/App/Localizable.xcstrings
  - type: android
    path: android/app/src/main/res
    keyStyle: underscore
  - type: i18next
    path: web/public/locales
    nested: true
```

**Commands**

| Command | Does |
|---|---|
| `runa pull` | Pulls the backend and writes every target. Idempotent, deterministic ordering, so diffs are clean. |
| `runa check` | Lists keys missing or unapproved per locale; non-zero exit for CI. |
| `runa import <files…> [--locale sv] [--dry-run] [--prefer file\|backend]` | Section 9. The Mac app is the primary place to resolve conflicts; the CLI handles the clean cases. |
| `runa keys search <query>` / `runa keys add <key> --text "…"` | Scripting helpers. |
| `runa mcp` | Starts an MCP server on stdio (official `modelcontextprotocol/swift-sdk`). |

**MCP tools** (so Claude Code, Cursor and friends can work with strings while implementing a
feature): `runa_search_keys`, `runa_get_key`, `runa_add_key`, `runa_update_source_text`,
`runa_delete_key`, `runa_list_locales`, `runa_check`, `runa_pull`. A `runa://project/summary`
resource gives the agent locale coverage at a glance. Setup is one line:
`claude mcp add runa -- runa mcp`, and the Mac app shows the equivalent JSON for other clients.

**Formats written**

| Target | File | Details |
|---|---|---|
| iOS | `Localizable.xcstrings` | String Catalog, all locales in one file, plurals via variations, `extractionState: manual`. Legacy `.strings` + `.stringsdict` writer for older projects. |
| Android | `res/values/strings.xml`, `res/values-<lang>/strings.xml` | `<plurals>`, proper escaping (`'`, `&`, `%` to `%%`), `translatable="false"` for do-not-translate keys. |
| Web | `locales/<lang>.json` | i18next (flat or nested) or ICU MessageFormat JSON. Optional `strings.d.ts` with a union of all keys. |

The Mac app also exports the same files through a save panel for ad-hoc use.

---

## 7. Runa for Mac

**Stack.** SwiftUI on macOS 15+, Swift 6 strict concurrency, `@Observable` view models, a JSON
file cache per project, `URLSession` only. Local-first: the app keeps the last snapshot and a queue
of pending changes, so it is instant to browse and conflicts are detected per cell, never
silently resolved.

**Layout.** `NavigationSplitView`: sidebar (Projects, Languages, Activity, Import), a `Table` of
keys with sortable columns and one status-dot column per language, and an inspector for the
selected key. Settings window (`⌘,`) for backends, AI providers, Figma token, glossary and style
guide, and the installers (section 12). Full menu bar and keyboard: `⌘K` command palette,
`⌘N` new key, `⌘F` search, `⌘⇧T` translate selection, `⌘⏎` approve.

**Keys.** Browse, fuzzy search over keys and every language's text, add, edit, rename, delete,
tag, multi-select for bulk actions. The inspector shows source text, description, placeholder
chips, one editor per language, a plural editor showing exactly the categories the language
needs, the Figma context card with thumbnail and "Open in Figma", and the key's history.

**Languages.** The Languages screen lists every language that exists in the backend with
coverage (`128 / 140 approved`, `12 missing`). **Add** opens a picker searchable by name or code
and shows the plural categories the language will need. **Remove** requires typing the language
code, exports that column to JSON first, then deletes it via the backend.

**Missing-translation warnings.** The sidebar badge shows the total of missing or unapproved
values. The Languages screen and a banner on the key list say _"12 keys are missing in Swedish"_
with one-click filters, each row shows a hollow dot for a missing value, `runa check` fails CI,
and the banner's call to action is **Translate missing with Claude** when a provider is
connected.

**AI translation.** From a key, a selection or the banner: pick target languages, see the batch
size and an estimated cost, run, then land in the **Review** screen: source, draft and editable
result side by side, approve or edit, keyboard driven. See section 10.

---

## 8. Figma plugin

Scope is deliberately narrow: **main language and the link only.**

- **Stack.** TypeScript, esbuild, Figma Plugin API, `manifest.json` with
  `networkAccess.allowedDomains` limited to `sheets.googleapis.com` and
  `oauth2.googleapis.com`.
- **Settings.** Spreadsheet ID and service-account JSON, stored in `figma.clientStorage`.
- **Linking flow.** Select one or more text layers. The panel shows each text, suggests a key
  from page name + frame name + a slug of the text (`checkout.summary.title`), and searches
  existing keys from a cached pull with fuzzy match. **Link** attaches an existing key;
  **Create** adds a new key with this text as the source-language value and an optional
  description. One push writes value and context.
- **Context captured per link** (what the translator and the AI need): file key, node id, page
  name, top-level frame name, node path, text box size and font size (a fit budget), sibling
  texts in the same frame, and the canonical Figma URL.
- **Bidirectional link.** `node.setPluginData("runa.key", key)` so linked layers show a badge,
  the plugin detects drift (designer changed the text after linking, or the source text changed
  in the backend) and offers to push or update, and a whole frame can be re-synced in one click.
- **Never shows other languages.** No translation preview, no locale switching. Those are app
  features.
- **Thumbnails** are not uploaded anywhere. The Mac app renders a node image on demand with the
  Figma REST API (`GET /v1/images/:file_key?ids=…`) using the user's Figma personal access
  token from the Keychain, caches it locally, and can pass it to a vision-capable AI provider.

---

## 9. Importing existing files

Importing is a three-step flow in the Mac app (and a `--dry-run` command in the CLI for the
clean cases). Nothing reaches the backend until the user confirms the review table.

1. **Parse.** Drop files or a folder. Format and locale are detected (`values-sv/strings.xml`
   → Android, `sv`; `sv.lproj/Localizable.strings` → iOS, `sv`; `Localizable.xcstrings` → all
   locales at once; `locales/sv.json` → web, `sv`), overridable per file. Files are converted
   to the canonical model: placeholders normalised, plural forms merged, keys mapped with a
   visible rule (Android `checkout_summary_title` ↔ `checkout.summary.title`).
2. **Diff against the current backend snapshot.** Every imported value lands in one bucket:

   | Bucket | Default action |
   |---|---|
   | New key | Add, status `approved` (it shipped) |
   | Same value | Skip |
   | **Different value** | Conflict: pick _file_ or _backend_ per row, or bulk "prefer file for Swedish"; the editor lets you merge by hand |
   | Placeholder mismatch (file has `%1$s`, backend has `{name}` and `{count}`) | Conflict, highlighted, cannot be auto-resolved |
   | Key only in backend | Untouched, listed for information |

   Languages present in the files but not in the backend are offered as "Add language sv?".
3. **Apply** as one `ChangeSet`, recorded in `_history` with action `import` and the file name,
   so it can be audited and reverted per key.

---

## 10. AI translation

### 10.1 Bring your own provider

```swift
public protocol TranslationProvider: Sendable {
    var id: ProviderID { get }                     // anthropic | openai | gemini | openaiCompatible
    var capabilities: ProviderCapabilities { get } // vision, jsonSchema, batchAPI
    func translate(_ batch: TranslationBatch) async throws -> [TranslationDraft]
}
```

| Provider | Order | Notes |
|---|---|---|
| **Claude** (Anthropic Messages API) | first | Direct HTTPS via `URLSession`; there is no official Swift SDK. Default model `claude-opus-5-5` with a picker. Structured output via `output_config.format` with a JSON schema, image blocks for Figma thumbnails, and the Batches API at half price for large runs later. |
| OpenAI | second | Responses API with JSON-schema structured output, image inputs for thumbnails. |
| Gemini | third | `generateContent` with `responseSchema`, image inputs. |
| OpenAI-compatible | fourth | Custom base URL + key. Covers Ollama, LM Studio, OpenRouter, Mistral, Groq and most others. JSON mode best effort. |

The user picks one provider per project in Settings, pastes their key (Keychain), presses
**Test**, and chooses a model. One prompt template and one output schema
(`{ translations: [{ keyId, locale, value | plural }] }`) are shared; each adapter only maps the
schema and image format to its API.

### 10.2 Prompt inputs per key

Source text, description, placeholders that must be preserved verbatim, the plural category
being filled, project glossary and do-not-translate list, per-language style guide (tone,
formality, e.g. Swedish "du"), Figma context (page and frame names, sibling texts, fit budget),
existing translations in other languages for consistency, and the Figma thumbnail when the
provider can see.

### 10.3 Deterministic validation (in Swift, provider-independent)

Placeholders preserved and typed correctly, all required plural categories present for the
language, no leading or trailing whitespace, length versus fit budget (warn), not an
untranslated copy of the source, no stray quotes or markdown. A failing draft is retried once
with the error attached, then shown as failed.

### 10.4 Workflow and cost

"Translate missing in sv, de" → batches of about 25 keys per language with a concurrency cap →
drafts land as `machine` → Review screen → `approved` or edited. Nothing is auto-approved, and
the status is visible in the sheet so translators can see what came from a model. The app shows
an estimate before running and the run is cancelable.

---

## 11. Design system, Linear-inspired

Linear's look is dark-first, near-monochrome, one accent, 1px low-contrast borders, dense rows,
tight typography, keyboard-driven, fast and quiet motion. It fits a Mac app well. The values
below approximate Linear's public stylesheet and should be checked in the browser inspector
before we lock them.

| Token | Dark | Light |
|---|---|---|
| bg.app | `#08090A` | `#FFFFFF` |
| bg.panel / bg.elevated | `#0F1011` / `#141516` | `#F7F8F8` / `#FFFFFF` |
| bg.hover / bg.selected | `#191A1B` / accent at 12% | `#F0F1F3` / accent at 10% |
| text.primary / secondary / tertiary | `#F7F8F8` / `#D0D6E0` / `#8A8F98` | `#0F1011` / `#3C3F44` / `#6F737A` |
| border.subtle / border.strong | `rgba(255,255,255,0.08)` / `0.12` | `rgba(0,0,0,0.08)` / `0.12` |
| accent / accent.hover | `#5E6AD2` / `#6E79D6` | same |
| status.missing / machine / review / approved | `#EB5757` / `#B59AFF` / `#F2C94C` / `#4CB782` | same, muted |

- **Type.** Inter Variable (OFL, bundled) with SF Pro fallback. Sizes 12 mini, 13 small,
  15 body, 17 / 20 / 24 titles. Weights 400 / 510 / 590. Titles use `-0.01em` to `-0.02em`
  letter-spacing. Tabular numerals wherever numbers align.
- **Shape.** Radius 4 chips, 6 buttons and inputs, 8 cards, 12 sheets. Spacing scale
  4 / 8 / 12 / 16 / 24 / 32. 1px separators, no drop shadows except menus and popovers.
- **Motion.** 120 to 180 ms ease-out. No springs or bounces.
- **Status** is shown as 6 to 8 px dots, not coloured badges, so rows stay quiet.
- **Mac specifics.** Unified toolbar, sidebar with vibrancy off (solid, like Linear), inspector
  on the right, command palette as a floating panel, native menus and shortcuts.
- Dark mode is the primary design. Light mode is fully supported.

Implemented as a `RunaDesign` Swift package (`Color.runa.*`, `Font.runa.*`, `Spacing`,
`Row`, `StatusDot`, `Chip`, `Field`, `CommandPalette`, `EmptyState`).

**Branding.** "Runa" (a rune is an inscribed mark, which is what a string key is). Wordmark in
Inter 590 with tight tracking, mark is a single angular glyph. We borrow Linear's _principles_,
not its logo, name or exact palette.

---

## 12. Distribution and installation

The GitHub repository is the product. License: MIT (easy for others to clone and ship).

| Piece | How others get it |
|---|---|
| **Mac app** | Clone and build in Xcode, or download `Runa.dmg` from GitHub Releases. A GitHub Actions workflow on every tag archives, signs, notarizes and uploads the DMG. Notarization needs an Apple Developer Program membership (USD 99 a year); without it users must right-click → Open once, which the README explains. Optional `brew install --cask runa` from a tap, and Sparkle 2 for in-app updates fed by the Releases appcast. |
| **CLI / MCP** | Bundled inside the app (`Runa.app/Contents/Helpers/runa`). Settings → **Install command line tool** symlinks it into `/usr/local/bin` (or `~/.local/bin` without admin), writes the credentials file, and shows the `claude mcp add runa -- runa mcp` line plus JSON for other MCP clients. Also a Homebrew formula and a GitHub Action for CI. |
| **Figma plugin** | Three paths, cheapest first. (1) **Import from manifest**: the built plugin folder is attached to every release; in Figma desktop, Plugins → Development → Import plugin from manifest. Works on every Figma plan, per user. (2) **From the Mac app**: Settings → **Install Figma plugin…** writes the bundled plugin folder to `~/Library/Application Support/Runa/figma-plugin/`, opens Figma, and shows the three-step import with the path on the clipboard. Figma has no API to register a development plugin, so the final click stays manual. (3) **Figma Community** (later, once stable): free, reviewed by Figma, public listing, one-click install for everyone; the plugin is still useless without the sheet credentials, so public listing is safe. Private _organisation_ publishing exists but requires a Figma Organization or Enterprise plan, so it is not the default path. |

---

## 13. Repository layout

```
runa/
  Package.swift                      # RunaCore, RunaDesign, RunaCLI
  Sources/RunaCore/
    Model/        Formats/{XCStrings,AndroidXML,I18nextJSON}/   Backends/{GoogleSheets,LocalJSON}/
    Sync/         Import/   History/   AI/{Providers,Prompting,Validation}/   Figma/
  Sources/RunaDesign/
  Sources/RunaCLI/                   # pull, check, import, keys, mcp
  Tests/RunaCoreTests/Fixtures/      # golden files, one folder per format and direction
  Apps/Runa/                         # Xcode project, macOS target, bundles the CLI and the plugin
  figma-plugin/                      # TS, esbuild, manifest.json, src/{code.ts,ui/}
  templates/runa-sheet-template.csv  # plus a "Make a copy" link in the README
  docs/                              # this plan, ADRs, setup guides (Google, Figma, MCP)
  .github/workflows/                 # tests, release (DMG + plugin zip + CLI)
```

---

## 14. Security and privacy

Service-account keys and AI API keys live in the Keychain (app), `0600` files the user opted
into (CLI), or `figma.clientStorage` (plugin). They are never written to the sheet, a repo or a
log. AI providers receive strings and context only, never credentials; the provider is opt-in
per project. No analytics or telemetry. The release workflow signs and notarizes so downloads
are verifiable.

---

## 15. Roadmap

| Phase | Scope | Rough size |
|---|---|---|
| 0. Spikes | Sheets API with a service account from Swift (RSA signing via swift-crypto) and from the Figma iframe (CORS + WebCrypto); `.xcstrings` round trip; Claude structured-output call from Swift. | 1 week |
| 1. Core + Sheets + Mac MVP | Model, converters, LocalJSON + Google Sheets with setup wizard and template sheet, key table with search / add / edit / delete, languages add / remove, missing warnings, export, design-system basics, release workflow producing a DMG. | 3 to 4 weeks |
| 2. CLI + MCP | `runa pull / check / keys`, `runa.yml`, `runa mcp` with the tool set above, "Install command line tool" in the app, GitHub Action. | 1 to 2 weeks |
| 3. AI translation | Provider protocol, Claude first, then OpenAI, Gemini, OpenAI-compatible; glossary and style guide; batch translate from the missing banner; Review screen; validation. | 2 weeks |
| 4. Figma plugin | Link / create keys, push source text, capture context, pluginData badges and drift detection, context card with thumbnails in the app, "Install Figma plugin" in the app. | 2 weeks |
| 5. Import + history | Import flow with conflict review, `_history` tab, Activity view, restore. | 1 to 2 weeks |
| 6. Polish and reach | Notarized releases, Sparkle updates, Homebrew, Figma Community listing, GitHub backend. | ongoing |

---

## 16. Remaining small decisions

1. **Apple Developer Program.** Do you have (or want) a membership for notarized releases? If
   not, phase 1 ships unsigned builds with the right-click → Open note.
2. **Minimum macOS.** The plan assumes macOS 15. Say so if you need 14.
3. **Figma Community listing.** Planned for phase 6, only if you want the public listing.
4. **Repository name and license.** `runa` and MIT assumed.

---

## 17. Risks

| Risk | Mitigation |
|---|---|
| Figma plugin iframe cannot reach Google APIs (CORS) or sign JWTs | Phase 0 spike; fallback is an Apps Script web app bound to the sheet, still no hosting of ours. |
| A shared service-account key leaks | It only grants access to sheets explicitly shared with it; rotate in the Google console; documented in the setup guide. |
| Rows shift under concurrent editing | UUID column, resolve positions right before writing, per-cell conflict check. |
| Plural and placeholder edge cases between formats | Golden tests; the import flow surfaces real-world cases early. |
| Provider APIs change shape | Thin adapters behind one protocol; one shared prompt and schema. |
| Unsigned builds scare users | Notarize as soon as a developer account exists; Homebrew cask as an alternative. |
