import { describe, expect, it } from "vitest";
import { createFakePrincipal, packageId } from "./index";

describe("@audio-reader/auth", () => {
  it("identifies the auth package", () => {
    expect(packageId).toBe("@audio-reader/auth");
  });

  it("builds a fake authentication principal for tests", () => {
    const principal = createFakePrincipal({ subject: "user-test" });
    expect(principal.subject).toBe("user-test");
    expect(principal.role).toBe("user");
    expect(principal.profileId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    );
  });
});
