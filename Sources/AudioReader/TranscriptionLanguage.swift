import Foundation
import NaturalLanguage

enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case englishUS = "en-US"
    case englishUK = "en-GB"
    case englishAustralia = "en-AU"
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case cantonese = "zh-HK"
    case japanese = "ja-JP"
    case korean = "ko-KR"
    case spanish = "es-ES"
    case french = "fr-FR"
    case german = "de-DE"
    case italian = "it-IT"
    case portugueseBrazil = "pt-BR"
    case dutch = "nl-NL"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    var promptName: String {
        switch self {
        case .englishUS, .englishUK, .englishAustralia: "English"
        case .simplifiedChinese: "Simplified Chinese"
        case .traditionalChinese: "Traditional Chinese"
        case .cantonese: "Cantonese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        case .portugueseBrazil: "Portuguese"
        case .dutch: "Dutch"
        }
    }

    var languageCode: String {
        switch self {
        case .cantonese: "yue"
        default: locale.language.languageCode?.identifier ?? String(rawValue.prefix(2))
        }
    }

    static func matching(localeIdentifier: String) -> TranscriptionLanguage? {
        if let exact = Self(rawValue: localeIdentifier) { return exact }
        let language = Locale(identifier: localeIdentifier).language.languageCode?.identifier
            ?? localeIdentifier.split(separator: "-").first.map(String.init)
        return language.flatMap(matching(languageCode:))
    }

    static func matching(languageCode: String) -> TranscriptionLanguage? {
        let normalized = languageCode.lowercased()
        if normalized == "zh-hant" { return .traditionalChinese }
        if normalized == "zh-hans" { return .simplifiedChinese }
        if normalized == "yue" { return .cantonese }
        return allCases.first { $0.languageCode.lowercased() == normalized }
    }

    var menuLabel: String {
        switch self {
        case .englishUS: "English (US)"
        case .englishUK: "English (UK)"
        case .englishAustralia: "English (Australia)"
        case .simplifiedChinese: "Chinese, Simplified"
        case .traditionalChinese: "Chinese, Traditional"
        case .cantonese: "Cantonese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        case .portugueseBrazil: "Portuguese (Brazil)"
        case .dutch: "Dutch"
        }
    }
}

enum ReaderLanguageLevel: String, CaseIterable, Identifiable, Sendable {
    case beginner
    case intermediate
    case advanced

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .beginner: "Beginner · A1–A2"
        case .intermediate: "Intermediate · B1–B2"
        case .advanced: "Advanced · C1–C2"
        }
    }

    var promptGuidance: String {
        switch self {
        case .beginner:
            "A1–A2: explain essential vocabulary, common combinations, basic grammar, and implied meaning needed to follow the sentence."
        case .intermediate:
            "B1–B2: focus on idioms, phrasal verbs, less common vocabulary, figurative language, and context-dependent combinations."
        case .advanced:
            "C1–C2: be highly selective; focus on nuanced register, literary or technical usage, subtle combinations, cultural implications, and book-specific concepts."
        }
    }
}

struct TranscriptionLanguageMismatch: Equatable, Sendable {
    let transcribedLanguage: TranscriptionLanguage
    let detectedLanguage: TranscriptionLanguage
    let confidence: Double
}

enum TranscriptionLanguageMismatchDetector {
    static func assess(
        transcribedLocale: String,
        detectedLanguageCode: String,
        confidence: Double,
        characterCount: Int
    ) -> TranscriptionLanguageMismatch? {
        guard characterCount >= 160, confidence >= 0.75,
              let transcribed = TranscriptionLanguage.matching(localeIdentifier: transcribedLocale),
              let detected = TranscriptionLanguage.matching(languageCode: detectedLanguageCode),
              transcribed.languageCode != detected.languageCode
        else { return nil }
        return .init(
            transcribedLanguage: transcribed,
            detectedLanguage: detected,
            confidence: confidence
        )
    }

    static func detect(in transcript: Transcript?) -> TranscriptionLanguageMismatch? {
        guard let transcript else { return nil }
        let text = transcript.segments.map(\.displayText).joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first else { return nil }
        return assess(
            transcribedLocale: transcript.locale,
            detectedLanguageCode: hypothesis.key.rawValue,
            confidence: hypothesis.value,
            characterCount: text.count
        )
    }
}
