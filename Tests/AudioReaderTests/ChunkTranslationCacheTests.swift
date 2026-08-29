import Foundation
import Testing
@testable import AudioReader
@testable import AudioReaderNetworking

@Suite("Chunk translation and managed cache helpers")
struct ChunkTranslationCacheTests {
    @Test("Aligned blocks match sequential chapter grouping including leftovers")
    func alignedBlocksMatchChapterChunks() {
        let segments = (1...7).map(segment)
        #expect(ChapterTranslationBatch.alignedBlock(
            containing: segments[6],
            in: segments,
            size: 3
        ).map(\.id) == ["segment-7"])
        #expect(ChapterTranslationBatch.alignedBlock(
            containing: segments[5],
            in: segments,
            size: 3
        ).map(\.id) == ["segment-4", "segment-5", "segment-6"])
        let orphan = segment(index: 99)
        #expect(ChapterTranslationBatch.alignedBlock(
            containing: orphan,
            in: segments,
            size: 3
        ).map(\.id) == ["segment-99"])
        #expect(ChapterTranslationBatch.alignedBlock(
            containing: orphan,
            in: [],
            size: 3
        ).map(\.id) == ["segment-99"])
        #expect(ChapterTranslationBatch.alignedBlock(
            containing: segments[0],
            in: segments,
            size: 0
        ).map(\.id) == ["segment-1"])
        #expect(ChapterTranslationBatch.alignedBlock(
            containing: segments[0],
            in: segments,
            size: 1
        ).map(\.id) == ["segment-1"])
        #expect(ChapterTranslationBatch.blocks(segments, size: 0).map(\.count) == Array(repeating: 1, count: 7))
    }

    @Test("Batch results drop empty target IDs and blank translations")
    func chapterResultsSkipUnusableRows() {
        let batch = ProductTranslationBatchResult(
            results: [
                ProductTranslationResult(
                    id: "cache-1",
                    translation: "  第一句。  ",
                    notes: [ProductLearningNote(source: "ice", category: "concept", explanation: "寒冰")],
                    provenance: "generated",
                    policyVersion: "qwen-managed-v1",
                    createdAt: "2026-08-29T00:00:00Z",
                    targetId: "s1",
                    source: "One."
                ),
                ProductTranslationResult(
                    id: "cache-2",
                    translation: "第二句。",
                    notes: [],
                    provenance: "cache_shared_exact",
                    policyVersion: "qwen-managed-v1",
                    createdAt: "2026-08-29T00:00:00Z",
                    targetId: "   ",
                    source: "Two."
                ),
                ProductTranslationResult(
                    id: "cache-3",
                    translation: "   ",
                    notes: [],
                    provenance: "generated",
                    policyVersion: "qwen-managed-v1",
                    createdAt: "2026-08-29T00:00:00Z",
                    targetId: "s3",
                    source: "Three."
                )
            ],
            missingIds: ["s3"]
        )
        let results = ManagedProductLLM.chapterResults(from: batch)
        #expect(results.map(\.id) == ["s1"])
        #expect(results[0].translation == "第一句。")
        #expect(results[0].notes.map(\.source) == ["ice"])
        #expect(ManagedProductLLM.chapterResults(from: ProductTranslationBatchResult(results: [], missingIds: ["s1"])).isEmpty)
        let valid = ManagedProductLLM.chapterResults(from: ProductTranslationBatchResult(
            results: [
                ProductTranslationResult(
                    id: "cache-4",
                    translation: "第二句。",
                    notes: [],
                    provenance: "cache_shared_exact",
                    policyVersion: "qwen-managed-v1",
                    createdAt: "2026-08-29T00:00:00Z",
                    targetId: "s2",
                    source: "Two."
                )
            ],
            missingIds: []
        ))
        #expect(valid.map(\.id) == ["s2"])
        #expect(valid[0].translation == "第二句。")
    }

    @Test("Word meaning text keeps examples and notes optional")
    func wordMeaningTextHandlesSparseNotes() {
        let meaningOnly = ProductTranslationResult(
            id: "cache-word",
            translation: "noun — frozen water",
            notes: [],
            provenance: "generated",
            policyVersion: "qwen-managed-v1",
            createdAt: "2026-08-29T00:00:00Z"
        )
        let text = ManagedProductLLM.wordMeaningText(from: meaningOnly)
        #expect(text.contains(GlossTextFormat.sentenceMeaningHeading))
        #expect(!text.contains(GlossTextFormat.examplesHeading))
        #expect(!text.contains(GlossTextFormat.learningNotesHeading))

        let exampleWithoutGloss = ProductTranslationResult(
            id: "cache-word-2",
            translation: "noun — ice",
            notes: [
                ProductLearningNote(source: "The ice closed.", category: "example", explanation: "  ")
            ],
            provenance: "generated",
            policyVersion: "qwen-managed-v1",
            createdAt: "2026-08-29T00:00:00Z"
        )
        let exampleText = ManagedProductLLM.wordMeaningText(from: exampleWithoutGloss)
        #expect(exampleText.contains(GlossTextFormat.examplesHeading))
        #expect(exampleText.contains("• The ice closed."))
        #expect(!exampleText.contains(GlossTextFormat.learningNotesHeading))
    }

    @Test("Managed Qwen auto-load and chunk translation stay wired on both platforms")
    func wiresCacheHydrationAndChunkTranslation() throws {
        let appState = try source("Sources/AudioReader/AppState.swift")
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let managed = try source("Sources/AudioReader/ManagedProductLLM.swift")

        #expect(appState.contains("func ensureCachedChapterSummary()"))
        #expect(appState.contains("ensureCachedChapterSummary()\n        ensureAutoTranslation()"))
        #expect(appState.contains("func ensureAutoTranslation()"))
        #expect(appState.contains("lookupOnly: true"))
        #expect(appState.contains("if lookupOnly, llmProvider != .managedQwen"))
        #expect(appState.contains("generate: settings.autoTranslate"))
        #expect(appState.contains("contextBefore: ReadingAssistantPrompt.sentenceContext("))
        #expect(appState.contains("refreshIds: Array(forceIDs)"))
        #expect(appState.contains("translateSentenceBlock(around: segment, forceIDs: [segment.id], generate: true)"))
        #expect(playerView.contains("onTranslate: { state.translateSentence(segment) }"))
        #expect(playerView.contains("state.ensureAutoTranslation()"))
        #expect(playerView.contains("state.summarizeChapter(force: true)"))
        #expect(managed.contains("static func translateBatch("))
        #expect(managed.contains("static func lookupSummary("))
        #expect(managed.contains("static func lookupTranslation("))
        #expect(managed.contains("lookupOnly: true"))
        #expect(managed.contains("if case .problem(status: 404, _, _) = error"))
    }

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func segment(index: Int) -> TranscriptSegment {
        TranscriptSegment(
            id: "segment-\(index)",
            start: Double(index),
            end: Double(index + 1),
            words: [
                .init(
                    id: "word-\(index)",
                    text: "Sentence \(index).",
                    start: Double(index),
                    end: Double(index + 1),
                    confidence: nil
                )
            ]
        )
    }
}
