import Foundation
import Testing
@testable import AudioReader

@Suite("Multilingual transcription and synchronized reading")
struct TranscriptionLanguageTests {
    @Test("Common audiobook languages expose stable speech locale identifiers")
    func exposesAudiobookLanguages() {
        #expect(TranscriptionLanguage.englishUS.locale.identifier == "en-US")
        #expect(TranscriptionLanguage.simplifiedChinese.locale.identifier == "zh-CN")
        #expect(TranscriptionLanguage.traditionalChinese.locale.identifier == "zh-TW")
        #expect(TranscriptionLanguage.japanese.locale.identifier == "ja-JP")
        #expect(TranscriptionLanguage.korean.locale.identifier == "ko-KR")
        #expect(TranscriptionLanguage.spanish.locale.identifier == "es-ES")
        #expect(TranscriptionLanguage.allCases.count >= 12)
    }

    @Test("Audiobook language persists independently from the study language")
    func persistsIndependently() throws {
        var settings = AppSettings.default
        settings.transcriptionLanguage = TranscriptionLanguage.japanese.rawValue
        settings.bookTranscriptionLanguages["spanish-book"] = TranscriptionLanguage.spanish.rawValue
        settings.readerLanguageLevel = ReaderLanguageLevel.advanced.rawValue
        settings.targetLanguage = StudyLanguage.zhHans.rawValue

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )

        #expect(decoded.transcriptionLanguage == TranscriptionLanguage.japanese.rawValue)
        #expect(decoded.bookTranscriptionLanguages["spanish-book"] == TranscriptionLanguage.spanish.rawValue)
        #expect(decoded.readerLanguageLevel == ReaderLanguageLevel.advanced.rawValue)
        #expect(decoded.targetLanguage == StudyLanguage.zhHans.rawValue)
    }

    @MainActor
    @Test("Each book can override the global audiobook language")
    func resolvesPerBookLanguage() {
        let state = AppState()
        let book = Book(
            id: "spanish-book",
            title: "Spanish Test",
            author: nil,
            folderPath: "/tmp/spanish-test",
            coverPath: nil,
            ebookPath: nil,
            chapters: []
        )
        state.settings.transcriptionLanguage = TranscriptionLanguage.englishUS.rawValue
        state.settings.bookTranscriptionLanguages.removeValue(forKey: book.id)

        #expect(state.audiobookLanguage(for: book) == .englishUS)

        state.setAudiobookLanguage(.spanish, for: book)

        #expect(state.audiobookLanguage(for: book) == .spanish)
        #expect(state.settings.bookTranscriptionLanguages[book.id] == TranscriptionLanguage.spanish.rawValue)
    }

    @Test("A confident on-device language mismatch suggests the matching speech locale")
    func detectsLikelyLanguageMismatch() {
        let mismatch = TranscriptionLanguageMismatchDetector.assess(
            transcribedLocale: "en-US",
            detectedLanguageCode: "es",
            confidence: 0.92,
            characterCount: 600
        )

        #expect(mismatch?.transcribedLanguage == .englishUS)
        #expect(mismatch?.detectedLanguage == .spanish)
        #expect(TranscriptionLanguageMismatchDetector.assess(
            transcribedLocale: "en-US",
            detectedLanguageCode: "es",
            confidence: 0.45,
            characterCount: 600
        ) == nil)
        #expect(TranscriptionLanguageMismatchDetector.assess(
            transcribedLocale: "en-US",
            detectedLanguageCode: "en",
            confidence: 0.99,
            characterCount: 600
        ) == nil)
    }

    @Test("Legacy settings keep the former English transcription behavior")
    func migratesLegacySettings() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "transcriptionLanguage")
        object.removeValue(forKey: "bookTranscriptionLanguages")
        object.removeValue(forKey: "readerLanguageLevel")

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.transcriptionLanguage == TranscriptionLanguage.englishUS.rawValue)
        #expect(decoded.bookTranscriptionLanguages.isEmpty)
        #expect(decoded.readerLanguageLevel == ReaderLanguageLevel.intermediate.rawValue)
    }
}
