import Foundation

struct PlaybackCursor: Equatable, Sendable {
    var segmentID: String?
    var wordID: String?
    var word: TranscriptWord?
    var segment: TranscriptSegment?

    static let empty = PlaybackCursor()

    /// Transcript segments are time ordered, so playback ticks locate the active sentence logarithmically.
    static func resolve(segments: [TranscriptSegment], time: TimeInterval) -> PlaybackCursor {
        guard !segments.isEmpty else { return .empty }
        var lower = 0
        var upper = segments.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if segments[middle].start <= time + 0.05 {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let candidateIndex = max(0, lower - 1)
        let candidate = segments[candidateIndex]
        let segment: TranscriptSegment
        if time >= candidate.start - 0.05, time < candidate.end + 0.12 {
            segment = candidate
        } else if candidate.start <= time {
            segment = candidate
        } else {
            return .empty
        }
        let tokens = StudyTokenIndex.tokens(in: segment)
        let word = tokens.last(where: { time >= $0.start && time < $0.end + 0.02 })
            ?? tokens.last(where: { time >= $0.start })
        return PlaybackCursor(
            segmentID: segment.id,
            wordID: word?.id,
            word: word,
            segment: segment
        )
    }
}

struct ChapterStudyPresentation: Identifiable, Equatable, Sendable {
    var id: String
    var chapterTitle: String
    var coverage: ChapterCoverage
    var items: [ChapterStudyItem]
    var hasTranscript: Bool

    static let empty = ChapterStudyPresentation(
        id: "empty",
        chapterTitle: "Chapter words",
        coverage: .empty,
        items: [],
        hasTranscript: false
    )
}

struct ShadowingResult: Equatable, Sendable {
    var expectedTokens: [String]
    var spokenTokens: [String]
    var matchedCount: Int
    var percent: Int
    var missed: [String]
    var extra: [String]

    var caption: String {
        "Spoken \(percent)% · \(missed.count) missed"
    }
}

enum ShadowingScorer {
    static func score(expected: String, spoken: String) -> ShadowingResult {
        let expectedTokens = tokenize(expected)
        let spokenTokens = tokenize(spoken)
        guard !expectedTokens.isEmpty else {
            return ShadowingResult(
                expectedTokens: expectedTokens,
                spokenTokens: spokenTokens,
                matchedCount: 0,
                percent: spokenTokens.isEmpty ? 100 : 0,
                missed: [],
                extra: spokenTokens
            )
        }

        var spokenIndex = 0
        var matched = 0
        var missed: [String] = []
        var extra: [String] = []
        for token in expectedTokens {
            if spokenIndex < spokenTokens.count,
               let found = spokenTokens[spokenIndex...].firstIndex(of: token) {
                extra.append(contentsOf: spokenTokens[spokenIndex..<found])
                spokenIndex = spokenTokens.index(after: found)
                matched += 1
            } else {
                missed.append(token)
            }
        }
        if spokenIndex < spokenTokens.count {
            extra.append(contentsOf: spokenTokens[spokenIndex...])
        }
        let percent = Int((Double(matched) / Double(expectedTokens.count) * 100).rounded())
        return ShadowingResult(
            expectedTokens: expectedTokens,
            spokenTokens: spokenTokens,
            matchedCount: matched,
            percent: percent,
            missed: missed,
            extra: extra
        )
    }

    static func tokenize(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if shouldSplitCharacters(trimmed) {
            return trimmed.map { normalize(String($0)) }.filter { !$0.isEmpty }
        }
        return trimmed.split { $0.isWhitespace || $0.isNewline }
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func shouldSplitCharacters(_ text: String) -> Bool {
        !text.contains(where: \.isWhitespace)
            && text.contains { !$0.isASCII }
    }

    private static func normalize(_ token: String) -> String {
        String(token.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

struct ChapterQuizChoice: Identifiable, Equatable, Hashable, Codable, Sendable {
    var id: String
    var text: String
    var index: Int
}

struct ChapterQuizQuestion: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case cloze
        case sequencing
        case comprehension
    }

    var id: String
    var kind: Kind
    var prompt: String
    var choices: [String]
    var answerIndex: Int
    var rationale: String?
    var segmentID: String?

    var labeledChoices: [ChapterQuizChoice] {
        choices.enumerated().map { offset, text in
            ChapterQuizChoice(id: "\(id)#\(offset)", text: text, index: offset)
        }
    }
}

struct ChapterQuiz: Equatable, Codable, Sendable {
    var questions: [ChapterQuizQuestion]

    func scored(selections: [Int]) -> ChapterQuizResult {
        let total = questions.count
        let correct = zip(questions, selections).reduce(into: 0) { count, pair in
            if pair.1 == pair.0.answerIndex { count += 1 }
        }
        let percent = total == 0 ? 0 : Int((Double(correct) / Double(total) * 100).rounded())
        return ChapterQuizResult(correctCount: correct, total: total, percent: percent)
    }
}

struct ChapterQuizResult: Equatable, Sendable {
    var correctCount: Int
    var total: Int
    var percent: Int

    var caption: String {
        "\(correctCount) of \(total) · \(percent)%"
    }
}

struct ChapterQuizSession: Identifiable, Equatable, Sendable {
    var id: String
    var quiz: ChapterQuiz
    var selections: [Int?]
    var isRevealed: Bool

    init(quiz: ChapterQuiz) {
        id = UUID().uuidString
        self.quiz = quiz
        selections = Array(repeating: nil, count: quiz.questions.count)
        isRevealed = false
    }

    var canScore: Bool {
        selections.count == quiz.questions.count && selections.allSatisfy { $0 != nil }
    }

    mutating func select(_ choiceIndex: Int, at questionIndex: Int) {
        guard !isRevealed,
              selections.indices.contains(questionIndex),
              quiz.questions.indices.contains(questionIndex),
              quiz.questions[questionIndex].choices.indices.contains(choiceIndex)
        else { return }
        selections[questionIndex] = choiceIndex
    }

    func result() -> ChapterQuizResult {
        quiz.scored(selections: selections.map { $0 ?? -1 })
    }

    /// Rationale is feedback after retrieval, never an answer cue before scoring.
    func visibleRationale(for questionIndex: Int) -> String? {
        guard isRevealed, quiz.questions.indices.contains(questionIndex) else { return nil }
        return quiz.questions[questionIndex].rationale
    }
}

enum ListenFirstVisibility: Equatable, Sendable {
    case revealed
    case currentHidden
    case futureHidden

    /// Keeps completed text available while withholding the active and future passage.
    static func resolve(
        segmentID: String,
        orderedSegmentIDs: [String],
        currentSegmentID: String?,
        pausedSegmentID: String?,
        replayRevealedSegmentID: String?
    ) -> Self {
        guard let segmentIndex = orderedSegmentIDs.firstIndex(of: segmentID) else { return .revealed }
        guard let currentSegmentID,
              let currentIndex = orderedSegmentIDs.firstIndex(of: currentSegmentID)
        else { return .futureHidden }
        if segmentIndex < currentIndex { return .revealed }
        if segmentID == pausedSegmentID || segmentID == replayRevealedSegmentID { return .revealed }
        return segmentIndex == currentIndex ? .currentHidden : .futureHidden
    }
}

struct HeardPassage: Equatable, Sendable {
    var segments: [TranscriptSegment]

    /// Selects only resolved transcript sentences completed through the paused boundary.
    static func recent(
        in transcript: Transcript,
        throughSegmentID: String,
        limit: Int = 6
    ) -> HeardPassage? {
        guard let boundary = transcript.segments.firstIndex(where: { $0.id == throughSegmentID }) else {
            return nil
        }
        let count = max(1, limit)
        let lower = max(transcript.segments.startIndex, boundary - count + 1)
        return HeardPassage(segments: Array(transcript.segments[lower...boundary]))
    }

    var promptInput: String {
        segments.enumerated().map { offset, segment in
            "HEARD id=\(segment.id) time=\(Self.clock(segment.start)) order=\(offset + 1): \(segment.displayText)"
        }.joined(separator: "\n")
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

enum HeardQuizResolver {
    /// Invalid model output degrades to the deterministic local quiz over the same bounded passage.
    static func resolve(response: String, passage: HeardPassage, language: String) -> ChapterQuiz {
        if let parsed = try? ChapterQuizParser.parse(response), !parsed.questions.isEmpty {
            let allowedIDs = Set(passage.segments.map(\.id))
            let grounded = parsed.questions.filter { question in
                guard let segmentID = question.segmentID,
                      allowedIDs.contains(segmentID),
                      question.choices.count == 4
                else { return false }
                let normalizedChoices = Set(question.choices.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                })
                return normalizedChoices.count == 4 && !normalizedChoices.contains("")
            }
            if !grounded.isEmpty { return ChapterQuiz(questions: grounded) }
        }
        return ChapterQuizBuilder.build(segments: passage.segments, language: language)
    }
}

enum ChapterQuizParsingError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "The LLM returned an invalid chapter quiz. Try generating the quiz again, or use the local quiz."
    }
}

enum ChapterQuizParser {
    static func parse(_ response: String) throws -> ChapterQuiz {
        let json = stripFences(response)
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        } catch {
            throw ChapterQuizParsingError.invalidResponse
        }
        let questions: [ChapterQuizQuestion] = payload.questions.compactMap { item in
            guard item.choices.count >= 2,
                  item.choices.indices.contains(item.answerIndex),
                  !item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let kind = ChapterQuizQuestion.Kind(rawValue: item.kind ?? "") ?? .comprehension
            return ChapterQuizQuestion(
                id: item.id ?? UUID().uuidString,
                kind: kind,
                prompt: item.prompt,
                choices: item.choices,
                answerIndex: item.answerIndex,
                rationale: item.rationale,
                segmentID: item.segmentID
            )
        }
        guard !questions.isEmpty else { throw ChapterQuizParsingError.invalidResponse }
        return ChapterQuiz(questions: questions)
    }

    private static func stripFences(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private struct Payload: Codable {
        var questions: [Item]

        struct Item: Codable {
            var id: String?
            var prompt: String
            var choices: [String]
            var answerIndex: Int
            var rationale: String?
            var kind: String?
            var segmentID: String?
        }
    }
}

enum ChapterQuizBuilder {
    static func build(
        segments: [TranscriptSegment],
        language: String,
        limit: Int = 6
    ) -> ChapterQuiz {
        let cloze = clozeQuestions(segments: segments, language: language, limit: max(1, limit - 2))
        let sequencing = sequencingQuestions(segments: segments, limit: 2)
        return ChapterQuiz(questions: Array((cloze + sequencing).prefix(max(1, limit))))
    }

    static func spreadIndices(count: Int, take: Int) -> [Int] {
        let n = min(max(take, 0), count)
        guard n > 0, count > 0 else { return [] }
        if n == 1 { return [0] }
        var seen = Set<Int>()
        return (0..<n).compactMap { step in
            let index = Int((Double(step) / Double(n - 1)) * Double(count - 1))
            return seen.insert(index).inserted ? index : nil
        }
    }

    static func pickDistractors(answer: String, pool: [String], count: Int, rotation: Int) -> [String] {
        let candidates = pool.filter { $0.caseInsensitiveCompare(answer) != .orderedSame }
        guard candidates.count >= count else { return [] }
        let start = abs(rotation) % candidates.count
        var picked: [String] = []
        var offset = 0
        while picked.count < count, offset < candidates.count {
            let word = candidates[(start + offset) % candidates.count]
            if !picked.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                picked.append(word)
            }
            offset += 1
        }
        return picked.count == count ? picked : []
    }

    static func clozeQuestions(
        segments: [TranscriptSegment],
        language: String,
        limit: Int
    ) -> [ChapterQuizQuestion] {
        let catalog = contentCatalog(segments: segments, language: language)
        let distractorPool = catalog.map(\.lemma.form)
        guard distractorPool.count >= 4 else { return [] }
        var questions: [ChapterQuizQuestion] = []
        for (rotation, catalogIndex) in spreadIndices(count: catalog.count, take: limit).enumerated() {
            let entry = catalog[catalogIndex]
            let sentence = entry.sentence
            guard let range = StudyTextMatch.firstWholeTokenRange(of: entry.surface, in: sentence) else {
                continue
            }
            let stem = String(sentence[..<range.lowerBound])
                + VocabCloze.blank
                + String(sentence[range.upperBound...])
            let answer = DictionaryLookup.headword(entry.surface)
            let distractors = pickDistractors(
                answer: answer,
                pool: distractorPool,
                count: 3,
                rotation: rotation * 3 + catalogIndex
            )
            guard distractors.count == 3 else { continue }
            let shuffled = (distractors + [answer]).shuffled()
            guard let answerIndex = shuffled.firstIndex(of: answer) else { continue }
            questions.append(
                ChapterQuizQuestion(
                    id: "cloze-\(entry.lemma.form)-\(entry.segmentID)",
                    kind: .cloze,
                    prompt: stem,
                    choices: shuffled,
                    answerIndex: answerIndex,
                    rationale: sentence,
                    segmentID: entry.segmentID
                )
            )
        }
        return questions
    }

    static func sequencingQuestions(
        segments: [TranscriptSegment],
        limit: Int
    ) -> [ChapterQuizQuestion] {
        let texts = segments.map { ($0.id, StudyTokenIndex.sentenceText(in: $0)) }
            .filter { !$0.1.isEmpty }
        guard texts.count >= 5 else { return [] }
        var questions: [ChapterQuizQuestion] = []
        let starts = spreadIndices(count: max(texts.count - 1, 1), take: limit)
        for (rotation, index) in starts.enumerated() {
            guard index < texts.count - 1 else { continue }
            let current = texts[index]
            let correct = texts[index + 1]
            let pool = texts.indices
                .filter { $0 != index && $0 != index + 1 }
                .map { texts[$0].1 }
            let distractors = pickDistractors(
                answer: correct.1,
                pool: pool,
                count: 3,
                rotation: rotation * 2 + index
            )
            guard distractors.count == 3 else { continue }
            let choices = (distractors + [correct.1]).shuffled()
            guard let answerIndex = choices.firstIndex(of: correct.1) else { continue }
            questions.append(
                ChapterQuizQuestion(
                    id: "next-\(current.0)",
                    kind: .sequencing,
                    prompt: "Which sentence comes next after:\n“\(current.1)”",
                    choices: choices,
                    answerIndex: answerIndex,
                    rationale: correct.1,
                    segmentID: current.0
                )
            )
        }
        return questions
    }

    private struct CatalogEntry {
        var lemma: StudyLemma
        var surface: String
        var sentence: String
        var segmentID: String
    }

    private static func contentCatalog(
        segments: [TranscriptSegment],
        language: String
    ) -> [CatalogEntry] {
        var seen = Set<StudyLemma>()
        var entries: [CatalogEntry] = []
        for segment in segments {
            let sentence = StudyTokenIndex.sentenceText(in: segment)
            for word in StudyTokenIndex.tokens(in: segment) {
                guard let lemma = StudyLemma.make(language: language, surface: word.text),
                      StudyTokenIndex.isContentWord(lemma),
                      seen.insert(lemma).inserted
                else { continue }
                entries.append(
                    CatalogEntry(
                        lemma: lemma,
                        surface: DictionaryLookup.headword(word.text),
                        sentence: sentence,
                        segmentID: segment.id
                    )
                )
            }
        }
        return entries
    }
}

struct StudyActivityLog: Codable, Equatable, Sendable {
    var days: [String]

    static let empty = StudyActivityLog(days: [])

    func recording(on date: Date, calendar: Calendar = .current) -> StudyActivityLog {
        let key = Self.dayKey(date, calendar: calendar)
        var next = days
        if !next.contains(key) {
            next.append(key)
            next.sort()
        }
        return StudyActivityLog(days: next)
    }

    func consecutiveDays(on date: Date, calendar: Calendar = .current) -> Int {
        let present = Set(days)
        var count = 0
        var cursor = calendar.startOfDay(for: date)
        while present.contains(Self.dayKey(cursor, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    var caption: String {
        let streak = consecutiveDays(on: Date())
        switch streak {
        case 0: return "No study day yet"
        case 1: return "Study days · 1 in a row"
        default: return "Study days · \(streak) in a row"
        }
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
