import Foundation
import NaturalLanguage

struct EPUBAlignmentResult: Sendable {
    var segments: [TranscriptSegment]
    var assessment: EPUBAlignmentAssessment
}

enum Aligner {
    private static let individualTrustThreshold = 0.68
    private static let minimumDocumentWords = 60
    private static let minimumDocumentSentences = 4

    /// Compatibility entry point for callers without book metadata. Content anchors still
    /// have to establish document-level trust before any EPUB wording can be displayed.
    static func align(segments: [TranscriptSegment], ebookText: String) -> [TranscriptSegment] {
        align(
            segments: segments,
            document: EPUBDocument(text: ebookText, title: nil, author: nil),
            expectedMetadata: .init(title: "", author: nil)
        ).segments
    }

    static func align(
        segments: [TranscriptSegment],
        document: EPUBDocument?,
        expectedMetadata: EPUBBookMetadata,
        continueAfterWrongBookPreflight: Bool = false
    ) -> EPUBAlignmentResult {
        guard let document else {
            return result(
                segments: segments,
                status: .unprocessable,
                reason: "The EPUB could not be opened or extracted.",
                metrics: .empty
            )
        }

        let ebookSentences = EPUBParser.sentences(from: document.text)
        let extractedWordCount = document.wordCount
        guard extractedWordCount >= minimumDocumentWords,
              ebookSentences.count >= minimumDocumentSentences
        else {
            var metrics = EPUBAlignmentMetrics.empty
            metrics.extractedWordCount = extractedWordCount
            metrics.extractedSentenceCount = ebookSentences.count
            return result(
                segments: segments,
                status: .unprocessable,
                reason: "The EPUB does not contain enough readable book text.",
                metrics: metrics
            )
        }

        let passages = makePassages(ebookSentences)
        let index = CandidateIndex(passages: passages)
        let eligibleIndices = segments.indices.filter { tokenize(segments[$0].spokenText).count >= 3 }
        let anchorIndices = sampledIndices(from: eligibleIndices, limit: 12)
        let eligibleIndexSet = Set(eligibleIndices)
        var comparisonCount = 0
        var matchedAnchors = 0
        for segmentIndex in anchorIndices {
            if anchorMatches(
                segmentIndex: segmentIndex,
                segments: segments,
                eligibleIndices: eligibleIndexSet,
                passages: passages,
                index: index,
                comparisonCount: &comparisonCount
            ) {
                matchedAnchors += 1
            }
        }

        let anchorCoverage = anchorIndices.isEmpty
            ? 0
            : Double(matchedAnchors) / Double(anchorIndices.count)
        let titleSimilarity = metadataSimilarity(expectedMetadata.title, document.title)
        let authorSimilarity = metadataSimilarity(expectedMetadata.author, document.author)
        let metadataMismatch = [titleSimilarity, authorSimilarity]
            .compactMap { $0 }
            .contains { $0 < 0.25 }

        var preflightMetrics = EPUBAlignmentMetrics.empty
        preflightMetrics.extractedWordCount = extractedWordCount
        preflightMetrics.extractedSentenceCount = ebookSentences.count
        preflightMetrics.sampledAnchorCount = anchorIndices.count
        preflightMetrics.matchedAnchorCount = matchedAnchors
        preflightMetrics.titleSimilarity = titleSimilarity
        preflightMetrics.authorSimilarity = authorSimilarity
        preflightMetrics.candidateComparisons = comparisonCount

        let wrongBookPreflight = anchorIndices.count >= 3
            && (anchorCoverage < 0.25 || (metadataMismatch && anchorCoverage < 0.5))
        if wrongBookPreflight, !continueAfterWrongBookPreflight {
            return result(
                segments: segments,
                status: .wrongBookLikely,
                reason: "Sampled audiobook passages do not match this EPUB.",
                metrics: preflightMetrics
            )
        }

        var aligned = segments
        var usedSentenceIndices = Set<Int>()
        var cursor = 0
        var matched: [AlignmentEvidence] = []
        var eligiblePosition = 0
        while eligiblePosition < eligibleIndices.count {
            let segmentIndex = eligibleIndices[eligiblePosition]
            if eligiblePosition + 1 < eligibleIndices.count {
                let nextSegmentIndex = eligibleIndices[eligiblePosition + 1]
                if nextSegmentIndex == segmentIndex + 1 {
                    let combined = tokenize(
                        segments[segmentIndex].spokenText + " " + segments[nextSegmentIndex].spokenText
                    )
                    if let windowMatch = bestMatch(
                        spoken: combined,
                        passages: passages,
                        index: index,
                        cursor: cursor,
                        usedSentenceIndices: usedSentenceIndices,
                        comparisonCount: &comparisonCount
                    ), windowMatch.score >= individualTrustThreshold,
                       windowMatch.passage.startIndex == windowMatch.passage.endIndex {
                        usedSentenceIndices.insert(windowMatch.passage.startIndex)
                        cursor = windowMatch.passage.endIndex + 1
                        matched.append(AlignmentEvidence(
                            segmentIndices: [segmentIndex, nextSegmentIndex],
                            passage: windowMatch.passage,
                            score: windowMatch.score
                        ))
                        eligiblePosition += 2
                        continue
                    }
                }
            }

            let spoken = tokenize(segments[segmentIndex].spokenText)
            if let match = bestMatch(
                spoken: spoken,
                passages: passages,
                index: index,
                cursor: cursor,
                usedSentenceIndices: usedSentenceIndices,
                comparisonCount: &comparisonCount
            ), match.score >= 0.52 {
                var copy = aligned[segmentIndex]
                copy.ebookText = match.passage.text
                copy.alignmentScore = match.score
                copy.individualEbookMatchTrusted = match.score >= individualTrustThreshold
                copy.documentEbookUseAllowed = false
                aligned[segmentIndex] = copy
                if copy.individualEbookMatchTrusted == true {
                    usedSentenceIndices.formUnion(match.passage.startIndex...match.passage.endIndex)
                    cursor = match.passage.endIndex + 1
                    matched.append(AlignmentEvidence(
                        segmentIndices: [segmentIndex],
                        passage: match.passage,
                        score: match.score
                    ))
                }
            }
            eligiblePosition += 1
        }

        let trustedScores = matched.map(\.score).sorted()
        let trustedSegmentIndices = Set(matched.flatMap(\.segmentIndices))
        let matchedCoverage = eligibleIndices.isEmpty
            ? 0
            : Double(trustedSegmentIndices.count) / Double(eligibleIndices.count)
        let backwardJumps = zip(matched, matched.dropFirst()).reduce(into: 0) { count, pair in
            if pair.1.passage.startIndex < pair.0.passage.startIndex { count += 1 }
        }
        let backwardJumpLimit = max(1, Int(Double(max(0, matched.count - 1)) * 0.05))
        let orderingIsConsistent = backwardJumps <= backwardJumpLimit
        let longestUnmatched = longestUnmatchedPassage(
            eligibleIndices: eligibleIndices,
            matchedIndices: trustedSegmentIndices
        )
        let median = percentile(trustedScores, fraction: 0.5)
        let lower = percentile(trustedScores, fraction: 0.2)

        let status: EPUBAlignmentStatus
        let reason: String
        if wrongBookPreflight {
            status = .wrongBookLikely
            reason = "Sampled audiobook passages do not match this EPUB."
        } else if eligibleIndices.count >= 3,
           matchedCoverage >= 0.70,
           anchorCoverage >= 0.50,
           median >= 0.72,
           lower >= 0.64,
           orderingIsConsistent,
           longestUnmatched <= max(2, eligibleIndices.count / 3) {
            status = .trusted
            reason = "Sampled content, coverage, score quality, and reading order agree."
        } else if matchedCoverage >= 0.30,
                  median >= 0.68,
                  orderingIsConsistent {
            status = .differentEdition
            reason = "Several ordered passages match, but coverage is too low for this edition to replace speech automatically."
        } else {
            status = .uncertain
            reason = !orderingIsConsistent
                ? "Matching passages appear out of audiobook order."
                : "There is not enough consistent evidence to trust this EPUB."
        }

        let documentUseAllowed = status == .trusted
        for index in aligned.indices where aligned[index].individualEbookMatchTrusted == true {
            aligned[index].documentEbookUseAllowed = documentUseAllowed
        }
        let metrics = EPUBAlignmentMetrics(
            extractedWordCount: extractedWordCount,
            extractedSentenceCount: ebookSentences.count,
            sampledAnchorCount: anchorIndices.count,
            matchedAnchorCount: matchedAnchors,
            matchedCoverage: matchedCoverage,
            medianScore: median,
            lowerPercentileScore: lower,
            backwardJumps: backwardJumps,
            longestUnmatchedPassage: longestUnmatched,
            titleSimilarity: titleSimilarity,
            authorSimilarity: authorSimilarity,
            candidateComparisons: comparisonCount,
            detailedAlignmentPerformed: true
        )
        return result(segments: aligned, status: status, reason: reason, metrics: metrics)
    }

    static func tokenize(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = folded
        let tokens = tokenizer.tokens(for: folded.startIndex..<folded.endIndex)
            .map { String(folded[$0]) }
            .filter { token in
                token.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
            }
            .map(normalizeNumber)
        if !tokens.isEmpty { return tokens }

        let scalars = folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(scalars).split(separator: " ").map(String.init).map(normalizeNumber)
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
        if lengthRatio < 0.55 {
            return f1 * 0.35
        }
        return 0.7 * f1 + 0.3 * prefix
    }

    private static func result(
        segments: [TranscriptSegment],
        status: EPUBAlignmentStatus,
        reason: String,
        metrics: EPUBAlignmentMetrics
    ) -> EPUBAlignmentResult {
        EPUBAlignmentResult(
            segments: segments,
            assessment: EPUBAlignmentAssessment(status: status, reason: reason, metrics: metrics)
        )
    }

    private struct Passage: Sendable {
        var startIndex: Int
        var endIndex: Int
        var text: String
        var tokens: [String]
    }

    private struct Match {
        var passage: Passage
        var score: Double
    }

    private struct AlignmentEvidence {
        var segmentIndices: [Int]
        var passage: Passage
        var score: Double
    }

    private struct CandidateIndex {
        var passageIDsByToken: [String: [Int]] = [:]

        init(passages: [Passage]) {
            for (passageID, passage) in passages.enumerated() {
                for token in Set(passage.tokens) {
                    passageIDsByToken[token, default: []].append(passageID)
                }
            }
        }
    }

    private static func makePassages(_ sentences: [String]) -> [Passage] {
        var passages: [Passage] = []
        passages.reserveCapacity(sentences.count * 2)
        for start in sentences.indices {
            for length in 1...2 {
                let end = start + length - 1
                guard sentences.indices.contains(end) else { continue }
                let text = sentences[start...end].joined(separator: " ")
                passages.append(Passage(
                    startIndex: start,
                    endIndex: end,
                    text: text,
                    tokens: tokenize(text)
                ))
            }
        }
        return passages
    }

    private static func bestMatch(
        spoken: [String],
        passages: [Passage],
        index: CandidateIndex,
        cursor: Int?,
        usedSentenceIndices: Set<Int>,
        comparisonCount: inout Int
    ) -> Match? {
        let rarityLimit = max(3, passages.count / 5)
        let informativeTokens = Set(spoken).filter {
            guard let count = index.passageIDsByToken[$0]?.count else { return false }
            return count <= rarityLimit
        }.sorted {
            (index.passageIDsByToken[$0]?.count ?? Int.max) < (index.passageIDsByToken[$1]?.count ?? Int.max)
        }
        var candidateIDs = Set(informativeTokens.prefix(8).flatMap { index.passageIDsByToken[$0] ?? [] })
        if let cursor {
            for (passageID, passage) in passages.enumerated()
            where passage.startIndex >= max(0, cursor - 4) && passage.startIndex <= cursor + 14 {
                candidateIDs.insert(passageID)
            }
        }

        var best: Match?
        for passageID in candidateIDs.sorted() {
            let passage = passages[passageID]
            guard !usedSentenceIndices.contains(where: { passage.startIndex...passage.endIndex ~= $0 }) else {
                continue
            }
            comparisonCount += 1
            let score = similarity(spoken, passage.tokens)
            if best == nil || score > best!.score {
                best = Match(passage: passage, score: score)
            }
        }
        return best
    }

    private static func anchorMatches(
        segmentIndex: Int,
        segments: [TranscriptSegment],
        eligibleIndices: Set<Int>,
        passages: [Passage],
        index: CandidateIndex,
        comparisonCount: inout Int
    ) -> Bool {
        let individual = bestMatch(
            spoken: tokenize(segments[segmentIndex].spokenText),
            passages: passages,
            index: index,
            cursor: nil,
            usedSentenceIndices: [],
            comparisonCount: &comparisonCount
        )
        if (individual?.score ?? 0) >= individualTrustThreshold { return true }

        for neighbourIndex in [segmentIndex - 1, segmentIndex + 1]
        where eligibleIndices.contains(neighbourIndex) {
            let firstIndex = min(segmentIndex, neighbourIndex)
            let secondIndex = max(segmentIndex, neighbourIndex)
            let combined = tokenize(
                segments[firstIndex].spokenText + " " + segments[secondIndex].spokenText
            )
            let window = bestMatch(
                spoken: combined,
                passages: passages,
                index: index,
                cursor: nil,
                usedSentenceIndices: [],
                comparisonCount: &comparisonCount
            )
            if let window,
               window.score >= individualTrustThreshold,
               window.passage.startIndex == window.passage.endIndex {
                return true
            }
        }
        return false
    }

    private static func sampledIndices(from indices: [Int], limit: Int) -> [Int] {
        guard indices.count > limit else { return indices }
        return (0..<limit).map { sample in
            indices[Int((Double(sample) * Double(indices.count - 1) / Double(limit - 1)).rounded())]
        }
    }

    private static func metadataSimilarity(_ expected: String?, _ actual: String?) -> Double? {
        guard let expected = expected?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty,
              let actual = actual?.trimmingCharacters(in: .whitespacesAndNewlines),
              !actual.isEmpty
        else { return nil }
        return similarity(tokenize(expected), tokenize(actual))
    }

    private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded(.down))))
        return sorted[index]
    }

    private static func longestUnmatchedPassage(
        eligibleIndices: [Int],
        matchedIndices: Set<Int>
    ) -> Int {
        var longest = 0
        var current = 0
        for index in eligibleIndices {
            if matchedIndices.contains(index) {
                current = 0
            } else {
                current += 1
                longest = max(longest, current)
            }
        }
        return longest
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
