import Foundation

enum Aligner {
    /// Attach the best-matching ebook sentence to each spoken segment.
    static func align(segments: [TranscriptSegment], ebookText: String) -> [TranscriptSegment] {
        let ebookSentences = EPUBParser.sentences(from: ebookText)
        guard !ebookSentences.isEmpty else { return segments }

        let ebookTokens = ebookSentences.map { tokenize($0) }
        var used = Set<Int>()
        var cursor = 0

        return segments.map { segment in
            let spoken = tokenize(segment.spokenText)
            guard spoken.count >= 3 else { return segment }

            var bestIdx: Int?
            var bestScore: Double = 0
            let windowStart = max(0, cursor - 6)
            let windowEnd = min(ebookSentences.count, cursor + 80)
            func consider(_ range: Range<Int>) {
                for i in range where !used.contains(i) {
                    let score = similarity(spoken, ebookTokens[i])
                    if score > bestScore {
                        bestScore = score
                        bestIdx = i
                    }
                }
            }
            consider(windowStart..<windowEnd)
            if bestScore < 0.52, spoken.count >= 8 {
                consider(0..<ebookSentences.count)
            }
            guard let idx = bestIdx, bestScore >= 0.52 else { return segment }
            used.insert(idx)
            cursor = idx + 1
            var copy = segment
            copy.ebookText = ebookSentences[idx]
            copy.alignmentScore = bestScore
            return copy
        }
    }

    static func tokenize(_ text: String) -> [String] {
        let folded = text.lowercased()
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars)
            .split(separator: " ")
            .map(String.init)
            .map(normalizeNumber)
            .filter { $0.count > 0 }
    }

    static func similarity(_ a: [String], _ b: [String]) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        let sa = Set(a)
        let sb = Set(b)
        let inter = Double(sa.intersection(sb).count)
        let recall = inter / Double(sa.count)
        let precision = inter / Double(sb.count)
        let f1 = (precision + recall) == 0 ? 0 : 2 * precision * recall / (precision + recall)

        let n = min(8, min(a.count, b.count))
        var same = 0
        for i in 0..<n where a[i] == b[i] { same += 1 }
        let prefix = Double(same) / Double(max(n, 1))

        let lengthRatio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        if lengthRatio < 0.55 && prefix < 0.5 {
            return f1 * 0.35
        }
        return 0.7 * f1 + 0.3 * prefix
    }

    private static func normalizeNumber(_ token: String) -> String {
        switch token {
        case "zero": return "0"
        case "one": return "1"
        case "two": return "2"
        case "three": return "3"
        case "four": return "4"
        case "five": return "5"
        case "six": return "6"
        case "seven": return "7"
        case "eight": return "8"
        case "nine": return "9"
        case "ten": return "10"
        case "eleven": return "11"
        case "twelve": return "12"
        case "thirteen": return "13"
        case "fourteen": return "14"
        case "fifteen": return "15"
        case "sixteen": return "16"
        case "seventeen": return "17"
        case "eighteen": return "18"
        case "nineteen": return "19"
        case "twenty": return "20"
        case "thirty": return "30"
        case "forty", "fourty": return "40"
        case "fifty": return "50"
        case "sixty": return "60"
        case "seventy": return "70"
        case "eighty": return "80"
        case "ninety": return "90"
        case "fortieth": return "40th"
        case "eleventh": return "11th"
        case "eighteenth": return "18th"
        default: return token
        }
    }
}
