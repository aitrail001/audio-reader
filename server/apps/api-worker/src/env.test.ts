import { describe, expect, it } from "vitest";
import { parseEnvironment } from "./env";

describe("parseEnvironment", () => {
  it("preserves known environments", () => {
    expect(parseEnvironment("local")).toBe("local");
    expect(parseEnvironment("test")).toBe("test");
    expect(parseEnvironment("staging")).toBe("staging");
    expect(parseEnvironment("production")).toBe("production");
  });

  it("fails closed to production when the value is missing or unknown", () => {
    expect(parseEnvironment(undefined)).toBe("production");
    expect(parseEnvironment("")).toBe("production");
    expect(parseEnvironment("prod")).toBe("production");
    expect(parseEnvironment("Production")).toBe("production");
  });
});
