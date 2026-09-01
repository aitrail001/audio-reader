import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const source = readFileSync(
  join(dirname(fileURLToPath(import.meta.url)), "operator-table.tsx"),
  "utf8",
);

describe("Paper Desk operator grid", () => {
  it("sorts, finds, and expands without a third-party grid", () => {
    expect(source).toContain("Find in this page");
    expect(source).toContain("aria-sort");
    expect(source).toContain("renderExpand");
    expect(source).toContain("leading");
    expect(source).not.toMatch(/ag-grid|AgGrid|@tanstack\/react-table/);
  });
});
