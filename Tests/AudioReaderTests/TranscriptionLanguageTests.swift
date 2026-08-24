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
        settings.targetLanguage = StudyLanguage.zhHans.rawValue

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )

        #expect(decoded.transcriptionLanguage == TranscriptionLanguage.japanese.rawValue)
        #expect(decoded.targetLanguage == StudyLanguage.zhHans.rawValue)
    }

    @Test("Legacy settings keep the former English transcription behavior")
    func migratesLegacySettings() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "transcriptionLanguage")

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.transcriptionLanguage == TranscriptionLanguage.englishUS.rawValue)
    }
}
