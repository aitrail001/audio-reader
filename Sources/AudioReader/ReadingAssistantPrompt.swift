import Foundation

struct LLMTaskPrompt: Equatable, Sendable {
    var system: String
    var user: String
}

enum SentenceTranslationContract {
    static let noteCategories = [
        "phrasal_verb",
        "phrase",
        "idiom",
        "challenging_word",
        "challenging_combination",
        "concept"
    ]

    static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "translations": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "id": ["type": "string"],
                            "translation": ["type": "string"],
                            "notes": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "additionalProperties": false,
                                    "properties": [
                                        "source": ["type": "string"],
                                        "category": [
                                            "type": "string",
                                            "enum": noteCategories
                                        ],
                                        "explanation": ["type": "string"]
                                    ],
                                    "required": ["source", "category", "explanation"]
                                ]
                            ]
                        ],
                        "required": ["id", "translation", "notes"]
                    ]
                ]
            ],
            "required": ["translations"]
        ]
    }

    static var submissionTool: [String: Any] {
        [
            "type": "function",
            "name": "submit_translations",
            "description": "Submit one contextual, learner-focused translation result for each requested sentence ID.",
            "parameters": jsonSchema
        ]
    }
}

enum ReadingAssistantPrompt {
    static func sentenceContext(
        around targets: [TranscriptSegment],
        in transcript: Transcript?,
        radius: Int
    ) -> String {
        guard let segments = transcript?.segments, !segments.isEmpty else {
            return targets.map { "TARGET id=\($0.id): \($0.displayText)" }.joined(separator: "\n")
        }
        let targetIDs = Set(targets.map(\.id))
        let targetIndices = segments.indices.filter { targetIDs.contains(segments[$0].id) }
        guard !targetIndices.isEmpty else {
            return targets.map { "TARGET id=\($0.id): \($0.displayText)" }.joined(separator: "\n")
        }
        let contextRadius = max(1, radius)
        var includedIndices = Set<Int>()
        for index in targetIndices {
            includedIndices.formUnion(
                max(0, index - contextRadius)...min(segments.count - 1, index + contextRadius)
            )
        }
        let firstTargetIndex = targetIndices.min() ?? 0
        return includedIndices.sorted().map { index in
            let segment = segments[index]
            if targetIDs.contains(segment.id) {
                return "TARGET id=\(segment.id): \(segment.displayText)"
            }
            let relation = index < firstTargetIndex ? "PREVIOUS" : "NEXT"
            return "\(relation): \(segment.displayText)"
        }.joined(separator: "\n")
    }

    static func sentenceTranslation(
        language: StudyLanguage,
        metadata: String,
        context: String,
        targetIDs: [String]
    ) -> LLMTaskPrompt {
        LLMTaskPrompt(
            system: sentenceTranslationSystem(language: language),
            user: """
            \(metadata)

            Previous, target, and next sentence context:
            \(context)

            Return results only for these target IDs: \(targetIDs.joined(separator: ", "))
            """
        )
    }

    static func word(language: StudyLanguage) -> String {
        """
        You are an English-learning tutor helping \(learnerProfile(language)).
        Apple Dictionary already lists every sense of the word. Do not repeat that list.
        Explain only the meaning of this word, or the phrase it belongs to, as used in this sentence.

        Write every explanation and example translation in \(language.promptName). Keep the new example sentences themselves in English.
        The uppercase English headings below are fixed app UI labels; copy them exactly.

        Output exactly this layout, nothing before or after it:

        \(GlossTextFormat.sentenceMeaningHeading)
        <part of speech in this sentence, in \(language.promptName)> — <short contextual meaning in \(language.promptName)>
        <if it belongs to a phrasal verb, phrase, idiom, challenging combination, or book-specific concept, explain that connection in \(language.promptName)>

        \(GlossTextFormat.examplesHeading)
        • <new English sentence using this same sense>
          <translation of that example in \(language.promptName)>
        • <second short English example using the same sense>
          <translation in \(language.promptName)>

        Rules:
        - Select the sense that fits the supplied sentence and nearby book context.
        - Highlight cross-language difficulty that is especially relevant to a native speaker of the selected language.
        - Keep examples short, natural, and substitutable for this sense.
        - Add no extra commentary.\(nonTargetLanguageRule(language))
        """
    }

    static func chapterSummary(language: StudyLanguage) -> String {
        """
        You are a reading companion and English-learning tutor helping \(learnerProfile(language)).
        Summarise the supplied audiobook chapter in \(language.promptName) without inventing details.

        Use concise headings and bullets to cover:
        - the main events or arguments, important characters or ideas, and themes;
        - key challenging concepts whose meaning depends on the book or chapter context;
        - a selective English language guide containing important phrasal verbs, phrases, idioms, challenging words, and challenging combinations from the chapter.

        For every language item, retain the exact English source text and explain its contextual meaning in \(language.promptName). Select items that are particularly useful or difficult for this reader's mother-language background rather than producing a generic dictionary list.\(nonTargetLanguageRule(language))
        """
    }

    static func chapterChat(language: StudyLanguage) -> String {
        """
        You are a reading companion and English-learning tutor helping \(learnerProfile(language)).
        Answer in \(language.promptName) unless the reader explicitly asks for another language.
        Ground the answer in the supplied book metadata and nearby previous and next sentences. Clearly say when the context is insufficient.
        When a language or concept is relevant to the question, explain the exact English wording, including phrasal verbs, phrases, idioms, challenging words or combinations, and book-specific concepts that may be difficult for this reader's mother-language background.\(nonTargetLanguageRule(language))
        """
    }

    private static func sentenceTranslationSystem(language: StudyLanguage) -> String {
        """
        You are a literary translator and English-learning tutor helping \(learnerProfile(language)).
        Translate each requested English target sentence naturally into \(language.promptName). Use the book metadata plus the previous and next sentences to resolve references, tone, implied meaning, and context, but return a result only for each requested target ID.

        For every target sentence, return:
        - a faithful, natural translation that preserves names, dialogue, register, and meaning;
        - categorized learner notes covering all phrasal verbs and idioms, plus useful phrases, challenging words, challenging combinations, and key concepts that are likely to hinder a native speaker of the selected language;
        - explanations in \(language.promptName) of the sense used here, including relevant cultural, grammatical, figurative, or book-specific meaning.

        Keep each note's source as exact English text from the target sentence. Be selective with ordinary words, but do not omit an item merely because a native English speaker would find it easy. Judge difficulty for the reader's mother-language background and this book context. Do not turn the response into a generic dictionary or grammar dump.

        Return valid JSON only, matching this exact shape:
        {"translations":[{"id":"supplied target id","translation":"natural translation in \(language.promptName)","notes":[{"source":"exact English text from the target sentence","category":"phrasal_verb | phrase | idiom | challenging_word | challenging_combination | concept","explanation":"contextual explanation in \(language.promptName)"}]}]}
        Use an empty notes array only when the sentence genuinely contains no useful language or concept note. Add no Markdown fences or commentary.\(nonTargetLanguageRule(language))
        """
    }

    private static func learnerProfile(_ language: StudyLanguage) -> String {
        if language == .en {
            return "a reader who wants a plain-English paraphrase and contextual explanation"
        }
        return "a native speaker of \(language.promptName) who is learning English"
    }

    private static func nonTargetLanguageRule(_ language: StudyLanguage) -> String {
        switch language {
        case .zhHans, .zhHant:
            ""
        default:
            "\nDo not use Chinese anywhere in the response."
        }
    }
}
