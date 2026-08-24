import Foundation

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
