import { describe, expect, it } from "vitest";
import { buildFigmaUrl, fileNameSlug, parseFigmaUrl } from "../src/shared/figma-url";

describe("Figma links", () => {
  it("builds design links with the node id in URL form", () => {
    expect(buildFigmaUrl("AbC123", "Checkout — Summary (v2)", "12:34")).toBe("https://www.figma.com/design/AbC123/Checkout-Summary-v2?node-id=12-34");
    expect(buildFigmaUrl("AbC123", "", "I1:2;3:4")).toBe("https://www.figma.com/design/AbC123/Untitled?node-id=I1-2%3B3-4");
  });

  it("parses file keys and node ids back", () => {
    expect(parseFigmaUrl("https://www.figma.com/design/AbC123/Checkout?node-id=12-34&t=x")).toEqual({ fileKey: "AbC123", nodeId: "12:34" });
    expect(parseFigmaUrl(buildFigmaUrl("K", "F", "I1:2;3:4"))).toEqual({ fileKey: "K", nodeId: "I1:2;3:4" });
    expect(parseFigmaUrl("https://figma.com/file/OldKey/Name")).toEqual({ fileKey: "OldKey" });
    expect(parseFigmaUrl("https://www.figma.com/proto/P1/Flow?node-id=1-2")).toEqual({ fileKey: "P1", nodeId: "1:2" });
  });

  it("rejects links that are not Figma files", () => {
    expect(parseFigmaUrl("https://example.com/design/AbC/x")).toBeUndefined();
    expect(parseFigmaUrl("https://www.figma.com/community/plugin/1")).toBeUndefined();
    expect(parseFigmaUrl("figma")).toBeUndefined();
    expect(parseFigmaUrl("https://notfigma.com/design/A/B")).toBeUndefined();
  });

  it("slugs file names", () => {
    expect(fileNameSlug("Hej då")).toBe("Hej-da");
  });
});
