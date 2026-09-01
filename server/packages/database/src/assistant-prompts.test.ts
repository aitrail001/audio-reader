import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
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
  assembleManagedPrompt,
  validateAssistantPromptDraft,
  validateManagedPromptOutput,
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

  it.each(["sentence", "word", "chapter_batch", "chapter_summary", "chat", "heard_quiz"] as const)(
    "assembles visible editable and enforced layers for %s",
    (subtask) => {
      const assembled = assembleManagedPrompt({
        subtask,
        policySystemPrompt: "Editable operator policy.",
        policyUserPrompt: "Operator layer: {{task}} / {{source}}",
        schemaVersion: "1",
        fields: {
          task: subtask,
          source: "She broke the ice.",
          context: "PREVIOUS: The room was quiet.",
          segments: "s1: She broke the ice.",
          question: "Why did she do that?",
          chapterId: "chapter-7",
          bookTitle: "The Example Book",
          author: "Ada Author",
          chapterTitle: "An Arrival",
          sourceLanguage: "English",
          targetLanguage: "Simplified Chinese",
          learnerLevel: "B1",
          targetIds: "s1",
        },
      });

      expect(assembled.validation.valid).toBe(true);
      expect(assembled.editable.system).toBe("Editable operator policy.");
      expect(assembled.enforced.taskContract.length).toBeGreaterThan(80);
      expect(assembled.effective.system).toContain("Editable operator policy.");
      for (const expected of [
        "The Example Book",
        "Ada Author",
        "An Arrival",
        "English",
        "Simplified Chinese",
        "B1",
      ]) {
        expect(assembled.effective.user).toContain(expected);
      }
      expect(assembled.outputSchema.type).toBe("object");
      expect(assembled.contractFingerprint).toMatch(/^[a-f0-9]{64}$/);
    },
  );

  it.each([
    ["sentence", "Quoted source (required):", "She broke the ice."],
    ["word", "Sentence context (required):", "TARGET: She broke the ice."],
    ["chapter_batch", "Target sentence block (required):", "TARGET: She broke the ice."],
    ["chapter_summary", "Chapter segments (required):", "She broke the ice."],
    ["chat", "Reader question (required):", "Why did she do that?"],
    ["heard_quiz", "Already-heard segments (required):", "HEARD id=s1"],
  ] as const)(
    "enforces required %s runtime input even when the editable template omits it",
    (subtask, label, expectedValue) => {
      const assembled = assembleManagedPrompt({
        subtask,
        policySystemPrompt: "Editable operator policy.",
        policyUserPrompt: "Operator guidance only.",
        schemaVersion: "1",
        fields: {
          task: subtask,
          source: "She broke the ice.",
          context: "TARGET: She broke the ice.",
          segments: "HEARD id=s1: She broke the ice.",
          question: "Why did she do that?",
          chapterId: "chapter-7",
          bookTitle: "The Example Book",
          author: "Ada Author",
          chapterTitle: "An Arrival",
          sourceLanguage: "English",
          targetLanguage: "Simplified Chinese",
          learnerLevel: "B1",
          targetIds: "s1",
        },
      });

      expect(assembled.validation.valid).toBe(true);
      expect(assembled.enforced.requestContext).toContain(label);
      expect(assembled.effective.user).toContain(expectedValue);
    },
  );

  it.each([
    ["sentence", "source"],
    ["word", "context"],
    ["chapter_batch", "context"],
    ["chapter_summary", "segments"],
    ["chat", "question"],
    ["heard_quiz", "segments"],
  ] as const)("fails %s runtime validation when required %s input is absent", (subtask, field) => {
    const fields: Record<string, string> = {
      task: subtask,
      source: "She broke the ice.",
      context: "TARGET: She broke the ice.",
      segments: "HEARD id=s1: She broke the ice.",
      question: "Why did she do that?",
      sourceLanguage: "English",
      targetLanguage: "Simplified Chinese",
      learnerLevel: "B1",
      targetIds: "s1",
    };
    fields[field] = "  ";

    const assembled = assembleManagedPrompt({
      subtask,
      policySystemPrompt: "Editable operator policy.",
      policyUserPrompt: "Operator guidance only.",
      schemaVersion: "1",
      fields,
    });

    expect(assembled.validation.valid).toBe(false);
    expect(assembled.validation.fieldErrors[`inputs.${field}`]).toContain("required");
  });

  it("keeps the complete sentence-learning contract enforced", () => {
    const assembled = assembleManagedPrompt({
      subtask: "sentence",
      policySystemPrompt: "Keep it short.",
      policyUserPrompt: "{{source}}",
      schemaVersion: "1",
      fields: {
        source: "She broke the ice.",
        bookTitle: "Book",
        author: "Author",
        chapterTitle: "Chapter",
        sourceLanguage: "English",
        targetLanguage: "Chinese",
        learnerLevel: "B1",
      },
    });
    for (const requirement of [
      "phrasal verbs",
      "idioms",
      "level-appropriate phrases",
      "challenging words",
      "challenging combinations",
      "book-specific concepts",
      "exact source-language span",
      "cultural",
      "grammatical",
      "figurative",
      "names",
      "dialogue",
      "register",
    ]) {
      expect(assembled.enforced.taskContract.toLowerCase()).toContain(requirement);
    }
  });

  it("keeps direct-provider and Managed Qwen learning-note semantics aligned", () => {
    const direct = JSON.parse(
      readFileSync("../Sources/AudioReader/Resources/ReadingAssistantPrompts.json", "utf8"),
    ) as { sentenceTranslationSystem: string };
    const managed = SENTENCE_TRANSLATION_INSTRUCTIONS.toLowerCase();
    const directSystem = direct.sentenceTranslationSystem.toLowerCase();
    for (const [directRequirement, managedRequirement] of [
      ["phrasal verbs", "phrasal verbs"],
      ["idioms", "idioms"],
      ["level-appropriate useful phrases", "level-appropriate phrases"],
      ["challenging words", "challenging words"],
      ["challenging combinations", "challenging combinations"],
      ["key concepts", "book-specific concepts"],
      ["exact {{sourcelanguage}} text", "exact source-language span"],
      ["cultural", "cultural"],
      ["grammatical", "grammatical"],
      ["figurative", "figurative"],
    ]) {
      expect(directSystem).toContain(directRequirement);
      expect(managed).toContain(managedRequirement);
    }
  });

  it("rejects unknown placeholders and unsupported schemas before save", () => {
    expect(
      validateAssistantPromptDraft({
        task: "translation",
        userPrompt: "Translate {{source}} and {{secretInstruction}}",
        schemaVersion: "2",
      }),
    ).toEqual({
      valid: false,
      fieldErrors: {
        schemaVersion: "Only schema version 1 is supported.",
        userPrompt: "Unknown placeholder: {{secretInstruction}}.",
      },
    });
  });

  it("validates provider JSON against the server-owned output contract", () => {
    expect(
      validateManagedPromptOutput(
        "sentence",
        '{"translation":"你好","notes":[{"source":"broke the ice","category":"idiom","explanation":"打破沉默"}]}',
      ).valid,
    ).toBe(true);
    expect(validateManagedPromptOutput("sentence", "not json").valid).toBe(false);
    expect(
      validateManagedPromptOutput(
        "word",
        '{"translation":"动词 — 打破沉默","connection":"","examples":[],"notes":[]}',
      ).errors,
    ).toContain("$.examples must contain at least 2 items.");
  });

  it("includes chapter-batch target IDs in the effective message and its fingerprint", () => {
    const fields = {
      task: "chapter_batch",
      source: "One.\nTwo.",
      context: "TARGET id=s1: One.\nTARGET id=s2: Two.",
      targetIds: "s1, s2",
      sourceLanguage: "en",
      targetLanguage: "zh-Hans",
      learnerLevel: "B1",
    };
    const assembled = assembleManagedPrompt({
      subtask: "chapter_batch",
      policySystemPrompt: "Editable operator policy.",
      policyUserPrompt: "Translate the supplied targets.",
      schemaVersion: "1",
      fields,
    });
    const changedTargets = assembleManagedPrompt({
      subtask: "chapter_batch",
      policySystemPrompt: "Editable operator policy.",
      policyUserPrompt: "Translate the supplied targets.",
      schemaVersion: "1",
      fields: { ...fields, targetIds: "s2" },
    });

    expect(assembled.effective.user).toContain("Requested target IDs (required):\ns1, s2");
    expect(assembled.contractFingerprint).not.toBe(changedTargets.contractFingerprint);
  });

  it("enforces a heard-only quiz contract and validates every cited sentence", () => {
    const assembled = assembleManagedPrompt({
      subtask: "heard_quiz",
      policySystemPrompt: "Editable chapter tutor policy.",
      policyUserPrompt: "{{question}}",
      schemaVersion: "1",
      fields: {
        task: "heard_quiz",
        question: "Quiz this completed passage.",
        segments: "HEARD id=s1: First.\nHEARD id=s2: Second.",
        chapterId: "chapter-7",
        bookTitle: "The Example Book",
        author: "Ada Author",
        chapterTitle: "An Arrival",
        sourceLanguage: "en",
        targetLanguage: "zh-Hans",
        learnerLevel: "B1",
      },
    });
    expect(assembled.enforced.taskContract).toContain("already-heard");
    expect(assembled.enforced.taskContract).toContain("exactly four distinct choices");
    expect(assembled.effective.user).toContain("HEARD id=s2");
    expect(assembled.effective.user).toContain("The Example Book");
    expect(assembled.outputSchema).toMatchObject({
      properties: { questions: { minItems: 2, maxItems: 4 } },
    });

    const valid = validateManagedPromptOutput(
      "heard_quiz",
      '{"questions":[{"id":"q1","kind":"comprehension","prompt":"What happened?","choices":["A","B","C","D"],"answerIndex":0,"rationale":"A follows s1.","segmentID":"s1"},{"id":"q2","kind":"sequencing","prompt":"What came next?","choices":["A","B","C","D"],"answerIndex":1,"rationale":"B follows s2.","segmentID":"s2"}]}',
      { allowedSegmentIDs: new Set(["s1", "s2"]) },
    );
    expect(valid.valid).toBe(true);

    for (const invalid of [
      '{"questions":[{"id":"q1","kind":"comprehension","prompt":"What?","choices":["A","A","C","D"],"answerIndex":0,"rationale":"Because.","segmentID":"s1"},{"id":"q2","kind":"sequencing","prompt":"Then?","choices":["A","B","C","D"],"answerIndex":1,"rationale":"Because.","segmentID":"s2"}]}',
      '{"questions":[{"id":"q1","kind":"comprehension","prompt":"What?","choices":["A","B","C","D"],"answerIndex":4,"rationale":"Because.","segmentID":"s1"},{"id":"q2","kind":"sequencing","prompt":"Then?","choices":["A","B","C","D"],"answerIndex":1,"rationale":"Because.","segmentID":"s2"}]}',
      '{"questions":[{"id":"q1","kind":"comprehension","prompt":"What?","choices":["A","B","C","D"],"answerIndex":0,"rationale":"","segmentID":"future"},{"id":"q2","kind":"sequencing","prompt":"Then?","choices":["A","B","C","D"],"answerIndex":1,"rationale":"Because.","segmentID":"s2"}]}',
    ]) {
      expect(
        validateManagedPromptOutput("heard_quiz", invalid, {
          allowedSegmentIDs: new Set(["s1", "s2"]),
        }).valid,
      ).toBe(false);
    }
  });
});
