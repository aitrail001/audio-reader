/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_API_BASE_URL?: string;
  readonly VITE_ADMIN_VERSION?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

interface TurnstileInstance {
  render(
    element: HTMLElement,
    options: {
      sitekey: string;
      callback: (token: string) => void;
      "error-callback"?: () => void;
      "expired-callback"?: () => void;
      theme?: "light" | "dark" | "auto";
    },
  ): string;
  reset(widgetId: string): void;
}

interface Window {
  turnstile?: TurnstileInstance;
}
