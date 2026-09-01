import Foundation
import Testing
@testable import AudioReader

@Suite("Sentence translation presentation")
struct SentenceTranslationPresentationTests {
    @Test("Listen First hides every translation detail and action")
    func hiddenSentenceKeepsTranslationSecret() {
        let presentation = SentenceTranslationPresentation.resolve(
            isRevealed: false,
            isSelected: true,
            isTranslating: true,
            gloss: gloss(status: .pending, sharedCacheEntryID: "cache-entry")
        )

        #expect(!presentation.showsBlock)
        #expect(!presentation.showsSpinner)
        #expect(presentation.glossText == nil)
        #expect(presentation.status == nil)
        #expect(presentation.actions.isEmpty)
    }

    @Test("An inactive untranslated sentence has no translation block")
    func inactiveSentenceWithoutGlossStaysCompact() {
        let presentation = SentenceTranslationPresentation.resolve(
            isRevealed: true,
            isSelected: false,
            isTranslating: false,
            gloss: nil
        )

        #expect(!presentation.showsBlock)
        #expect(!presentation.showsSpinner)
        #expect(presentation.glossText == nil)
        #expect(presentation.status == nil)
        #expect(presentation.actions.isEmpty)
    }

    @Test("Only a selected idle untranslated sentence offers Translate")
    func selectedSentenceOffersTranslateUntilWorkStarts() {
        let idle = SentenceTranslationPresentation.resolve(
            isRevealed: true,
            isSelected: true,
            isTranslating: false,
            gloss: nil
        )
        let translating = SentenceTranslationPresentation.resolve(
            isRevealed: true,
            isSelected: true,
            isTranslating: true,
            gloss: nil
        )
        let translatingAfterFocusMoves = SentenceTranslationPresentation.resolve(
            isRevealed: true,
            isSelected: false,
            isTranslating: true,
            gloss: nil
        )

        #expect(idle.showsBlock)
        #expect(!idle.showsSpinner)
        #expect(idle.actions == [.translate])
        #expect(translating.showsBlock)
        #expect(translating.showsSpinner)
        #expect(translating.actions.isEmpty)
        #expect(translatingAfterFocusMoves.showsBlock)
        #expect(translatingAfterFocusMoves.showsSpinner)
        #expect(translatingAfterFocusMoves.actions.isEmpty)
    }

    @Test("Pending gloss content and status persist while only the active row can review")
    func pendingGlossPersistsOutsideSelection() {
        for draftStatus in [GlossStatus.pending, .edited, .replaced] {
            let pending = gloss(status: draftStatus)
            let inactive = SentenceTranslationPresentation.resolve(
                isRevealed: true,
                isSelected: false,
                isTranslating: false,
                gloss: pending
            )
            let selected = SentenceTranslationPresentation.resolve(
                isRevealed: true,
                isSelected: true,
                isTranslating: false,
                gloss: pending
            )

            #expect(inactive.showsBlock)
            #expect(inactive.glossText == pending.text)
            #expect(inactive.status == .draft(model: pending.model))
            #expect(inactive.actions.isEmpty)
            #expect(selected.glossText == pending.text)
            #expect(selected.status == .draft(model: pending.model))
            #expect(selected.actions == [.accept, .reject, .edit, .retranslate])
        }
    }

    @Test("Accepted cache-backed gloss stays saved and visible outside selection")
    func cachedAcceptedGlossPersistsOutsideSelection() {
        let accepted = gloss(status: .accepted, sharedCacheEntryID: "cache-entry")
        let inactive = SentenceTranslationPresentation.resolve(
            isRevealed: true,
            isSelected: false,
            isTranslating: false,
            gloss: accepted
        )
        let selected = SentenceTranslationPresentation.resolve(
            isRevealed: true,
            isSelected: true,
            isTranslating: false,
            gloss: accepted
        )

        #expect(inactive.showsBlock)
        #expect(inactive.glossText == accepted.text)
        #expect(inactive.status == .saved(model: accepted.model))
        #expect(inactive.actions.isEmpty)
        #expect(selected.actions == [.edit, .retranslate])
    }

    @Test("Replacement progress does not hide the saved gloss or expose actions")
    func replacementKeepsExistingGlossVisible() {
        let accepted = gloss(status: .accepted, sharedCacheEntryID: "cache-entry")
        let presentation = SentenceTranslationPresentation.resolve(
            isRevealed: true,
            isSelected: true,
            isTranslating: true,
            gloss: accepted
        )

        #expect(presentation.showsBlock)
        #expect(presentation.showsSpinner)
        #expect(presentation.glossText == accepted.text)
        #expect(presentation.status == .saved(model: accepted.model))
        #expect(presentation.actions.isEmpty)
    }

    private func gloss(status: GlossStatus, sharedCacheEntryID: String? = nil) -> GlossEntry {
        GlossEntry(
            id: "gloss-\(status.rawValue)",
            kind: .sentence,
            language: "ko",
            source: "A sentence.",
            context: nil,
            text: "번역문.",
            status: status,
            model: "managed-model",
            sharedCacheEntryID: sharedCacheEntryID,
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}
