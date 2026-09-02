import Foundation
import Testing
@testable import AudioReader

@Suite("Common English known words")
struct CommonEnglishWordsTests {
    @Test("Presets expose each 500-word step through 5,000")
    func presetCounts() {
        #expect(CommonEnglishWordTier.allCases.map(\.rawValue) == Array(stride(from: 500, through: 5_000, by: 500)))
    }

    @Test("Ranked prefixes contain exactly the requested number of families")
    func exactPrefixCounts() {
        let catalog = CommonEnglishWordCatalog.shared

        for tier in CommonEnglishWordTier.allCases {
            #expect(catalog.headwords(first: tier.rawValue).count == tier.rawValue)
        }
        #expect(Set(catalog.headwords(first: 5_000)).count == 5_000)
        #expect(catalog.headwords(first: 5_000).filter { $0.count == 1 }.sorted() == ["a", "i"])
    }

    @Test("Inflected forms resolve to one known headword")
    func inflectedFormsShareHeadword() {
        let catalog = CommonEnglishWordCatalog.shared

        #expect(catalog.headword(for: "do") == "do")
        #expect(catalog.headword(for: "did") == "do")
        #expect(catalog.headword(for: "done") == "do")
        #expect(catalog.headword(for: "was") == "be")
        #expect(catalog.headword(for: "children") == "child")
        #expect(StudyLemma.make(language: "en-US", surface: "Done.")?.form == "do")
        #expect(KnownLemmaRecord(language: "en", form: "did", updatedAt: .distantPast).lemma.form == "do")
    }

    @Test("Non-English and unknown English forms keep their normal identity")
    func unsupportedFormsStayUnchanged() {
        #expect(StudyLemma.make(language: "fr", surface: "Faites.")?.form == "faites")
        #expect(StudyLemma.make(language: "en", surface: "Zyzzyva.")?.form == "zyzzyva")
    }

    @Test("Batch add and remove are idempotent and preserve unrelated words")
    func batchMutationPreservesUnrelatedWords() throws {
        let manual = try #require(StudyLemma.make(language: "en", surface: "zyzzyva"))
        let french = try #require(StudyLemma.make(language: "fr", surface: "bonjour"))
        let common = Set(CommonEnglishWordCatalog.shared.headwords(first: 1_000).map {
            StudyLemma(language: "en", form: $0)
        })
        let original = [
            KnownLemmaRecord(language: manual.language, form: manual.form, updatedAt: .distantPast),
            KnownLemmaRecord(language: french.language, form: french.form, updatedAt: .distantPast),
            KnownLemmaRecord(language: "en", form: "did", updatedAt: .distantPast),
            KnownLemmaRecord(language: "en", form: "do", updatedAt: .distantPast)
        ]

        let added = KnownLemmaStore.setting(common, known: true, in: original, at: Date(timeIntervalSince1970: 10))
        let addedAgain = KnownLemmaStore.setting(common, known: true, in: added, at: Date(timeIntervalSince1970: 20))
        let removed = KnownLemmaStore.setting(common, known: false, in: addedAgain)

        #expect(added.filter { $0.language == "en" }.count == 1_001)
        #expect(addedAgain == added)
        #expect(removed.map(\.lemma) == [manual, french].sorted { $0.language < $1.language })
    }

    @MainActor
    @Test("AppState adds and removes a selected common-word prefix")
    func appStateBatchOperation() async throws {
        let state = AppState(composition: .inMemory())
        state.knownLemmas = [KnownLemmaRecord(language: "en", form: "zyzzyva", updatedAt: .distantPast)]

        let added = try await state.setCommonEnglishWordsKnown(first: 500, known: true)
        #expect(added == 500)
        #expect(state.knownLemmas.contains { $0.form == "do" })
        #expect(state.knownLemmas.contains { $0.form == "zyzzyva" })

        let removed = try await state.setCommonEnglishWordsKnown(first: 500, known: false)
        #expect(removed == 500)
        #expect(state.knownLemmas.map(\.form) == ["zyzzyva"])
    }
}
