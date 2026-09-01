import { describe, expect, it } from "vitest";
import { createTestApp } from "./app";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";

function headers(): Record<string, string> {
  return { authorization: "Bearer test", "X-Device-Id": DEVICE_ID };
}

describe("retired sync v1", () => {
  it.each([
    ["GET", "/v1/sync/capabilities"],
    ["POST", "/v1/sync/push"],
    ["GET", "/v1/sync/bootstrap?offset=0&limit=100"],
    ["GET", "/v1/sync/pull?cursor=0&limit=100"],
  ])("returns upgrade_required for authenticated %s %s requests", async (method, path) => {
    const response = await createTestApp().fetch(
      new Request(`http://localhost${path}`, {
        method,
        headers: {
          ...headers(),
          ...(method === "POST"
            ? { "content-type": "application/json", "Idempotency-Key": "retired-sync-v1" }
            : {}),
        },
        ...(method === "POST" ? { body: "{}" } : {}),
      }),
    );

    expect(response.status).toBe(426);
    expect(response.headers.get("X-Min-App-Version")).toBe("2.0.0");
    expect(await response.json()).toMatchObject({ code: "upgrade_required" });
  });

  it("authenticates and binds the device before disclosing retirement", async () => {
    const unauthenticated = await createTestApp({ authenticate: () => null }).fetch(
      new Request("http://localhost/v1/sync/pull?cursor=0", {
        headers: { "X-Device-Id": DEVICE_ID },
      }),
    );
    expect(unauthenticated.status).toBe(401);

    const unbound = await createTestApp().fetch(
      new Request("http://localhost/v1/sync/pull?cursor=0", {
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        },
      }),
    );
    expect(unbound.status).toBe(401);
  });
});
