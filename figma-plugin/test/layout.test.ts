import { describe, expect, it } from "vitest";
import { derivedId } from "../src/sheets/hash";
import { parseGuidelines, parseSheet, sourceText } from "../src/sheets/layout";
import { SheetError } from "../src/sheets/types";
import { CONTEXT_HEADER_V1, IDS, sampleInfo, sampleModel, TITLE_URL } from "./fixtures";

describe("parseSheet", () => {
  it("reads settings from _meta", () => {
    const model = sampleModel();
    expect(model.projectName).toBe("Shop");
    expect(model.sourceLocale).toBe("en");
    expect(model.locales).toEqual(["en", "sv"]);
    expect(model.setupIssues).toEqual([]);
    expect(model.missingTabs).toEqual([]);
  });

  it("groups rows by id, derives blank ids and skips rows without a key", () => {
    const model = sampleModel();
    expect(model.keys.map((key) => key.key)).toEqual(["checkout.title", "checkout.pay_now", "cart.items", "formula.text"]);
    const payNow = model.byName.get("checkout.pay_now")!;
    expect(payNow.id).toBe(derivedId("checkout.pay_now"));
    expect(payNow.rows[0]!.hasStoredId).toBe(false);
    expect(payNow.rows[0]!.index).toBe(2);
    expect(model.byId.get(IDS.title)!.rows[0]!.hasStoredId).toBe(true);
  });

  it("reads plural groups, with description from the first non-empty cell", () => {
    const items = sampleModel().byId.get(IDS.items)!;
    expect(items.isPlural).toBe(true);
    expect(items.rows.map((row) => [row.index, row.category])).toEqual([[3, "one"], [4, "other"]]);
    expect(items.source).toEqual({ one: "{count:int} item", other: "{count:int} items" });
    expect(items.description).toBe("Item count");
    expect(sourceText(items)).toBe("{count:int} items");
  });

  it("treats a blank plural cell in a plural group as the other form", () => {
    const model = sampleModel((grids) => {
      grids.strings![4]![3] = "";
    });
    expect(model.byId.get(IDS.items)!.source.other).toBe("{count:int} items");
  });

  it("finds columns by header name, with description aliases and any order", () => {
    const model = parseSheet(sampleInfo(), {
      strings: [
        ["Comment", "SV", "Key", "EN", "_ID"],
        ["Shown on the button", "Köp", "buy", "Buy", ""],
      ],
      _meta: [["key", "value"]],
    });
    const buy = model.byName.get("buy")!;
    expect(buy.description).toBe("Shown on the button");
    // No sourceLocale in _meta: the first locale column (SV) is the source.
    expect(model.sourceLocale).toBe("sv");
    expect(model.locales).toEqual(["sv", "en"]);
    expect(buy.source).toEqual({ other: "Köp" });
    expect(model.columns.id).toBe(4);
    expect(model.projectName).toBe("Shop strings");
  });

  it("falls back to the first locale column when the declared source has no column", () => {
    const model = sampleModel((grids) => {
      grids._meta![3] = ["sourceLocale", "de"];
    });
    expect(model.sourceLocale).toBe("en");
    expect(model.warnings.some((warning) => warning.includes("de"))).toBe(true);
  });

  it("merges Figma links from _context and the figma column, and reads frameId", () => {
    const extra = "https://www.figma.com/design/FILE1/App?node-id=5-6";
    const model = sampleModel((grids) => {
      grids.strings![1]![6] = `${TITLE_URL}\n${extra}\nnot a figma link`;
    });
    const title = model.byId.get(IDS.title)!;
    expect(title.figmaUrls).toEqual([TITLE_URL, extra]);
    expect(title.contexts[0]).toMatchObject({ url: TITLE_URL, nodeId: "1:2", frameId: "1:1", frame: "Summary" });
    expect(title.contexts[1]).toMatchObject({ url: extra, fileKey: "FILE1", nodeId: "5:6", frameId: "" });
  });

  it("reads _context rows of sheets set up before the frameId column existed", () => {
    const model = sampleModel((grids) => {
      grids._context = [CONTEXT_HEADER_V1, [IDS.title, TITLE_URL, "FILE1", "1:2", "Checkout", "Summary"]];
    });
    expect(model.byId.get(IDS.title)!.contexts[0]).toMatchObject({ url: TITLE_URL, frame: "Summary", frameId: "" });
  });

  it("reports missing tabs and columns as setup issues instead of failing", () => {
    const model = sampleModel(undefined, ["_context", "_history"]);
    expect(model.missingTabs).toEqual(["_context", "_history"]);
    expect(model.setupIssues).toEqual(["the _context tab", "the _history tab"]);
    expect(model.keys).toHaveLength(4);

    const noId = parseSheet(sampleInfo(), { strings: [["key", "en"], ["a", "A"]] });
    expect(noId.setupIssues).toEqual(["the _id column", "the figma column"]);
    expect(noId.byName.get("a")!.id).toBe(derivedId("a"));
  });

  it("fails clearly without a strings tab, key column or locale column", () => {
    expect(() => parseSheet({ title: "x", tabs: [] }, {})).toThrow(SheetError);
    expect(() => parseSheet(sampleInfo(), { strings: [["name", "en"]] })).toThrow(/"key" column/);
    expect(() => parseSheet(sampleInfo(), { strings: [["key", "notes"]] })).toThrow(/no language columns/);
  });

  it("warns about duplicate key names and keeps the first", () => {
    const model = sampleModel((grids) => {
      grids.strings!.push([derivedId("x"), "checkout.title", "", "", "Again"]);
    });
    expect(model.byName.get("checkout.title")!.id).toBe(IDS.title);
    expect(model.warnings.some((warning) => warning.includes("more than once"))).toBe(true);
  });
});

describe("guidelines tab", () => {
  it("reads the naming guide, key template and pattern", () => {
    const model = sampleModel((grids) => {
      grids.guidelines = [
        ["Topic", "Language", "Value"],
        ["naming", "", "## Keys\nfeature_description_type"],
        ["keyTemplate", "", "  {feature}_{description}_{type:title|text|action} "],
        ["keyPattern", "", ""],
        ["style", "sv", "Informellt"],
        ["owner", "", "Design"],
      ];
    });
    expect(model.guidelines).toEqual({ naming: "## Keys\nfeature_description_type", keyTemplate: "{feature}_{description}_{type:title|text|action}", keyPattern: "" });
    expect(model.rules.template?.source).toBe("{feature}_{description}_{type:title|text|action}");
    expect(model.warnings).toEqual([]);
  });

  it("has no rules without the tab, and warns about a broken template", () => {
    expect(sampleModel().rules.regex).toBeUndefined();
    expect(parseGuidelines(undefined)).toEqual({ naming: "", keyTemplate: "", keyPattern: "" });
    const broken = sampleModel((grids) => {
      grids.guidelines = [["topic", "language", "value"], ["keyTemplate", "", "{feature"]];
    });
    expect(broken.warnings).toEqual(['The key template has a "{" without a matching "}". (guidelines tab)']);
  });
});
