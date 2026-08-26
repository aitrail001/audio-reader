import { existsSync, readFileSync } from "node:fs";
import { COMMENT_HEADER } from "openapi-typescript";
import { describe, expect, it } from "vitest";
import { defaultGeneratedPath } from "../scripts/codegen";
import type { operations } from "./generated/openapi";

const requiredContractOperations = [
  "bootstrapSession",
  "requestEmailOtp",
  "verifyEmailOtp",
  "pushSyncMutations",
  "pullSyncChanges",
  "adminListUsers",
] as const;

function extractGeneratedOperationIds(source: string): Set<string> {
  const ids = new Set<string>();
  for (const match of source.matchAll(/operations\[\s*["']([^"']+)["']\s*\]/g)) {
    const id = match[1];
    if (id !== undefined) {
      ids.add(id);
    }
  }
  return ids;
}

type RequiredOperation = (typeof requiredContractOperations)[number];
// Tuple wrapper disables distribution so a partial missing set is `false`, not `boolean`.
type RequiredOperationsPresent = [RequiredOperation] extends [keyof operations] ? true : false;

describe("generated OpenAPI types", () => {
  it("includes required auth, sync, and admin operations", () => {
    expect(existsSync(defaultGeneratedPath)).toBe(true);
    const source = readFileSync(defaultGeneratedPath, "utf8");
    expect(source.startsWith(COMMENT_HEADER)).toBe(true);
    const operationIds = extractGeneratedOperationIds(source);
    expect([...operationIds]).toEqual(expect.arrayContaining([...requiredContractOperations]));
  });

  it("types the required operations on the generated operations map", () => {
    const present: RequiredOperationsPresent = true;
    expect(present).toBe(true);
  });
});
