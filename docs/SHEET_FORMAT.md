# Runa sheet format (schema version 1)

This is the contract between every client that reads or writes a Runa Google Sheet: the Mac app
and CLI (Swift, `Sources/RunaCore/Backends/GoogleSheets`) and the Figma plugin (TypeScript,
`figma-plugin/src/sheets`). Change both when this changes, and bump `schemaVersion`.

## Tabs

| Tab | Visible | Purpose |
|---|---|---|
| `strings` | yes | One row per key (one per plural form for plural keys). What translators edit. |
| `_meta` | hidden | Project settings as `key | value` rows. |
| `_status` | hidden | Review status per key and locale. |
| `_context` | hidden | Figma links with design context. |
| `_history` | hidden | Append-only change log. |
| `guidelines` | yes | Naming guide, key format and style guides, for people and agents. Optional. |
| `glossary` | yes | Terms AI must translate a fixed way. Optional. |

Tab names are exact and case-sensitive. A spreadsheet without `_meta`/`_status`/`_context`/`_history`
still reads; clients create the missing tabs on setup. `guidelines` and `glossary` are optional: new
sheets get them on setup, older ones when guidelines are first saved. Adding them did not change the
schema version, since clients that do not know them ignore them.

## `strings`

Row 1 is the header. Columns are found by header name (trimmed, case-insensitive), never by
position, so people can reorder or add their own columns. Unknown columns are preserved and ignored.

| Header | Meaning |
|---|---|
| `_id` | Stable key id, lowercase UUID. Hidden. Blank means "derive" (below). |
| `key` | Key name, for example `checkout.summary.title`. Required. Projects can set a format in `guidelines`. |
| `description` | Context for translators. Aliases: `comment`, `context`. |
| `plural` | Blank for plain keys. For plural keys one row per form: `zero` `one` `two` `few` `many` `other`. |
| *locale* | Any header that is a valid language tag with a real ISO 639 language (`en`, `sv`, `pt-BR`, `zh-Hans`) is a locale column. The cell is that locale's text. Empty cell = missing. |
| `figma` | Figma node URLs, one per line. |
| `tags` | Comma-separated. The tag `notranslate` means every locale uses the source text. |
| `platforms` | Comma-separated subset of `ios`, `android`, `web`. Blank = all. |

Column order on creation: `_id, key, description, plural, <source locale>, <other locales…>, figma, tags, platforms`.
New locale columns are inserted after the last locale column.

**Rows of one key.** Rows with the same `_id` belong to one key. Plural keys have one row per form;
`key`, `description`, `tags`, `platforms` repeat on each row and are read from the first non-empty
cell. `figma` is written on the key's first row only; readers collect URLs from every row. A row
whose `plural` cell is blank in a plural group is the `other` form.

**Derived ids.** A row with a blank `_id` gets `uuid(sha256("runa:key:" + key))`: the first 16 bytes
of the SHA-256 digest of the UTF-8 string, with `byte[6] = (byte[6] & 0x0F) | 0x50` and
`byte[8] = (byte[8] & 0x3F) | 0x80`, formatted lowercase `8-4-4-4-12`. Clients write the derived id
into the cell the next time they touch the row.

**Text.** Values are stored as plain strings (written with `stringValue`, so `=` and leading zeros
are safe) and read with `FORMATTED_VALUE`. Placeholders use Runa syntax: `{name}`, `{count:int}`,
`{price:double}`, `{price:double.2}`.

## `_meta`

Header `key | value`, then:

| key | value |
|---|---|
| `schemaVersion` | `1` |
| `projectName` | Display name. Falls back to the spreadsheet title. |
| `sourceLocale` | The source language, for example `en`. Falls back to the first locale column. |

## `_status`

Header: `id | locale | status | hash | sourceHash | updatedAt | updatedBy`

- `status`: `machine`, `needs-review` or `approved`.
- `hash`: hash (below) of the translation's text when the row was written. If the current text has
  a different hash, someone edited the cell directly in the sheet: the status reads as `approved`.
- `sourceHash`: hash of the source-locale text the translation was written or approved against. If
  the current source text hashes differently, an approved translation reads as `needs-review`.
- No row for a translation means `approved`. The source locale never has rows.
- `updatedAt`: ISO 8601 UTC without fractional seconds, `2026-10-07T09:30:00Z`.

**Hash.** Take the forms that are not empty, in the order `zero one two few many other`; write each
as `<category> U+001F <text>`; join with U+001E; SHA-256 the UTF-8 bytes; keep the first 12 lowercase
hex characters. A plain key is the single form `other`.

## `_context`

Header: `id | url | fileKey | nodeId | page | frame | path | width | height | fontSize | siblings | linkedAt | linkedBy | frameId`

One row per (key, Figma node). `nodeId` and `frameId` use API form `12:34`. `frameId` is the top-level
frame under the page that contains the text; the Mac app renders it through the Figma REST API as a
screenshot for translators and AI. Empty when the text is not inside a frame. `siblings` is a JSON array of up to
10 strings (each at most 200 characters) from other text layers in the same frame. Numbers are
plain decimals. The `figma` column in `strings` lists the same URLs for people; a URL that appears
only there is read as a context with just `url`, `fileKey` and `nodeId`.

## `_history`

Header: `ts | actor | action | id | key | locale | plural | before | after | note`

Append-only. `action` is one of `add-key`, `update-key`, `delete-key`, `set-value`, `set-status`,
`link-figma`, `add-locale`, `remove-locale`, `update-guidelines`. For `update-guidelines`, `key` holds
the topic (`naming`, `keyTemplate`, `keyPattern`, `style` with `locale`, or `glossary`, whose
`before` and `after` are term counts such as `12 terms`). `note` says where a change came from:
`figma`, `import values-sv/strings.xml`, `ai claude-opus-5-5`, …

## `guidelines`

Header `topic | language | value`, then one row per topic. The first non-empty value of a topic counts.

| topic | language | value |
|---|---|---|
| `naming` | | Markdown for people and agents: how to name keys and write text. The MCP server sends it to agents. |
| `keyTemplate` | | The key format, below. Empty: no rule. |
| `keyPattern` | | A regular expression every key name must match in full. Checked instead of the template when set. |
| `style` | a language code | The style guide for that language, used by AI translation. |

Rows with other topics are notes for people. Clients that save guidelines rewrite the known topics
and keep the other rows below them. A cell holds at most 50,000 characters.

### Key template

```
{platform?}_{feature}_{description}_{type:title|text|action}
```

- `{name}` is one lowerCamelCase word: a letter, then letters and digits (`home`, `welcomeCard`).
- `{name:a|b|c}` is one of the listed values.
- `{platform}` is `ios`, `android` or `web`, unless values are listed. A key whose name starts with a
  platform ships to that platform only; clients set `platforms` when they create it, and
  `runa check --names` reports keys where the two disagree.
- `?` makes a part optional together with the literal text right after it (`{platform?}_`), or the
  literal right before it when the part comes last.
- Everything outside braces is literal.

Plural forms are never part of a key name: a plural key has one name and its forms live in the
`plural` column.

## `glossary`

Header `term | note`, then one column per language code. One row per term. An empty translation means
the term stays as it is in that language. Clients that save the glossary rewrite the whole tab.

## Writing rules

- Read everything, then write all changes in **one** `spreadsheets.batchUpdate`, which Google
  applies atomically.
- Only rewrite rows of keys you changed. Never rewrite the whole tab.
- Resolve row positions from a fresh read immediately before writing.
- Before overwriting a cell, compare it with the value you based your edit on. If it changed and
  differs from your new value, report a conflict instead of writing.
- Append one `_history` row per change.
- Place cells in hidden tabs by header name. If a tab's header lacks a column you need to write
  (an older sheet without `frameId`, say), add the header cell at the end of row 1 in the same batch.

## Test vectors

Every implementation must reproduce these (Swift: `TextTests.crossLanguageVectors`).

| Input | Output |
|---|---|
| hash of `{other: "Hello"}` | `a8a7157e2918` |
| hash of `{one: "{count:int} item", other: "{count:int} items"}` | `28e56bf13e39` |
| hash of `{other: "Hej då 👋"}` | `48a4dc59c479` |
| derived id of `checkout.title` | `d286c840-69d2-5786-b77b-30b06363380d` |
| derived id of `cart.items` | `31962844-99e1-5361-85d8-42d00b9b2191` |

Key templates (Swift: `KeyTemplateTests.templateVectors`; TypeScript: `test/keys.test.ts`). With the
template `{platform?}_{feature}_{description}_{type:title|text|action}`:

| Name | Valid | Platform |
|---|---|---|
| `home_welcomeCard_title` | yes | |
| `common_ok_action` | yes | |
| `ios_checkout_continueWithApplePay_action` | yes | `ios` |
| `android_settings_openGooglePlay_action` | yes | `android` |
| `web_footer_terms_text` | yes | `web` |
| `home_welcomeCard_heading` | no | |
| `Home_welcomeCard_title` | no | |
| `home_welcome_card_title` | no | |
| `ios_title` | no | |
| `profile_friendsCount_text.one` | no, plural form in the name | |

| Template | Name | Valid |
|---|---|---|
| `{platform?:ios\|android}_{feature}_{description}` | `web_footer_terms` | no |
| `{feature}.{description}` | `checkout.summaryTitle` | yes |
| `{feature}.{description}` | `checkout.summary.title` | no |
| `{feature}_{description}_{variant?}` | `home_title` | yes |
| `{feature}_{description}_{variant?}` | `home_title_short` | yes |
