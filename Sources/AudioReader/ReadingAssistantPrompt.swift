import Foundation

struct LLMTaskPrompt: Equatable, Sendable {
    var system: String
    var user: String
}

struct ChapterSummaryPresentation: Codable, Equatable, Sendable {
    struct Concept: Codable, Equatable, Sendable {
        let name: String
        let explanation: String
    }

    let overview: String
    let keyPoints: [String]
    let charactersOrIdeas: [String]
    let keyConcepts: [Concept]
    let themes: [String]

    static func parse(_ response: String) throws -> ChapterSummaryPresentation {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if trimmed.hasPrefix("```") {
            var lines = trimmed.components(separatedBy: .newlines)
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
                lines.removeLast()
            }
            json = lines.joined(separator: "\n")
        } else {
            json = trimmed
        }

        do {
            return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
        } catch {
            throw ChapterSummaryParsingError.invalidResponse
        }
    }
}

struct ChapterSummaryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var summary: ChapterSummaryPresentation
    var language: String
    var status: GlossStatus
    var model: String
    var promptVersion: String = "local"
    var modelPolicyHash: String = "local"
    var sharedCacheEntryID: String? = nil
    var bookID: String?
    var bookTitle: String
    var chapterID: String
    var chapterTitle: String
    var createdAt: Date
    var decidedAt: Date?
    var replacedSummary: ChapterSummaryPresentation?
    var replacedModel: String?

    static func pending(
        summary: ChapterSummaryPresentation,
        language: String,
        model: String,
        bookID: String?,
        bookTitle: String,
        chapterID: String,
        chapterTitle: String,
        replacing existing: ChapterSummaryRecord?,
        assistantResultID: String? = nil,
        promptVersion: String = "local",
        modelPolicyHash: String = "local",
        sharedCacheEntryID: String? = nil,
        createdAt: Date = Date()
    ) -> Self {
        let previousSummary = existing?.status == .accepted
            ? existing?.summary
            : existing?.replacedSummary
        let previousModel = existing?.status == .accepted
            ? existing?.model
            : existing?.replacedModel
        return Self(
            id: assistantResultID ?? existing?.id ?? UUID().uuidString.lowercased(),
            summary: summary,
            language: language,
            status: existing == nil ? .pending : .replaced,
            model: model,
            promptVersion: promptVersion,
            modelPolicyHash: modelPolicyHash,
            sharedCacheEntryID: sharedCacheEntryID,
            bookID: bookID,
            bookTitle: bookTitle,
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            createdAt: createdAt,
            decidedAt: nil,
            replacedSummary: previousSummary,
            replacedModel: previousModel
        )
    }

    func accept(at date: Date = Date()) -> Self {
        var copy = self
        copy.status = .accepted
        copy.decidedAt = date
        copy.replacedSummary = nil
        copy.replacedModel = nil
        return copy
    }

    func reject(at date: Date = Date()) -> Self {
        var copy = self
        if let replacedSummary, let replacedModel {
            copy.summary = replacedSummary
            copy.model = replacedModel
            copy.status = .accepted
            copy.replacedSummary = nil
            copy.replacedModel = nil
        } else {
            copy.status = .rejected
        }
        copy.decidedAt = date
        return copy
    }

    static func makeID(chapterID: String, language: String) -> String {
        "\(chapterID)|\(language)"
    }
}

enum ChapterSummaryParsingError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "The LLM returned an invalid chapter summary. Try summarising the chapter again."
    }
}

struct PromptTemplateCatalog: Codable, Equatable, Sendable {
    let sentenceTranslationSystem: String
    let wordSystem: String
    let chapterSummarySystem: String
    let chapterChatSystem: String
    let heardQuizSystem: String

    static func load() throws -> PromptTemplateCatalog {
        let fileName = "ReadingAssistantPrompts.json"
        let candidates = [
            Bundle.main.url(forResource: "ReadingAssistantPrompts", withExtension: "json"),
            Bundle.main.resourceURL?.appendingPathComponent("AudioReader_AudioReader.bundle/\(fileName)"),
            Bundle.main.bundleURL.appendingPathComponent("AudioReader_AudioReader.bundle/\(fileName)"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/\(fileName)")
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    fileprivate static let shared: PromptTemplateCatalog = {
        do { return try load() }
        catch { preconditionFailure("ReadingAssistantPrompts.json is missing or invalid: \(error.localizedDescription)") }
    }()
}

enum SentenceTranslationContract {
    static let noteCategories = [
        "phrasal_verb", "phrase", "idiom", "challenging_word",
        "challenging_combination", "concept"
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
                                        "category": ["type": "string", "enum": noteCategories],
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
    static func neighbors(
        around target: TranscriptSegment,
        in transcript: Transcript?,
        limit: Int = 10
    ) -> (previous: [String], next: [String]) {
        guard let segments = transcript?.segments,
              let index = segments.firstIndex(where: { $0.id == target.id })
        else {
            return ([], [])
        }
        let start = max(segments.startIndex, index - limit)
        let previous = Array(segments[start..<index].map(\.displayText))
        let nextStart = index + 1
        let end = min(segments.endIndex, nextStart + limit)
        let next = nextStart < end ? Array(segments[nextStart..<end].map(\.displayText)) : []
        return (previous, next)
    }

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
        let contextRadius = max(0, radius)
        if contextRadius == 0 {
            return targets.map { "TARGET id=\($0.id): \($0.displayText)" }.joined(separator: "\n")
        }
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
        sourceLanguage: TranscriptionLanguage = .englishUS,
        readerLevel: ReaderLanguageLevel = .intermediate,
        metadata: String,
        context: String,
        targetIDs: [String]
    ) -> LLMTaskPrompt {
        LLMTaskPrompt(
            system: render(
                PromptTemplateCatalog.shared.sentenceTranslationSystem,
                language: language,
                sourceLanguage: sourceLanguage,
                readerLevel: readerLevel
            ),
            user: """
            \(metadata)

            Target sentences:
            \(context)

            Return results only for these target IDs: \(targetIDs.joined(separator: ", "))
            """
        )
    }

    static func word(
        language: StudyLanguage,
        sourceLanguage: TranscriptionLanguage = .englishUS,
        readerLevel: ReaderLanguageLevel = .intermediate
    ) -> String {
        render(
            PromptTemplateCatalog.shared.wordSystem,
            language: language,
            sourceLanguage: sourceLanguage,
            readerLevel: readerLevel
        )
    }

    static func chapterSummary(
        language: StudyLanguage,
        sourceLanguage: TranscriptionLanguage = .englishUS,
        readerLevel: ReaderLanguageLevel = .intermediate
    ) -> String {
        render(
            PromptTemplateCatalog.shared.chapterSummarySystem,
            language: language,
            sourceLanguage: sourceLanguage,
            readerLevel: readerLevel
        )
    }

    static func chapterChat(
        language: StudyLanguage,
        sourceLanguage: TranscriptionLanguage = .englishUS,
        readerLevel: ReaderLanguageLevel = .intermediate
    ) -> String {
        render(
            PromptTemplateCatalog.shared.chapterChatSystem,
            language: language,
            sourceLanguage: sourceLanguage,
            readerLevel: readerLevel
        )
    }

    /// Builds a retrieval-first quiz from only the resolved sentences the learner has completed.
    static func heardQuiz(
        passage: HeardPassage,
        language: StudyLanguage,
        sourceLanguage: TranscriptionLanguage = .englishUS,
        readerLevel: ReaderLanguageLevel = .intermediate
    ) -> LLMTaskPrompt {
        LLMTaskPrompt(
            system: render(
                PromptTemplateCatalog.shared.heardQuizSystem,
                language: language,
                sourceLanguage: sourceLanguage,
                readerLevel: readerLevel
            ),
            user: """
            Create a short Quick Quiz from this already-heard passage only:
            \(passage.promptInput)

            Do not reveal the answer outside the JSON. Use only supplied HEARD ids as segmentID values.
            """
        )
    }

    private static func render(
        _ template: String,
        language: StudyLanguage,
        sourceLanguage: TranscriptionLanguage,
        readerLevel: ReaderLanguageLevel
    ) -> String {
        let values = [
            "targetLanguage": language.promptName,
            "sourceLanguage": sourceLanguage.promptName,
            "learnerProfile": learnerProfile(language, sourceLanguage: sourceLanguage),
            "readerLevelName": readerLevel.menuLabel,
            "readerLevelGuidance": readerLevel.promptGuidance,
            "sentenceMeaningHeading": GlossTextFormat.sentenceMeaningHeading,
            "examplesHeading": GlossTextFormat.examplesHeading,
            "nonTargetLanguageRule": nonTargetLanguageRule(language)
        ]
        return values.reduce(template) { output, entry in
            output.replacingOccurrences(of: "{{\(entry.key)}}", with: entry.value)
        }
    }

    private static func learnerProfile(
        _ language: StudyLanguage,
        sourceLanguage: TranscriptionLanguage
    ) -> String {
        if language.promptName == sourceLanguage.promptName {
            return "a reader who wants a clear paraphrase and contextual explanation in \(language.promptName)"
        }
        return "a native speaker of \(language.promptName) who is learning \(sourceLanguage.promptName)"
    }

    private static func nonTargetLanguageRule(_ language: StudyLanguage) -> String {
        switch language {
        case .zhHans, .zhHant: ""
        default: "\nDo not use Chinese anywhere in the response."
        }
    }
}
