import { describe, expect, it } from "vitest";
import {
  CHAPTER_BATCH_TRANSLATION_INSTRUCTIONS,
  CHAPTER_SUMMARY_INSTRUCTIONS,
  DEFAULT_ASSISTANT_PROMPTS,
  DEFAULT_ASSISTANT_USER_PROMPTS,
  SENTENCE_TRANSLATION_INSTRUCTIONS,
  WORD_IN_SENTENCE_INSTRUCTIONS,
  chapterBatchTranslationInstructions,
  chapterSummaryInstructions,
  composeAssistantSystemPrompt,
  defaultAssistantPrompt,
  defaultAssistantUserPrompt,
  clampContextCount,
  formatManagedChapterBatchContext,
  formatManagedSentenceContext,
  isChapterBatchTask,
  isWordTranslationTask,
  promptLanguageName,
  renderAssistantUserPrompt,
  sentenceTranslationInstructions,
  stringList,
  wordInSentenceInstructions,
} from "./assistant-prompts";

describe("assistant prompts", () => {
  it("seeds a distinct default prompt per task", () => {
    expect(defaultAssistantPrompt("translation")).toBe(DEFAULT_ASSISTANT_PROMPTS.translation);
    expect(defaultAssistantPrompt("chapter_summary")).toBe(
      DEFAULT_ASSISTANT_PROMPTS.chapter_summary,
    );
    expect(defaultAssistantPrompt("chat")).toBe(DEFAULT_ASSISTANT_PROMPTS.chat);
    expect(DEFAULT_ASSISTANT_PROMPTS.translation).not.toBe(DEFAULT_ASSISTANT_PROMPTS.chat);
  });

  it("keeps the operator prompt and appends app instructions for chat", () => {
    expect(composeAssistantSystemPrompt("Operator tutor.", "Operator tutor.")).toBe(
      "Operator tutor.",
    );
    expect(composeAssistantSystemPrompt("Operator tutor.", "Translate this chapter.")).toBe(
      "Operator tutor.\n\nAdditional task instructions from the app:\nTranslate this chapter.",
    );
  });

  it("renders user-prompt placeholders and falls back to JSON", () => {
    expect(defaultAssistantUserPrompt("translation")).toBe(
      DEFAULT_ASSISTANT_USER_PROMPTS.translation,
    );
    expect(
      renderAssistantUserPrompt("Translate {{source}} into {{targetLanguage}}.", {
        source: "bonjour",
        targetLanguage: "en",
      }),
    ).toBe("Translate bonjour into en.");
    expect(renderAssistantUserPrompt("  ", { source: "bonjour" })).toBe('{"source":"bonjour"}');
    expect(new Set(Object.values(DEFAULT_ASSISTANT_USER_PROMPTS)).size).toBe(3);
  });

  it("treats word and word_context as in-sentence meaning tasks", () => {
    expect(isWordTranslationTask("word")).toBe(true);
    expect(isWordTranslationTask("word_context")).toBe(true);
    expect(isWordTranslationTask("sentence")).toBe(false);
    expect(isChapterBatchTask("chapter_batch")).toBe(true);
    expect(isChapterBatchTask("sentence")).toBe(false);
    expect(WORD_IN_SENTENCE_INSTRUCTIONS).toContain("examples MUST contain exactly two");
    expect(promptLanguageName("zh-Hans")).toBe("Simplified Chinese (简体中文)");
    expect(promptLanguageName("ja")).toBe("Japanese");
    expect(
      wordInSentenceInstructions({
        sourceLanguage: "en",
        targetLanguage: "zh-Hans",
        learnerLevel: "beginner",
      }),
    ).toContain("Simplified Chinese");
    expect(
      wordInSentenceInstructions({
        sourceLanguage: "en",
        targetLanguage: "zh-Hans",
        learnerLevel: "beginner",
      }),
    ).toContain("App Translate into setting: zh-Hans");
    expect(SENTENCE_TRANSLATION_INSTRUCTIONS).toContain(
      "notes[].explanation MUST be in the target language",
    );
    expect(
      sentenceTranslationInstructions({
        sourceLanguage: "en",
        targetLanguage: "zh-Hans",
        learnerLevel: "intermediate",
      }),
    ).toContain("Simplified Chinese");
    expect(DEFAULT_ASSISTANT_PROMPTS.translation).toContain(
      "note explanations in the target language",
    );
    expect(DEFAULT_ASSISTANT_USER_PROMPTS.translation).toContain("{{context}}");
    expect(CHAPTER_SUMMARY_INSTRUCTIONS).toContain(
      "Write the entire summary in the target language",
    );
    expect(
      chapterSummaryInstructions({
        sourceLanguage: "en",
        targetLanguage: "zh-Hans",
        learnerLevel: "intermediate",
      }),
    ).toContain("Simplified Chinese");
    expect(
      formatManagedSentenceContext({
        source: "She broke the ice.",
        previous: ["The room fell silent.", "Nobody spoke."],
        next: ["Everyone relaxed.", "Then they sat."],
        radius: 1,
      }),
    ).toBe("PREVIOUS: Nobody spoke.\nTARGET: She broke the ice.\nNEXT: Everyone relaxed.");
    expect(
      formatManagedChapterBatchContext({
        sentences: [
          { id: "s1", text: "She broke the ice." },
          { id: "s2", text: "Everyone relaxed." },
        ],
        previous: ["The room fell silent."],
        next: ["Then they sat."],
        radius: 1,
      }),
    ).toBe(
      "PREVIOUS: The room fell silent.\nTARGET id=s1: She broke the ice.\nTARGET id=s2: Everyone relaxed.\nNEXT: Then they sat.",
    );
    expect(
      formatManagedChapterBatchContext({
        sentences: [
          { id: "s1", text: "The room fell silent." },
          { id: "s2", text: "She broke the ice." },
          { id: "s3", text: "Everyone relaxed." },
        ],
        previous: ["Earlier."],
        next: ["Later."],
        radius: 1,
        targetIds: ["s2"],
      }),
    ).toBe(
      "PREVIOUS: Earlier.\nPREVIOUS: The room fell silent.\nTARGET id=s2: She broke the ice.\nNEXT: Everyone relaxed.\nNEXT: Later.",
    );
    expect(CHAPTER_BATCH_TRANSLATION_INSTRUCTIONS).toContain("exactly one object");
    expect(
      chapterBatchTranslationInstructions({
        sourceLanguage: "en",
        targetLanguage: "zh-Hans",
        learnerLevel: "intermediate",
      }),
    ).toContain("Simplified Chinese");
    expect(DEFAULT_ASSISTANT_PROMPTS.translation).toContain("chapter_batch");
    expect(DEFAULT_ASSISTANT_PROMPTS.chapter_summary).toContain(
      "Write every field in the target language",
    );
  });

  it("formats chapter batch context with radius zero and empty neighbor lists", () => {
    expect(
      formatManagedChapterBatchContext({
        sentences: [{ id: "s1", text: "Only target." }],
        previous: ["Ignored previous."],
        next: ["Ignored next."],
        radius: 0,
        targetIds: ["s1"],
      }),
    ).toBe("TARGET id=s1: Only target.");
    expect(
      formatManagedSentenceContext({
        source: "Hello.",
        previous: [],
        next: [],
        radius: 1,
        fallback: "PREVIOUS: Fallback.\nTARGET: Hello.",
      }),
    ).toBe("PREVIOUS: Fallback.\nTARGET: Hello.");
    expect(
      formatManagedSentenceContext({
        source: "Hello.",
        previous: ["Ignored previous."],
        next: ["Ignored next."],
        radius: 0,
      }),
    ).toBe("TARGET: Hello.");
  });

  it("clamps context counts and trims string lists", () => {
    expect(clampContextCount(Number.NaN, 10)).toBe(1);
    expect(clampContextCount(-4, 10)).toBe(0);
    expect(clampContextCount(99, 3)).toBe(3);
    expect(clampContextCount(2.8, 10)).toBe(2);
    expect(stringList("nope")).toEqual([]);
    expect(stringList(["  keep  ", "", "drop-later", "also"], 2)).toEqual([
      "  keep  ",
      "drop-later",
    ]);
    expect(stringList([3, null, "ok"] as unknown[], 10)).toEqual(["ok"]);
    expect(promptLanguageName("")).toBe("");
    expect(promptLanguageName("xx-YY")).toBe("xx-YY");
    expect(promptLanguageName("zh")).toBe("Simplified Chinese (简体中文)");
  });
});
