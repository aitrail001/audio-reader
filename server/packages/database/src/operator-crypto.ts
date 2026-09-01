const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

export type OperatorSecrets = {
  qwenApiKey?: string;
  gcsServiceAccountJson?: string;
  turnstileSecret?: string;
};

export type OperatorCipher = {
  nonce: string;
  ciphertext: string;
};

export async function encryptOperatorSecrets(
  wrappingSecret: string,
  secrets: OperatorSecrets,
): Promise<OperatorCipher> {
  const key = await deriveKey(wrappingSecret);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv },
      key,
      textEncoder.encode(JSON.stringify(secrets)),
    ),
  );
  return { nonce: bytesToBase64(iv), ciphertext: bytesToBase64(sealed) };
}

export async function decryptOperatorSecrets(
  wrappingSecret: string,
  cipher: OperatorCipher,
): Promise<OperatorSecrets> {
  const key = await deriveKey(wrappingSecret);
  const iv = base64ToBytes(cipher.nonce);
  const sealed = base64ToBytes(cipher.ciphertext);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, sealed);
  const parsed: unknown = JSON.parse(textDecoder.decode(plain));
  if (!isRecord(parsed)) {
    return {};
  }
  return {
    ...(typeof parsed.qwenApiKey === "string" ? { qwenApiKey: parsed.qwenApiKey } : {}),
    ...(typeof parsed.gcsServiceAccountJson === "string"
      ? { gcsServiceAccountJson: parsed.gcsServiceAccountJson }
      : {}),
    ...(typeof parsed.turnstileSecret === "string"
      ? { turnstileSecret: parsed.turnstileSecret }
      : {}),
  };
}

async function deriveKey(wrappingSecret: string) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    textEncoder.encode(`audio-reader-operator:${wrappingSecret}`),
  );
  return crypto.subtle.importKey("raw", digest, "AES-GCM", false, ["encrypt", "decrypt"]);
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function base64ToBytes(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
