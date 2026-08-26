import Foundation
import Testing
@testable import AudioReader

@Suite("Playback cursor follows spoken tokens")
struct PlaybackCursorTests {
    @Test("Cursor selects the word whose timestamp contains the playhead")
    func followsWordTimestamps() {
        let segments = timedSegments()
        let atForest = PlaybackCursor.resolve(segments: segments, time: 0.3)
        let atStream = PlaybackCursor.resolve(segments: segments, time: 2.4)

        #expect(atForest.segmentID == "first")
        #expect(atForest.wordID == "forest-1")
        #expect(atForest.word?.text == "forest")
        #expect(atStream.segmentID == "second")
        #expect(atStream.wordID == "stream-1")
    }

    @Test("Cursor uses synthetic tokens when a sentence has spoken text but no word array")
    func usesSyntheticTokensWhenWordsAreMissing() {
        let segment = TranscriptSegment(
            id: "spoken-only",
            start: 0,
            end: 2,
            words: [],
            ebookText: "ignored because it is not trusted",
            alignmentScore: nil
        )
        // spokenText is derived from words, so seed via a word-less spoken fallback:
        // StudyTokenIndex reads trustedEbookText ?? spokenText. Mark ebook trusted.
        var trusted = segment
        trusted.ebookText = "The forest canopy"
        trusted.individualEbookMatchTrusted = true
        trusted.documentEbookUseAllowed = true

        let cursor = PlaybackCursor.resolve(segments: [trusted], time: 0.8)
        #expect(cursor.segmentID == "spoken-only")
        #expect(cursor.word?.text == "forest")
    }

    @Test("A later sentence does not keep the previous sentence's word")
    func leavesPreviousSentence() {
        let cursor = PlaybackCursor.resolve(segments: timedSegments(), time: 2.05)
        #expect(cursor.segmentID == "second")
        #expect(cursor.wordID != "canopy-1")
    }
}

@Suite("Chapter words presentation snapshot")
struct ChapterStudyPresentationTests {
    @MainActor
    @Test("Presenting chapter words snapshots coverage and priming independently of later index clears")
    func snapshotSurvivesEmptyIndex() {
        let state = AppState()
        state.settings.transcriptionLanguage = TranscriptionLanguage.englishUS.rawValue
        state.vocab = []
        state.knownLemmas = []
        state.selectedChapterID = "chapter"
        state.transcript = Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/chapter-words.m4b",
            createdAt: Date(),
            locale: "en-US",
            segments: timedSegments(),
            source: "test",
            ebookAligned: false
        )

        state.presentChapterStudyList()
        #expect(state.chapterStudyPresentation?.hasTranscript == true)
        #expect(state.chapterStudyPresentation?.items.map(\.lemma.form) == ["forest", "canopy", "stream"])
        #expect(state.chapterStudyPresentation?.coverage.contentCount == 3)

        state.transcript = nil
        #expect(state.chapterStudyItems.isEmpty)
        #expect(state.chapterStudyPresentation?.items.map(\.lemma.form) == ["forest", "canopy", "stream"])
    }

    @MainActor
    @Test("Marking known refreshes the open snapshot instead of leaving a stale empty sheet")
    func markKnownUpdatesOpenSnapshot() {
        let state = AppState()
        state.settings.transcriptionLanguage = TranscriptionLanguage.englishUS.rawValue
        state.vocab = []
        state.knownLemmas = []
        state.transcript = Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/chapter-words-mark.m4b",
            createdAt: Date(),
            locale: "en-US",
            segments: timedSegments(),
            source: "test",
            ebookAligned: false
        )
        state.presentChapterStudyList()
        let canopy = TranscriptWord(id: "canopy-1", text: "canopy", start: 0.6, end: 1.1, confidence: nil)
        state.markKnown(canopy, known: true)

        #expect(state.chapterStudyPresentation?.items.map(\.lemma.form) == ["forest", "stream"])
        #expect(state.chapterStudyPresentation?.coverage.knownCount == 1)
    }
}

@Suite("Shadowing score")
struct ShadowingScoreTests {
    @Test("Identical sentences score 100 and miss nothing")
    func exactMatchIsPerfect() {
        let result = ShadowingScorer.score(
            expected: "The forest canopy hides a stream.",
            spoken: "The forest canopy hides a stream."
        )
        #expect(result.percent == 100)
        #expect(result.missed.isEmpty)
        #expect(result.extra.isEmpty)
        #expect(result.matchedCount == result.expectedTokens.count)
    }

    @Test("Missing content words lower the score and are listed")
    func listsMissedWords() {
        let result = ShadowingScorer.score(
            expected: "The forest canopy hides a stream",
            spoken: "The forest hides a stream"
        )
        #expect(result.percent == 83 || result.percent == 80)
        #expect(result.missed == ["canopy"])
        #expect(result.extra.isEmpty)
    }

    @Test("Extra spoken words do not count as matches")
    func extraWordsAreReported() {
        let result = ShadowingScorer.score(
            expected: "forest canopy",
            spoken: "the dark forest canopy tonight"
        )
        #expect(result.percent == 100)
        #expect(result.extra.contains("dark") || result.extra.contains("tonight"))
    }

    @Test("Empty speech is zero")
    func emptySpeechIsZero() {
        let result = ShadowingScorer.score(expected: "forest canopy", spoken: "")
        #expect(result.percent == 0)
        #expect(result.matchedCount == 0)
        #expect(result.missed == ["forest", "canopy"])
    }

    @Test("CJK shadowing compares characters when there are no spaces")
    func scoresCJKCharacters() {
        let result = ShadowingScorer.score(expected: "森林树冠", spoken: "森林")
        #expect(result.percent == 50)
        #expect(result.missed == ["树", "冠"])
    }
}

@Suite("Chapter comprehension quiz")
struct ChapterQuizTests {
    @Test("Local quiz includes a cloze from a content word and a what-comes-next item")
    func buildsClozeAndSequencing() {
        let quiz = ChapterQuizBuilder.build(
            segments: quizSegments(),
            language: "en",
            limit: 6
        )
        #expect(quiz.questions.count >= 2)
        #expect(quiz.questions.contains { $0.kind == .cloze })
        #expect(quiz.questions.contains { $0.kind == .sequencing })
        #expect(quiz.questions.allSatisfy { $0.choices.count == 4 })
        #expect(quiz.questions.allSatisfy { $0.choices.indices.contains($0.answerIndex) })
        #expect(quiz.questions.allSatisfy { Set($0.choices).count == 4 })
    }

    @Test("Cloze blanks a content word and keeps function words in the stem")
    func clozeKeepsFunctionWords() {
        let quiz = ChapterQuizBuilder.build(segments: quizSegments(), language: "en", limit: 6)
        let cloze = quiz.questions.first { $0.kind == .cloze }
        #expect(cloze != nil)
        #expect(cloze?.prompt.contains("____") == true)
        #expect(cloze?.prompt.lowercased().contains("the") == true)
        #expect(!(cloze?.choices.contains { $0.lowercased() == "the" } ?? true))
    }

    @Test("Scoring a quiz counts correct answers without mutating the transcript")
    func scoresAnswers() {
        let quiz = ChapterQuizBuilder.build(segments: quizSegments(), language: "en", limit: 4)
        var picks = Array(repeating: 0, count: quiz.questions.count)
        picks[0] = quiz.questions[0].answerIndex
        let result = quiz.scored(selections: picks)
        #expect(result.correctCount >= 1)
        #expect(result.total == quiz.questions.count)
        #expect(result.percent >= 0 && result.percent <= 100)
    }

    @Test("Cloze questions do not all share the same four options")
    func clozeChoicesAreNotIdenticalAcrossQuestions() {
        let quiz = ChapterQuizBuilder.build(segments: quizSegments(), language: "en", limit: 6)
        let cloze = quiz.questions.filter { $0.kind == .cloze }
        #expect(cloze.count >= 2)
        let signatures = Set(cloze.map { $0.choices.map { $0.lowercased() }.sorted().joined(separator: ",") })
        #expect(signatures.count > 1)
    }

    @Test("Selecting one quiz answer leaves other questions untouched")
    func selectionIsPerQuestion() {
        let quiz = ChapterQuizBuilder.build(segments: quizSegments(), language: "en", limit: 4)
        var session = ChapterQuizSession(quiz: quiz)
        session.select(1, at: 0)
        #expect(session.selections[0] == 1)
        #expect(session.selections.dropFirst().allSatisfy { $0 == nil })
    }

    @Test("Quiz choice identities are unique across every question")
    func choiceIdentitiesAreUnique() {
        let quiz = ChapterQuizBuilder.build(segments: quizSegments(), language: "en", limit: 6)
        let ids = quiz.questions.flatMap(\.labeledChoices).map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Distractors rotate through the chapter instead of always taking the first three words")
    func distractorsRotateThroughThePool() {
        let pool = ["forest", "canopy", "stream", "sunlight", "travelers", "valley"]
        let first = ChapterQuizBuilder.pickDistractors(answer: "forest", pool: pool, count: 3, rotation: 0)
        let later = ChapterQuizBuilder.pickDistractors(answer: "forest", pool: pool, count: 3, rotation: 3)
        #expect(Set(first).count == 3)
        #expect(!first.contains("forest"))
        #expect(Set(first) != Set(later))
    }

    @Test("LLM quiz JSON is parsed without markdown fences")
    func parsesModelJSON() throws {
        let raw = """
        ```json
        {"questions":[{"id":"q1","prompt":"Why does the canopy matter?","choices":["Shade","Noise","Dust","Salt"],"answerIndex":0,"rationale":"It hides the stream."}]}
        ```
        """
        let parsed = try ChapterQuizParser.parse(raw)
        #expect(parsed.questions.count == 1)
        #expect(parsed.questions[0].prompt.contains("canopy"))
        #expect(parsed.questions[0].answerIndex == 0)
        #expect(parsed.questions[0].kind == .comprehension)
    }
}

@Suite("Local study days")
struct StudyStreakTests {
    @Test("Recording today starts a one-day streak")
    func recordsToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let log = StudyActivityLog.empty.recording(on: day, calendar: calendar)
        #expect(log.consecutiveDays(on: day, calendar: calendar) == 1)
        #expect(log.days.count == 1)
    }

    @Test("Consecutive calendar days lengthen the streak")
    func consecutiveDaysLengthen() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = calendar.date(byAdding: .day, value: -1, to: day)!
        let log = StudyActivityLog.empty
            .recording(on: previous, calendar: calendar)
            .recording(on: day, calendar: calendar)
        #expect(log.consecutiveDays(on: day, calendar: calendar) == 2)
    }

    @Test("A skipped day resets the streak without deleting history")
    func skippedDayResetsCurrentStreak() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: day)!
        let log = StudyActivityLog.empty.recording(on: twoDaysAgo, calendar: calendar)
        #expect(log.consecutiveDays(on: day, calendar: calendar) == 0)
        #expect(log.days.count == 1)
    }

    @Test("Study activity round-trips without XP or remote library fields")
    func roundTripsWithoutXP() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-streak-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fixture) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let log = StudyActivityLog.empty.recording(on: day, calendar: calendar)
        Persistence.saveStudyActivityLog(log, to: fixture)
        let loaded = Persistence.loadStudyActivityLog(from: fixture)
        #expect(loaded.days == log.days)
        let encoded = try String(contentsOf: fixture, encoding: .utf8)
        #expect(!encoded.contains("xp"))
        #expect(!encoded.contains("leaderboard"))
        #expect(!encoded.contains("libraryURL"))
    }
}

@Suite("Full-chapter overlay and isolated playback chrome")
struct StudyOverlayChromeContractTests {
    @Test("Overlay tokenizes every visible sentence, not only the selected one")
    func overlayTokenizesWholeChapter() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let sentenceRow = try section(
            in: playerView,
            from: "private struct SentenceRow: View",
            to: "private struct WordToken: View"
        )
        #expect(sentenceRow.contains("isSelected || studyOverlayEnabled"))
        #expect(sentenceRow.contains("StudyTokenIndex.tokens"))
        #expect(!sentenceRow.contains("if isSelected {\n                    FlowLayout"))
        let wordToken = try section(
            in: playerView,
            from: "private struct WordToken: View",
            to: "private struct WordInspector: View"
        )
        #expect(wordToken.contains("if studyOverlayEnabled, familiarity != .known"))
        #expect(!wordToken.contains("if studyOverlayEnabled, !dimmed, familiarity != .known"))
    }

    @Test("Chapter words uses a snapshot sheet and a real Mac button outside the Reading menu")
    func chapterWordsUsesSnapshotSheet() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let listView = try source("Sources/AudioReader/ChapterStudyListView.swift")
        let macRoot = try source("Sources/AudioReader/RootView.swift")
        let iPadRoot = try source("Sources/AudioReader/IPadRootView.swift")
        let app = try source("Sources/AudioReader/AudioReaderApp.swift")
        let expandedHeader = try section(
            in: playerView,
            from: "    private var desktopExpandedHeaderControls",
            to: "    private var desktopCompactHeaderControls"
        )
        let expandedMenu = try section(
            in: expandedHeader,
            from: "            Menu {",
            to: "            } label: {"
        )

        #expect(expandedHeader.contains("Button(\"Chapter words\")"))
        #expect(!expandedMenu.contains("Button(\"Chapter words\")"))
        #expect(playerView.contains("presentChapterStudyList()"))
        #expect(app.contains("presentChapterStudyList()"))
        #expect(macRoot.contains(".sheet(item: $state.chapterStudyPresentation)"))
        #expect(iPadRoot.contains(".sheet(item: $state.chapterStudyPresentation)"))
        #expect(!macRoot.contains("$state.showChapterStudyList"))
        #expect(!iPadRoot.contains("$state.showChapterStudyList"))
        #expect(listView.contains("presentation.items"))
        #expect(listView.contains("minWidth: 420"))
        let listBlock = try section(
            in: listView,
            from: "            List {",
            to: "            .navigationTitle(\"Chapter words\")"
        )
        #expect(!listBlock.contains("ContentUnavailableView"))
    }

    @Test("Playback ticks do not rebuild the whole player through PlayerView.body")
    func playbackTimeIsIsolatedFromPlayerBody() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let body = try section(
            in: playerView,
            from: "    var body: some View {",
            to: "    private var ebookMissingNotice"
        )
        #expect(!body.contains("player.currentTime"))
        #expect(!body.contains("currentReaderPosition"))
        #expect(playerView.contains("struct TranscriptTextColumn"))
        #expect(playerView.contains("struct PlaybackChrome"))
        #expect(playerView.contains(".equatable()"))
    }

    @Test("Shadowing and chapter quiz are reachable from the shared Reading menu")
    func studyPracticeIsInReadingMenu() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let sharedMenu = try section(
            in: playerView,
            from: "    private var sharedReadingMenu: some View {",
            to: "        } label: {"
        )
        #expect(sharedMenu.contains("Shadow this sentence"))
        #expect(sharedMenu.contains("Chapter quiz"))
        #expect(playerView.contains("ShadowingPracticeView"))
        #expect(playerView.contains("ChapterQuizView"))
        #expect(!sharedMenu.contains("#if os("))
        #expect(playerView.contains("VoiceCaptureLocale.speechLocale(\n                for: .chapterQuestion"))
        #expect(!playerView.contains("locale: state.currentAudiobookLanguage.locale"))
        #expect(playerView.contains("player.pause()"))
        #expect(playerView.contains("voice.isListening"))
        #expect(playerView.contains("UncheckedAction { onSeek(word.start) }"))
        #expect(!playerView.contains("dictation.isListening"))
        #expect(!playerView.contains("ForEach(TextSource.allCases)"))
        #expect(playerView.contains("Text(TextSource.spoken.rawValue).tag(TextSource.spoken)"))
        let shadowing = try source("Sources/AudioReader/ShadowingPracticeView.swift")
        #expect(shadowing.contains("for: .sentenceShadowing"))
        #expect(shadowing.contains("voice.isListening"))
        #expect(shadowing.contains("PlatformTap("))
        #expect(!shadowing.contains("dictation.isListening"))
        #expect(!shadowing.contains("NavigationStack"))
        let quizView = try source("Sources/AudioReader/ChapterQuizView.swift")
        #expect(quizView.contains("labeledChoices"))
        #expect(!quizView.contains("id: \\.offset"))
        let dictation = try source("Sources/AudioReader/ChapterChatDictation.swift")
        #expect(dictation.contains("audioEngine.reset()"))
        #expect(dictation.contains("VoiceCaptureLocale.isUsable"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func section(in source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func timedSegments() -> [TranscriptSegment] {
    [
        TranscriptSegment(
            id: "first",
            start: 0,
            end: 2,
            words: [
                TranscriptWord(id: "the-1", text: "The", start: 0, end: 0.2, confidence: nil),
                TranscriptWord(id: "forest-1", text: "forest", start: 0.2, end: 0.6, confidence: nil),
                TranscriptWord(id: "canopy-1", text: "canopy", start: 0.6, end: 1.1, confidence: nil)
            ],
            ebookText: nil,
            alignmentScore: nil
        ),
        TranscriptSegment(
            id: "second",
            start: 2,
            end: 4,
            words: [
                TranscriptWord(id: "the-2", text: "The", start: 2.0, end: 2.2, confidence: nil),
                TranscriptWord(id: "stream-1", text: "stream", start: 2.2, end: 2.8, confidence: nil)
            ],
            ebookText: nil,
            alignmentScore: nil
        )
    ]
}

private func quizSegments() -> [TranscriptSegment] {
    [
        TranscriptSegment(
            id: "s1",
            start: 0,
            end: 2,
            words: words("s1", "The forest hides a stream", from: 0),
            ebookText: nil,
            alignmentScore: nil
        ),
        TranscriptSegment(
            id: "s2",
            start: 2,
            end: 4,
            words: words("s2", "A canopy filters the sunlight", from: 2),
            ebookText: nil,
            alignmentScore: nil
        ),
        TranscriptSegment(
            id: "s3",
            start: 4,
            end: 6,
            words: words("s3", "Birds gather above the moss", from: 4),
            ebookText: nil,
            alignmentScore: nil
        ),
        TranscriptSegment(
            id: "s4",
            start: 6,
            end: 8,
            words: words("s4", "Travelers follow the quiet path", from: 6),
            ebookText: nil,
            alignmentScore: nil
        ),
        TranscriptSegment(
            id: "s5",
            start: 8,
            end: 10,
            words: words("s5", "Night settles over the valley", from: 8),
            ebookText: nil,
            alignmentScore: nil
        )
    ]
}

private func words(_ segmentID: String, _ sentence: String, from start: TimeInterval) -> [TranscriptWord] {
    let parts = sentence.split(separator: " ")
    return parts.enumerated().map { index, part in
        let t = start + Double(index) * 0.2
        return TranscriptWord(
            id: "\(segmentID)-\(index)",
            text: String(part),
            start: t,
            end: t + 0.2,
            confidence: nil
        )
    }
}
