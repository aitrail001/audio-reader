import { describe, expect, it } from "vitest";
import {
  DEFAULT_ASSISTANT_PROMPTS,
  composeAssistantSystemPrompt,
  defaultAssistantPrompt,
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
});
