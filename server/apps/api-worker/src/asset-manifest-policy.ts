const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;

export const ASSET_MANIFEST_KINDS = [
  "audio",
  "epub",
  "cover",
  "transcriptRevision",
  "epubReadingPackage",
  "alignmentPackage",
  "mediaAnalysis",
  "transcriptExport",
  "accountExport",
  "assistantArtifact",
  "otherLargeImmutable",
] as const;

export type AssetManifestKind = (typeof ASSET_MANIFEST_KINDS)[number];

export type AssetManifestDraft = {
  kind?: unknown;
  contentType?: unknown;
  encoding?: unknown;
  compressedBytes?: unknown;
  originalBytes?: unknown;
  sha256?: unknown;
  revisionId?: unknown;
  bookId?: unknown;
  chapterId?: unknown;
  segmentCount?: unknown;
  objectKey?: unknown;
};

export type AssetManifestValidation =
  | {
      ok: true;
      value: {
        kind: AssetManifestKind;
        contentType: string;
        encoding: string;
        compressedBytes: number;
        originalBytes: number;
        sha256: string;
        revisionId: string | null;
        bookId: string | null;
        chapterId: string | null;
        segmentCount: number | null;
      };
    }
  | { ok: false; field: string; message: string };

const MAX_COMPRESSED_BYTES = 2 * 1_024 * 1_024 * 1_024;
const MAX_ORIGINAL_BYTES = 4 * 1_024 * 1_024 * 1_024;
const MAX_TRANSCRIPT_BYTES = 64 * 1_024 * 1_024;
const MAX_SEGMENTS = 2_000_000;

/** The API derives the key; accepting one from a client would permit cross-owner writes or SSRF-like URLs. */
export function contentAddressedObjectKey(
  ownerId: string,
  kind: AssetManifestKind,
  sha256: string,
): string {
  if (!UUID_PATTERN.test(ownerId) || !ASSET_MANIFEST_KINDS.includes(kind) || !SHA256_PATTERN.test(sha256)) {
    throw new Error("invalid object identity");
  }
  return `private/v2/${ownerId}/${kind}/${sha256}`;
}

export function pendingUploadObjectKey(ownerId: string, uploadId: string): string {
  if (!UUID_PATTERN.test(ownerId) || !UUID_PATTERN.test(uploadId)) {
    throw new Error("invalid pending upload identity");
  }
  return `private/v2/${ownerId}/pending/${uploadId}`;
}

export function validateAssetManifestDraft(input: AssetManifestDraft): AssetManifestValidation {
  if (input.objectKey !== undefined) {
    return { ok: false, field: "objectKey", message: "objectKey is server-generated." };
  }
  if (typeof input.kind !== "string" || !isAssetManifestKind(input.kind)) {
    return { ok: false, field: "kind", message: "kind is unsupported." };
  }
  if (
    typeof input.contentType !== "string" ||
    !/^[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*$/i.test(input.contentType) ||
    input.contentType.length > 200
  ) {
    return { ok: false, field: "contentType", message: "contentType is required." };
  }
  if (typeof input.encoding !== "string" || input.encoding.trim() === "") {
    return { ok: false, field: "encoding", message: "encoding is required." };
  }
  if (input.encoding !== "identity" && input.encoding !== "identity-json-v1") {
    return {
      ok: false,
      field: "encoding",
      message: "Compressed encodings are not accepted until bounded server-side decoding is available.",
    };
  }
  if (input.kind !== "transcriptRevision" && input.encoding !== "identity") {
    return { ok: false, field: "encoding", message: "This asset kind requires identity encoding." };
  }
  if (!boundedInteger(input.compressedBytes, 1, MAX_COMPRESSED_BYTES)) {
    return { ok: false, field: "compressedBytes", message: "compressedBytes is invalid." };
  }
  if (!boundedInteger(input.originalBytes, input.compressedBytes, MAX_ORIGINAL_BYTES)) {
    return { ok: false, field: "originalBytes", message: "originalBytes is invalid." };
  }
  if (input.encoding.startsWith("identity") && input.originalBytes !== input.compressedBytes) {
    return {
      ok: false,
      field: "originalBytes",
      message: "Identity-encoded assets must declare equal compressed and original sizes.",
    };
  }
  if (typeof input.sha256 !== "string" || !SHA256_PATTERN.test(input.sha256)) {
    return { ok: false, field: "sha256", message: "sha256 must be 64 lowercase hex characters." };
  }

  const revisionId = optionalUUID(input.revisionId);
  const bookId = optionalUUID(input.bookId);
  const chapterId = optionalUUID(input.chapterId);
  const segmentCount = input.segmentCount === undefined ? null : input.segmentCount;
  if (input.revisionId !== undefined && revisionId === null) {
    return { ok: false, field: "revisionId", message: "revisionId must be a UUID." };
  }
  if (input.bookId !== undefined && bookId === null) {
    return { ok: false, field: "bookId", message: "bookId must be a UUID." };
  }
  if (input.chapterId !== undefined && chapterId === null) {
    return { ok: false, field: "chapterId", message: "chapterId must be a UUID." };
  }
  if (segmentCount !== null && !boundedInteger(segmentCount, 0, MAX_SEGMENTS)) {
    return { ok: false, field: "segmentCount", message: "segmentCount is invalid." };
  }
  if (input.kind === "transcriptRevision") {
    if (input.encoding !== "identity-json-v1") {
      return {
        ok: false,
        field: "encoding",
        message: "Transcript revisions currently require identity-json-v1 encoding.",
      };
    }
    if (input.compressedBytes > MAX_TRANSCRIPT_BYTES) {
      return { ok: false, field: "compressedBytes", message: "Transcript revision is too large." };
    }
    if (revisionId === null) {
      return { ok: false, field: "revisionId", message: "revisionId is required." };
    }
    if (chapterId === null) {
      return { ok: false, field: "chapterId", message: "chapterId is required." };
    }
    if (segmentCount === null) {
      return { ok: false, field: "segmentCount", message: "segmentCount is required." };
    }
  }
  return {
    ok: true,
    value: {
      kind: input.kind,
      contentType: input.contentType,
      encoding: input.encoding,
      compressedBytes: input.compressedBytes,
      originalBytes: input.originalBytes,
      sha256: input.sha256,
      revisionId,
      bookId,
      chapterId,
      segmentCount,
    },
  };
}

/** Completion verifies the stored private bytes before the manifest can become ready. */
export async function verifyAssetObject(
  manifest: {
    compressedBytes: number;
    sha256: string;
    kind?: AssetManifestKind;
    encoding?: string;
    originalBytes?: number;
    segmentCount?: number | null;
  },
  bytes: Uint8Array,
): Promise<boolean> {
  if (bytes.byteLength !== manifest.compressedBytes) return false;
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const actual = [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  if (actual !== manifest.sha256) return false;
  if (manifest.encoding?.startsWith("identity") === true && manifest.originalBytes !== undefined) {
    if (bytes.byteLength !== manifest.originalBytes) return false;
  }
  if (manifest.kind === "transcriptRevision") {
    if (manifest.encoding !== "identity-json-v1" || bytes.byteLength > MAX_TRANSCRIPT_BYTES) return false;
    try {
      const decoded: unknown = JSON.parse(
        new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes),
      );
      if (typeof decoded !== "object" || decoded === null || Array.isArray(decoded)) return false;
      const segments = (decoded as Record<string, unknown>).segments;
      if (!Array.isArray(segments) || segments.length !== manifest.segmentCount) return false;
    } catch {
      return false;
    }
  }
  return true;
}

/** Verifies provider metadata and bytes incrementally; no whole object is materialized in Worker memory. */
export async function verifyAssetStream(
  manifest: {
    compressedBytes: number;
    sha256: string;
    kind?: AssetManifestKind;
    encoding?: string;
    originalBytes?: number;
    segmentCount?: number | null;
  },
  object: ObjectStream,
): Promise<boolean> {
  if (object.size !== manifest.compressedBytes || object.size > MAX_COMPRESSED_BYTES) {
    await object.body.cancel();
    return false;
  }
  if (object.sha256 !== undefined && object.sha256 !== manifest.sha256) {
    await object.body.cancel();
    return false;
  }
  const hash = new IncrementalSha256();
  const transcript = manifest.kind === "transcriptRevision"
    ? new StreamingTranscriptJSONParser()
    : undefined;
  const reader = object.body.getReader();
  let total = 0;
  try {
    for (;;) {
      const next = await reader.read();
      if (next.done) break;
      total += next.value.byteLength;
      if (total > manifest.compressedBytes || total > MAX_COMPRESSED_BYTES) {
        await reader.cancel();
        return false;
      }
      hash.update(next.value);
      transcript?.update(next.value);
    }
  } catch {
    try { await reader.cancel(); } catch { /* storage already failed */ }
    return false;
  }
  if (total !== manifest.compressedBytes || hash.digestHex() !== manifest.sha256) return false;
  if (manifest.encoding?.startsWith("identity") === true && manifest.originalBytes !== total) return false;
  if (transcript !== undefined) {
    return manifest.encoding === "identity-json-v1"
      && total <= MAX_TRANSCRIPT_BYTES
      && transcript.finish() === manifest.segmentCount;
  }
  return true;
}

type JSONToken =
  | { kind: "string"; value: string }
  | { kind: "primitive" }
  | { kind: "punctuation"; value: "{" | "}" | "[" | "]" | ":" | "," };

type JSONFrame =
  | {
      kind: "object";
      state: "keyOrEnd" | "key" | "colon" | "value" | "commaOrEnd";
      key?: string;
      root: boolean;
    }
  | {
      kind: "array";
      state: "valueOrEnd" | "value" | "commaOrEnd";
      segments: boolean;
    };

/** Incremental JSON tokenizer/parser for transcript objects; it never materializes the document. */
class StreamingTranscriptJSONParser {
  private static readonly maximumDepth = 64;
  private static readonly maximumTokens = 2_000_000;
  private static readonly maximumStringLength = 65_536;
  private static readonly maximumPrimitiveLength = 128;

  private readonly decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });
  private readonly frames: JSONFrame[] = [];
  private lexicalState: "default" | "string" | "escape" | "unicode" | "number" | "literal" = "default";
  private tokenBuffer = "";
  private unicodeBuffer = "";
  private rootState: "value" | "done" = "value";
  private tokenCount = 0;
  private segmentCount = 0;
  private segmentsSeen = false;
  private valid = true;

  update(bytes: Uint8Array): void {
    if (!this.valid) return;
    try {
      this.scan(this.decoder.decode(bytes, { stream: true }));
    } catch {
      this.valid = false;
    }
  }

  finish(): number | undefined {
    try {
      this.scan(this.decoder.decode());
      this.finishPrimitive();
    } catch {
      this.valid = false;
    }
    return this.valid && this.lexicalState === "default" && this.rootState === "done"
      && this.frames.length === 0 && this.segmentsSeen
      ? this.segmentCount
      : undefined;
  }

  private scan(text: string): void {
    for (const character of text) this.scanCharacter(character);
  }

  private scanCharacter(character: string): void {
    if (!this.valid) return;
    if (this.lexicalState === "string") {
      if (character === "\"") {
        this.lexicalState = "default";
        this.emit({ kind: "string", value: this.tokenBuffer });
      } else if (character === "\\") {
        this.lexicalState = "escape";
      } else if (character < " ") {
        this.valid = false;
      } else {
        this.appendString(character);
      }
      return;
    }
    if (this.lexicalState === "escape") {
      const escapes: Record<string, string> = {
        "\"": "\"", "\\": "\\", "/": "/", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t",
      };
      if (character === "u") {
        this.unicodeBuffer = "";
        this.lexicalState = "unicode";
      } else if (Object.hasOwn(escapes, character)) {
        this.appendString(escapes[character] ?? "");
        this.lexicalState = "string";
      } else {
        this.valid = false;
      }
      return;
    }
    if (this.lexicalState === "unicode") {
      if (!/[0-9a-f]/i.test(character)) {
        this.valid = false;
        return;
      }
      this.unicodeBuffer += character;
      if (this.unicodeBuffer.length === 4) {
        this.appendString(String.fromCharCode(Number.parseInt(this.unicodeBuffer, 16)));
        this.lexicalState = "string";
      }
      return;
    }
    if (this.lexicalState === "number") {
      if (/[0-9eE+.-]/.test(character)) {
        this.appendPrimitive(character);
        return;
      }
      this.finishPrimitive();
      this.scanCharacter(character);
      return;
    }
    if (this.lexicalState === "literal") {
      if (/[a-z]/.test(character)) {
        this.appendPrimitive(character);
        return;
      }
      this.finishPrimitive();
      this.scanCharacter(character);
      return;
    }
    if (/\s/.test(character)) return;
    if (character === "\"") {
      this.tokenBuffer = "";
      this.lexicalState = "string";
      return;
    }
    if (character === "{" || character === "}" || character === "[" || character === "]"
        || character === ":" || character === ",") {
      this.emit({ kind: "punctuation", value: character });
      return;
    }
    if (character === "-" || /[0-9]/.test(character)) {
      this.tokenBuffer = character;
      this.lexicalState = "number";
      return;
    }
    if (character === "t" || character === "f" || character === "n") {
      this.tokenBuffer = character;
      this.lexicalState = "literal";
      return;
    }
    this.valid = false;
  }

  private appendString(character: string): void {
    this.tokenBuffer += character;
    if (this.tokenBuffer.length > StreamingTranscriptJSONParser.maximumStringLength) this.valid = false;
  }

  private appendPrimitive(character: string): void {
    this.tokenBuffer += character;
    if (this.tokenBuffer.length > StreamingTranscriptJSONParser.maximumPrimitiveLength) this.valid = false;
  }

  private finishPrimitive(): void {
    if (this.lexicalState === "number") {
      if (!/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$/.test(this.tokenBuffer)) {
        this.valid = false;
      } else {
        this.emit({ kind: "primitive" });
      }
    } else if (this.lexicalState === "literal") {
      if (this.tokenBuffer !== "true" && this.tokenBuffer !== "false" && this.tokenBuffer !== "null") {
        this.valid = false;
      } else {
        this.emit({ kind: "primitive" });
      }
    } else if (this.lexicalState !== "default") {
      this.valid = false;
    }
    if (this.lexicalState === "number" || this.lexicalState === "literal") {
      this.lexicalState = "default";
      this.tokenBuffer = "";
    }
  }

  private emit(token: JSONToken): void {
    this.tokenCount += 1;
    if (this.tokenCount > StreamingTranscriptJSONParser.maximumTokens) {
      this.valid = false;
      return;
    }
    const frame = this.frames.at(-1);
    if (frame === undefined) {
      if (this.rootState !== "value" || token.kind !== "punctuation" || token.value !== "{") {
        this.valid = false;
        return;
      }
      this.rootState = "done";
      this.push({ kind: "object", state: "keyOrEnd", root: true });
      return;
    }
    if (frame.kind === "object") this.consumeObject(frame, token);
    else this.consumeArray(frame, token);
  }

  private consumeObject(frame: Extract<JSONFrame, { kind: "object" }>, token: JSONToken): void {
    if (frame.state === "keyOrEnd" || frame.state === "key") {
      if (token.kind === "punctuation" && token.value === "}" && frame.state === "keyOrEnd") {
        this.close(frame);
      } else if (token.kind === "string") {
        frame.key = token.value;
        frame.state = "colon";
      } else {
        this.valid = false;
      }
      return;
    }
    if (frame.state === "colon") {
      if (token.kind !== "punctuation" || token.value !== ":") this.valid = false;
      else frame.state = "value";
      return;
    }
    if (frame.state === "value") {
      const isSegments = frame.root && frame.key === "segments";
      if (isSegments) {
        if (this.segmentsSeen || token.kind !== "punctuation" || token.value !== "[") {
          this.valid = false;
          return;
        }
        this.segmentsSeen = true;
      }
      frame.state = "commaOrEnd";
      delete frame.key;
      this.startValue(token, isSegments);
      return;
    }
    if (token.kind === "punctuation" && token.value === ",") frame.state = "key";
    else if (token.kind === "punctuation" && token.value === "}") this.close(frame);
    else this.valid = false;
  }

  private consumeArray(frame: Extract<JSONFrame, { kind: "array" }>, token: JSONToken): void {
    if (frame.state === "valueOrEnd" || frame.state === "value") {
      if (token.kind === "punctuation" && token.value === "]" && frame.state === "valueOrEnd") {
        this.close(frame);
        return;
      }
      if (frame.segments && (token.kind !== "punctuation" || token.value !== "{")) {
        this.valid = false;
        return;
      }
      if (frame.segments) this.segmentCount += 1;
      frame.state = "commaOrEnd";
      this.startValue(token, false);
      return;
    }
    if (token.kind === "punctuation" && token.value === ",") frame.state = "value";
    else if (token.kind === "punctuation" && token.value === "]") this.close(frame);
    else this.valid = false;
  }

  private startValue(token: JSONToken, segments: boolean): void {
    if (token.kind === "primitive" || token.kind === "string") return;
    if (token.value === "{") this.push({ kind: "object", state: "keyOrEnd", root: false });
    else if (token.value === "[") this.push({ kind: "array", state: "valueOrEnd", segments });
    else this.valid = false;
  }

  private push(frame: JSONFrame): void {
    this.frames.push(frame);
    if (this.frames.length > StreamingTranscriptJSONParser.maximumDepth) this.valid = false;
  }

  private close(frame: JSONFrame): void {
    if (this.frames.at(-1) !== frame) {
      this.valid = false;
      return;
    }
    this.frames.pop();
  }
}

export function isAssetManifestKind(value: string): value is AssetManifestKind {
  return (ASSET_MANIFEST_KINDS as readonly string[]).includes(value);
}

function boundedInteger(value: unknown, minimum: unknown, maximum: number): value is number {
  return (
    typeof value === "number" &&
    Number.isSafeInteger(value) &&
    typeof minimum === "number" &&
    value >= minimum &&
    value <= maximum
  );
}

function optionalUUID(value: unknown): string | null {
  return typeof value === "string" && UUID_PATTERN.test(value) ? value : null;
}
import { IncrementalSha256 } from "./incremental-sha256";
import type { ObjectStream } from "./object-store";
