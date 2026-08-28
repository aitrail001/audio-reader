import { describe, expect, it } from "vitest";
import { createResendOtpMailer } from "./otp-mail";

describe("Resend OTP mailer", () => {
  it("posts a sign-in code without returning it to the client", async () => {
    const seen: { url: string; auth: string | null; body: Record<string, unknown> }[] = [];
    const mailer = createResendOtpMailer({
      apiKey: "re_test",
      from: "AudioReader <onboarding@resend.dev>",
      fetch: (input, init) => {
        const bodyText = typeof init?.body === "string" ? init.body : "";
        seen.push({
          url: typeof input === "string" ? input : input instanceof URL ? input.href : input.url,
          auth: new Headers(init?.headers).get("authorization"),
          body: JSON.parse(bodyText) as Record<string, unknown>,
        });
        return Promise.resolve(new Response(JSON.stringify({ id: "msg_1" }), { status: 200 }));
      },
    });
    await expect(mailer({ to: "ops@example.com", code: "424242" })).resolves.toBe(true);
    expect(seen).toHaveLength(1);
    expect(seen[0]?.url).toBe("https://api.resend.com/emails");
    expect(seen[0]?.auth).toBe("Bearer re_test");
    expect(seen[0]?.body["to"]).toEqual(["ops@example.com"]);
    const text = seen[0]?.body["text"];
    expect(typeof text === "string" ? text : "").toContain("424242");
    expect(seen[0]?.body["subject"]).toBe("Your AudioReader sign-in code");
  });

  it("reports failure when Resend rejects the recipient", async () => {
    const mailer = createResendOtpMailer({
      apiKey: "re_test",
      fetch: () => Promise.resolve(new Response("forbidden", { status: 403 })),
    });
    await expect(mailer({ to: "other@example.com", code: "111111" })).resolves.toBe(false);
  });
});
