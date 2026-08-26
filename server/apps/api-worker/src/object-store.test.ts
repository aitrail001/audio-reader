import { describe, expect, it } from "vitest";
import { createFakeObjectStore } from "./object-store";

describe("fake R2 object store", () => {
  it("stores objects in memory and reports ready", async () => {
    const store = createFakeObjectStore();
    await expect(store.ping()).resolves.toBe("ok");
    await store.put("chapter/1.mp3", new Uint8Array([1, 2, 3]));
    await expect(store.get("chapter/1.mp3")).resolves.toEqual(new Uint8Array([1, 2, 3]));
    await store.delete("chapter/1.mp3");
    await expect(store.get("chapter/1.mp3")).resolves.toBeUndefined();
  });

  it("can simulate R2 unavailability", async () => {
    await expect(createFakeObjectStore({ status: "unavailable" }).ping()).resolves.toBe(
      "unavailable",
    );
  });
});
