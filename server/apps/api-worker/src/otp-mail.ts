const DEFAULT_FROM = "AudioReader <onboarding@resend.dev>";

export type OtpMailer = (input: { to: string; code: string }) => Promise<boolean>;

export function createResendOtpMailer(input: {
  apiKey: string;
  from?: string;
  fetch?: typeof fetch;
}): OtpMailer {
  const fetchImpl = input.fetch ?? fetch;
  const from = input.from?.trim() || DEFAULT_FROM;
  return async ({ to, code }) => {
    const response = await fetchImpl("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        authorization: `Bearer ${input.apiKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        from,
        to: [to],
        subject: "Your AudioReader sign-in code",
        text: [
          `Your AudioReader sign-in code is ${code}.`,
          "",
          "Enter it on the operator console or in the app. It expires in about an hour.",
          "If you did not request this, ignore the email.",
        ].join("\n"),
      }),
    });
    return response.ok;
  };
}
