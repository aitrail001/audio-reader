import { createFakePrincipal } from "@audio-reader/auth";
import { createFakeDatabaseClient } from "@audio-reader/database";
import { describe, expect, it } from "vitest";
import { createTestApp } from "./app";
import { toProductEvent } from "./product-events";

const USER_ID = "00000000-0000-4000-8000-000000000002";
const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";

function expectOpaqueProperty(value: unknown, prefix: "content" | "chapter"): void {
  expect(typeof value).toBe("string");
  if (typeof value === "string") {
    expect(value).toMatch(new RegExp(`^${prefix}-[0-9a-f]{16}$`));
  }
}

describe("product event privacy", () => {
  it("re-sanitizes legacy content identifiers before Activity output", async () => {
    const visible = await toProductEvent({
      id: "00000000-0000-4000-8000-000000000099",
      accountId: USER_ID,
      deviceId: DEVICE_ID,
      name: "reading.chapter_opened",
      outcome: "ok",
      requestId: "legacy-row",
      properties: {
        contentId: "legacy-book-id",
        chapterId: "legacy-chapter-id",
        title: "Private legacy title",
      },
      createdAt: "2026-08-30T00:00:00.000Z",
    });
    expectOpaqueProperty(visible.properties?.contentId, "content");
    expectOpaqueProperty(visible.properties?.chapterId, "chapter");
    expect(JSON.stringify(visible)).not.toMatch(/legacy-book-id|legacy-chapter-id|Private legacy/);
  });

  it("drops non-string content identifiers instead of exposing raw values", async () => {
    const visible = await toProductEvent({
      id: "00000000-0000-4000-8000-000000000098",
      accountId: USER_ID,
      deviceId: null,
      name: "reading.chapter_opened",
      outcome: "ok",
      requestId: "legacy-numeric-row",
      properties: { contentId: 12345, chapterId: true },
      createdAt: "2026-08-30T00:00:00.000Z",
    });
    expect(visible.properties).toEqual({});
  });

  it("derives coarse geography and device metadata while rejecting sensitive content", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.bootstrapDevice(USER_ID, {
      deviceId: DEVICE_ID,
      platform: "macos",
      appVersion: "1.3.0",
      buildNumber: "87",
    });
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ accountId: USER_ID }),
    });
    const request = new Request("http://localhost/v1/me/events", {
      method: "POST",
      headers: {
        authorization: "Bearer test",
        "content-type": "application/json",
        "x-device-id": DEVICE_ID,
      },
      body: JSON.stringify({
        events: [
          {
            name: "reading.session.completed",
            properties: {
              bookId: "book-stable-id",
              sourceLanguage: " EN_us ",
              targetLanguage: "zh-hans",
              readerLevel: "Intermediate",
              contentCategory: "fiction",
              feature: "reader",
              title: "Raw book title",
              sentenceText: "Private reading text",
              email: "reader@example.com",
              ipAddress: "203.0.113.42",
              latitude: "-37.8",
              unknownNote: "Could contain arbitrary text",
            },
          },
        ],
      }),
    });
    Object.defineProperty(request, "cf", {
      value: { country: "au", regionCode: "vic", city: "Melbourne", latitude: "-37.8" },
    });

    const response = await app.fetch(request);
    expect(response.status).toBe(202);
    const [stored] = await database.ops.listProductEvents();
    expect(stored?.properties).toMatchObject({
      country: "AU",
      region: "AU-VIC",
      platform: "macos",
      appVersion: "1.3.0",
      buildNumber: "87",
      sourceLanguage: "en-US",
      targetLanguage: "zh-Hans",
      readerLevel: "intermediate",
      contentCategory: "fiction",
      feature: "reader",
    });
    expectOpaqueProperty(stored?.properties.contentId, "content");
    expect(JSON.stringify(stored?.properties)).not.toMatch(
      /book-stable-id|Raw book title|Private reading text|reader@example|203\.0\.113|Melbourne|-37\.8|unknownNote/,
    );
  });
});
