import Foundation
import SwiftUI
import AppKit

@MainActor
@Observable
final class AppState {
    var settings: AppSettings
    var books: [Book] = []
    var selectedBookID: String?
    var selectedChapterID: String?
    var transcript: Transcript?
    var vocab: [VocabEntry] = []
    var tab: AppTab = .library
    var textSource: TextSource = .spoken
    var player = PlayerEngine()

    var isScanning = false
    var isTranscribing = false
    var transcriptionProgress: TranscriptionProgress?
    var errorMessage: String?
    var selectedWord: TranscriptWord?
    var definition: String?
    var dictionaryHits: [DictionaryHit] = []
    var selectedDictionaryName: String = ""
    var loopSentence = false
    var glosses: [GlossEntry] = []
    var isTranslating = false
    var translationError: String?
    var showSettings = false
    var apiKeyDraft = ""
    var focusedSegmentID: String?
    var focusedWordID: String?
    var scrollSegmentID: String?
    var revealToken: Int = 0

    private var transcriber = Transcriber()
    private var transcriptionTask: Task<Void, Never>?
    private var lastSentenceID: String?
    private var pendingReveal: PendingReveal?

    var selectedBook: Book? {
        books.first { $0.id == selectedBookID }
    }

    var selectedChapter: Chapter? {
        selectedBook?.chapters.first { $0.id == selectedChapterID }
    }

    var currentSegment: TranscriptSegment? {
        guard let transcript else { return nil }
        let t = player.currentTime
        return transcript.segments.last { t >= $0.start - 0.05 && t < $0.end + 0.12 }
            ?? transcript.segments.last { t >= $0.start }
    }

    var currentWord: TranscriptWord? {
        guard let segment = currentSegment else { return nil }
        let t = player.currentTime
        return segment.words.last { t >= $0.start && t < $0.end + 0.02 }
            ?? segment.words.last { t >= $0.start }
    }

    var studyLanguage: StudyLanguage {
        StudyLanguage(rawValue: settings.targetLanguage) ?? .zhHans
    }

    var currentSentenceGloss: GlossEntry? {
        guard let segment = currentSegment else { return nil }
        return lookupGloss(kind: .sentence, source: segment.displayText, context: nil)
    }

    var selectedWordGloss: GlossEntry? {
        guard let word = selectedWord else { return nil }
        return lookupGloss(
            kind: .word,
            source: DictionaryLookup.headword(word.text),
            context: currentSegment?.displayText
        )
    }

    var acceptedSentences: [GlossEntry] {
        glosses.filter { $0.kind == .sentence && $0.status == .accepted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    init() {
        settings = Persistence.loadSettings()
        vocab = Persistence.loadVocab().map { entry in
            var copy = entry
            copy.sanitizeDictionaryFields()
            return copy
        }
        glosses = Persistence.loadGlosses()
        apiKeyDraft = APIKeyStore.savedFileKey() ?? ""
        selectedDictionaryName = settings.preferredDictionary
        if let raw = TextSource(rawValue: settings.textSource) {
            textSource = raw
        }
        player.rate = Float(settings.playbackRate)
        importGlossesIntoVocab()
        if vocab.contains(where: { DictionaryLookup.looksLikeMarkup($0.definition ?? "") }) {
            Persistence.saveVocab(vocab)
        }
    }

    func boot() async {
        await rescan()
        if let first = books.first {
            selectedBookID = first.id
            selectedChapterID = first.chapters.first?.id
        }
    }

    func rescan() async {
        isScanning = true
        let root = URL(fileURLWithPath: settings.libraryPath)
        let scanned = LibraryScanner.scan(root: root)
        books = scanned
        isScanning = false
        for (index, book) in scanned.enumerated() {
            let updated = await LibraryScanner.loadDurations(for: book)
            if index < books.count, books[index].id == updated.id {
                books[index] = updated
            }
        }
    }

    func open(chapter: Chapter, in book: Book, autoplay: Bool) {
        selectedBookID = book.id
        selectedChapterID = chapter.id
        tab = .player
        player.load(path: chapter.audioPath)
        player.rate = Float(settings.playbackRate)
        transcript = Persistence.loadTranscript(chapterID: chapter.id, audioPath: chapter.audioPath)
        if pendingReveal == nil {
            selectedWord = nil
            definition = nil
            dictionaryHits = []
            focusedSegmentID = nil
            focusedWordID = nil
        }
        if autoplay { player.play() }
        if let pending = pendingReveal, transcript != nil {
            applyReveal(pending)
            pendingReveal = nil
        }
    }

    func transcribeSelected(force: Bool = false) {
        guard let book = selectedBook, let chapter = selectedChapter else { return }
        if !force, let existing = Persistence.loadTranscript(chapterID: chapter.id, audioPath: chapter.audioPath) {
            transcript = existing
            return
        }
        transcriptionTask?.cancel()
        isTranscribing = true
        transcriptionProgress = .init(fraction: 0, message: "Starting…")
        errorMessage = nil
        let transcriber = self.transcriber
        transcriptionTask = Task {
            do {
                let result = try await transcriber.transcribe(
                    chapter: chapter,
                    ebookPath: book.ebookPath,
                    progress: { [weak self] p in
                        Task { @MainActor in
                            self?.transcriptionProgress = p
                        }
                    },
                    checkpoint: { [weak self] locale, segments in
                        Task { @MainActor in
                            self?.commitTranscript(
                                chapter: chapter,
                                locale: locale,
                                segments: segments,
                                aligned: false
                            )
                        }
                    }
                )
                self.commitTranscript(
                    chapter: chapter,
                    locale: result.locale,
                    segments: result.segments,
                    aligned: result.ebookAligned
                )
            } catch is CancellationError {
                // ignore
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isTranscribing = false
            self.transcriptionProgress = nil
        }
    }

    @discardableResult
    private func commitTranscript(
        chapter: Chapter,
        locale: String,
        segments: [TranscriptSegment],
        aligned: Bool
    ) -> Bool {
        let transcript = Transcript(
            chapterID: chapter.id,
            audioPath: chapter.audioPath,
            createdAt: Date(),
            locale: locale,
            segments: segments,
            source: "SpeechAnalyzer",
            ebookAligned: aligned
        )
        do {
            try Persistence.saveTranscript(transcript)
            self.transcript = transcript
            if let pending = pendingReveal {
                applyReveal(pending)
                pendingReveal = nil
            }
            return true
        } catch {
            errorMessage = "Could not save transcript: \(error.localizedDescription)"
            self.transcript = transcript
            return false
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        Task { await transcriber.cancel() }
        isTranscribing = false
        transcriptionProgress = nil
    }

    func togglePlay() {
        guard selectedChapter != nil else { return }
        if transcript == nil, !isTranscribing {
            transcribeSelected()
        }
        player.toggle()
    }

    func skipSentence(direction: Int) {
        guard let transcript, let current = currentSegment else {
            player.skip(seconds: Double(direction) * settings.skipSeconds)
            return
        }
        guard let idx = transcript.segments.firstIndex(of: current) else { return }
        if direction < 0 {
            if player.currentTime - current.start > 1.0 {
                player.seek(current.start)
            } else if idx > 0 {
                player.seek(transcript.segments[idx - 1].start)
            } else {
                player.seek(0)
            }
        } else {
            if idx + 1 < transcript.segments.count {
                player.seek(transcript.segments[idx + 1].start)
            }
        }
    }

    func replaySentence() {
        if let current = currentSegment {
            player.seek(current.start)
            player.play()
        }
    }

    func tickLoop() {
        guard loopSentence, let current = currentSegment else { return }
        if player.currentTime >= current.end - 0.04 {
            player.seek(current.start)
            player.play()
        }
    }

    func addVocab(word: TranscriptWord, segment: TranscriptSegment) {
        guard let book = selectedBook, let chapter = selectedChapter else { return }
        let head = DictionaryLookup.headword(word.text)
        guard !head.isEmpty else { return }
        if vocab.contains(where: { $0.word.caseInsensitiveCompare(head) == .orderedSame && $0.chapterID == chapter.id && $0.category == .word && abs($0.timestamp - word.start) < 0.4 }) {
            return
        }
        let gloss = lookupGloss(kind: .word, source: head, context: segment.displayText)
        let accepted = gloss?.status == .accepted ? gloss : lookupGloss(kind: .word, source: head, context: nil)
        let dict = selectedDictionaryHit ?? dictionaryHits.first
        let entry = VocabEntry(
            id: UUID().uuidString,
            word: head,
            category: .word,
            definition: DictionaryLookup.plainPreview(from: dict?.preview ?? definition ?? dict?.html ?? ""),
            dictionaryName: dict?.name,
            dictionaryHTML: DictionaryLookup.optionalDisplayHTML(dict?.html),
            translation: (accepted?.status == .accepted ? accepted?.text : nil) ?? (gloss?.status == .accepted ? gloss?.text : nil),
            translationLanguage: accepted?.language ?? gloss?.language,
            context: segment.displayText,
            spokenText: segment.spokenText,
            ebookText: segment.ebookText,
            bookID: book.id,
            bookTitle: book.title,
            chapterID: chapter.id,
            chapterTitle: chapter.title,
            segmentID: segment.id,
            wordID: word.id,
            timestamp: word.start,
            addedAt: Date()
        )
        vocab.insert(entry, at: 0)
        Persistence.saveVocab(vocab)
    }

    func removeVocab(_ entry: VocabEntry) {
        vocab.removeAll { $0.id == entry.id }
        Persistence.saveVocab(vocab)
    }

    func jumpToVocab(_ entry: VocabEntry) {
        pendingReveal = PendingReveal(
            kind: entry.category == .sentence ? .sentence : .word,
            timestamp: entry.timestamp,
            segmentID: entry.segmentID,
            wordID: entry.wordID,
            wordText: entry.category == .sentence ? nil : entry.word,
            sentenceText: entry.context
        )
        guard let located = locate(bookID: entry.bookID, bookTitle: entry.bookTitle, chapterID: entry.chapterID, chapterTitle: entry.chapterTitle) else {
            errorMessage = "Could not find “\(entry.bookTitle)” in the library."
            pendingReveal = nil
            return
        }
        tab = .player
        open(chapter: located.chapter, in: located.book, autoplay: false)
    }

    func jumpToGloss(_ entry: GlossEntry) {
        pendingReveal = PendingReveal(
            kind: entry.kind == .sentence ? .sentence : .word,
            timestamp: entry.timestamp ?? 0,
            segmentID: nil,
            wordID: nil,
            wordText: entry.kind == .word ? entry.source : nil,
            sentenceText: entry.kind == .sentence ? entry.source : entry.context
        )
        guard let located = locate(bookID: entry.bookID, bookTitle: entry.bookTitle, chapterID: entry.chapterID, chapterTitle: entry.chapterTitle) else {
            errorMessage = "Could not find that passage in the library."
            pendingReveal = nil
            return
        }
        tab = .player
        open(chapter: located.chapter, in: located.book, autoplay: false)
    }

    func inspect(word: TranscriptWord) {
        selectedWord = word
        translationError = nil
        dictionaryHits = []
        definition = nil
        let preferred = settings.preferredDictionary
        let text = word.text
        let wordID = word.id
        Task.detached(priority: .userInitiated) {
            let hits = DictionaryLookup.lookup(text, preferredName: preferred)
            await MainActor.run {
                guard self.selectedWord?.id == wordID else { return }
                self.dictionaryHits = hits
                if hits.contains(where: { $0.name == preferred }) {
                    self.selectedDictionaryName = preferred
                } else {
                    self.selectedDictionaryName = hits.first?.name ?? preferred
                }
                let hit = hits.first(where: { $0.name == self.selectedDictionaryName }) ?? hits.first
                self.definition = hit.map { DictionaryLookup.plainPreview(from: $0.preview.isEmpty ? $0.html : $0.preview) }
            }
        }
    }

    var selectedDictionaryHit: DictionaryHit? {
        dictionaryHits.first { $0.name == selectedDictionaryName } ?? dictionaryHits.first
    }

    func persistSettings() {
        settings.playbackRate = Double(player.rate)
        settings.textSource = textSource.rawValue
        Persistence.saveSettings(settings)
    }

    func lookupGloss(kind: GlossKind, source: String, context: String?) -> GlossEntry? {
        let id = GlossEntry.makeID(kind: kind, language: settings.targetLanguage, source: source, context: context)
        if let hit = glosses.first(where: { $0.id == id }), hit.status != .rejected {
            return hit
        }
        return glosses.first {
            $0.kind == kind
            && $0.language == settings.targetLanguage
            && $0.status != .rejected
            && GlossEntry.normalize($0.source) == GlossEntry.normalize(source)
        }
    }

    func translateCurrentSentence() {
        guard let segment = currentSegment else { return }
        translate(kind: .sentence, source: segment.displayText, context: nil, timestamp: segment.start)
    }

    func translateSelectedWord() {
        guard let word = selectedWord else { return }
        let head = DictionaryLookup.headword(word.text)
        translate(
            kind: .word,
            source: head,
            context: currentSegment?.displayText,
            timestamp: word.start
        )
    }

    func ensureAutoTranslation() {
        guard settings.autoTranslate else { return }
        guard currentSentenceGloss == nil, currentSegment != nil, !isTranslating else { return }
        translateCurrentSentence()
    }

    func acceptGloss(_ entry: GlossEntry) {
        var copy = entry
        copy.status = .accepted
        copy.decidedAt = Date()
        saveGloss(copy)
    }

    func rejectGloss(_ entry: GlossEntry) {
        var copy = entry
        copy.status = .rejected
        copy.decidedAt = Date()
        saveGloss(copy)
        let source = GlossEntry.normalize(entry.source)
        vocab.removeAll {
            GlossEntry.normalize($0.context) == source
            || (entry.kind == .word && $0.category == .word && $0.word.caseInsensitiveCompare(entry.source) == .orderedSame && $0.translation == entry.text)
        }
        Persistence.saveVocab(vocab)
    }

    func retryGloss(_ entry: GlossEntry) {
        glosses.removeAll { $0.id == entry.id }
        Persistence.saveGlosses(glosses)
        if entry.kind == .sentence {
            translateCurrentSentence()
        } else {
            translateSelectedWord()
        }
    }

    private func translate(kind: GlossKind, source: String, context: String?, timestamp: TimeInterval) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = lookupGloss(kind: kind, source: trimmed, context: context),
           existing.status == .accepted || existing.status == .pending {
            return
        }
        guard APIKeyStore.isConfigured else {
            translationError = GrokError.noAPIKey.localizedDescription
            showSettings = true
            return
        }

        isTranslating = true
        translationError = nil
        let language = studyLanguage
        let model = settings.grokModel
        let book = selectedBook
        let chapter = selectedChapter
        Task {
            do {
                let system: String
                let user: String
                if kind == .sentence {
                    system = """
                    You are a literary translator and English-learning tutor.
                    Work in \(language.promptName).

                    Output exactly this layout, nothing before or after it:

                    译文：
                    <natural translation of the whole sentence; keep names; audiobook register; 1–2 sentences>

                    短语：
                    • <English phrase or idiom from THIS sentence> — <how it is used here, in \(language.promptName)>
                    • <next phrase> — <meaning in this sentence>

                    Rules:
                    - Pull out collocations, phrasal verbs, idioms, and set phrases (e.g. "have trouble doing", "in trouble", "ask for trouble").
                    - Explain the sense in *this* sentence, not a generic dictionary dump.
                    - Skip ordinary single words unless they are part of a phrase.
                    - If there is nothing worth noting, write: 短语：无
                    - No quotes around the translation. No grammar lecture.
                    """
                    user = trimmed
                } else {
                    system = """
                    You are an English-learning tutor.
                    Apple Dictionary already lists every sense of the word. Do NOT repeat that list.
                    Your only job is the meaning of this word (or the phrase it sits in) as used in THIS sentence.

                    Work in \(language.promptName).

                    Output exactly this layout, nothing before or after it:

                    本句释义：
                    <part of speech in this sentence> — <short meaning here, in \(language.promptName)>
                    <if it is part of a phrase/idiom, name the phrase and what it means here>

                    例句：
                    • <new English sentence using THIS same sense, not some other meaning>
                      <translation of that example>
                    • <second new example, same sense>
                      <translation>

                    Rules:
                    - Pick the one sense that fits the given sentence. Ignore other dictionary senses.
                    - Examples must be substitutable for that sense (e.g. if the sentence uses "trouble" = difficulty/problem, do not give examples about "don't trouble yourself" or medical "heart trouble" unless that is the sentence sense).
                    - Keep examples short and natural.
                    - No extra commentary.
                    """
                    user = "Word: \(trimmed)\nSentence: \(context ?? trimmed)"
                }
                let text = try await GrokClient.shared.complete(
                    system: system,
                    user: user,
                    model: model,
                    effort: settings.grokEffort
                )
                let entry = GlossEntry(
                    id: GlossEntry.makeID(kind: kind, language: language.rawValue, source: trimmed, context: context),
                    kind: kind,
                    language: language.rawValue,
                    source: trimmed,
                    context: context,
                    text: text,
                    status: .pending,
                    model: model,
                    bookID: book?.id,
                    bookTitle: book?.title,
                    chapterID: chapter?.id,
                    chapterTitle: chapter?.title,
                    timestamp: timestamp,
                    createdAt: Date(),
                    decidedAt: nil
                )
                self.saveGloss(entry)
            } catch {
                self.translationError = error.localizedDescription
            }
            self.isTranslating = false
        }
    }

    private func saveGloss(_ entry: GlossEntry) {
        if let idx = glosses.firstIndex(where: { $0.id == entry.id }) {
            glosses[idx] = entry
        } else {
            glosses.insert(entry, at: 0)
        }
        Persistence.saveGlosses(glosses)
        if entry.status != .rejected {
            captureAccepted(entry)
        }
    }

    func importGlossesIntoVocab() {
        let keep = glosses.filter { $0.status != .rejected }
        guard !keep.isEmpty else { return }
        var changed = false
        for gloss in keep {
            if captureAccepted(gloss, persist: false) {
                changed = true
            }
        }
        if changed {
            Persistence.saveVocab(vocab)
        }
    }

    @discardableResult
    private func captureAccepted(_ gloss: GlossEntry, persist: Bool = true) -> Bool {
        let bookID = gloss.bookID ?? selectedBookID ?? ""
        let bookTitle = gloss.bookTitle ?? selectedBook?.title ?? ""
        let chapterID = gloss.chapterID ?? selectedChapterID ?? ""
        let chapterTitle = gloss.chapterTitle ?? selectedChapter?.title ?? ""
        let timestamp = gloss.timestamp ?? currentSegment?.start ?? 0
        let segment = currentSegment
        let original = gloss.context ?? gloss.source
        let dict = selectedDictionaryHit ?? dictionaryHits.first
        var changed = false

        if gloss.kind == .word {
            if let idx = vocab.firstIndex(where: {
                $0.category == .word
                && $0.word.caseInsensitiveCompare(gloss.source) == .orderedSame
                && (chapterID.isEmpty || $0.chapterID == chapterID)
            }) {
                if vocab[idx].translation != gloss.text {
                    vocab[idx].translation = gloss.text
                    vocab[idx].translationLanguage = gloss.language
                    changed = true
                }
                if vocab[idx].definition == nil || DictionaryLookup.looksLikeMarkup(vocab[idx].definition ?? "") {
                    vocab[idx].definition = dict.map { DictionaryLookup.plainPreview(from: $0.preview) }
                    vocab[idx].dictionaryName = dict?.name
                    vocab[idx].dictionaryHTML = DictionaryLookup.optionalDisplayHTML(dict?.html)
                    vocab[idx].sanitizeDictionaryFields()
                    changed = true
                }
            } else {
                vocab.insert(
                    VocabEntry(
                        id: UUID().uuidString,
                        word: gloss.source,
                        category: .word,
                        definition: dict.map { DictionaryLookup.plainPreview(from: $0.preview) },
                        dictionaryName: dict?.name,
                        dictionaryHTML: DictionaryLookup.optionalDisplayHTML(dict?.html),
                        translation: gloss.text,
                        translationLanguage: gloss.language,
                        context: original,
                        spokenText: segment?.spokenText,
                        ebookText: segment?.ebookText,
                        bookID: bookID,
                        bookTitle: bookTitle,
                        chapterID: chapterID,
                        chapterTitle: chapterTitle,
                        segmentID: segment?.id,
                        wordID: selectedWord?.id,
                        timestamp: timestamp,
                        addedAt: Date()
                    ),
                    at: 0
                )
                changed = true
            }
        } else {
            if !vocab.contains(where: {
                $0.category == .sentence
                && GlossEntry.normalize($0.context) == GlossEntry.normalize(gloss.source)
                && (chapterID.isEmpty || $0.chapterID == chapterID || $0.chapterID.isEmpty)
            }) {
                vocab.insert(
                    VocabEntry(
                        id: UUID().uuidString,
                        word: String(gloss.source.prefix(80)),
                        category: .sentence,
                        definition: nil,
                        translation: gloss.text,
                        translationLanguage: gloss.language,
                        context: gloss.source,
                        spokenText: segment?.spokenText,
                        ebookText: segment?.ebookText,
                        bookID: bookID,
                        bookTitle: bookTitle,
                        chapterID: chapterID,
                        chapterTitle: chapterTitle,
                        segmentID: segment?.id,
                        timestamp: timestamp,
                        addedAt: Date()
                    ),
                    at: 0
                )
                changed = true
            }
            for phrase in GlossPhrases.extract(from: gloss.text) {
                if vocab.contains(where: {
                    $0.category == .phrase
                    && $0.word.caseInsensitiveCompare(phrase.phrase) == .orderedSame
                    && GlossEntry.normalize($0.context) == GlossEntry.normalize(gloss.source)
                }) { continue }
                let hits = DictionaryLookup.lookup(phrase.phrase, preferredName: settings.preferredDictionary)
                let hit = hits.first
                vocab.insert(
                    VocabEntry(
                        id: UUID().uuidString,
                        word: phrase.phrase,
                        category: .phrase,
                        definition: hit.map { DictionaryLookup.plainPreview(from: $0.preview) },
                        dictionaryName: hit?.name,
                        dictionaryHTML: DictionaryLookup.optionalDisplayHTML(hit?.html),
                        translation: phrase.meaning,
                        translationLanguage: gloss.language,
                        context: gloss.source,
                        spokenText: segment?.spokenText,
                        ebookText: segment?.ebookText,
                        bookID: bookID,
                        bookTitle: bookTitle,
                        chapterID: chapterID,
                        chapterTitle: chapterTitle,
                        segmentID: segment?.id,
                        timestamp: timestamp,
                        addedAt: Date()
                    ),
                    at: 0
                )
                changed = true
            }
        }
        if persist, changed {
            Persistence.saveVocab(vocab)
        }
        return changed
    }

    private func locate(
        bookID: String?,
        bookTitle: String?,
        chapterID: String?,
        chapterTitle: String?
    ) -> (book: Book, chapter: Chapter)? {
        var book: Book?
        if let bookID {
            book = books.first { $0.id == bookID }
        }
        if book == nil, let bookTitle, !bookTitle.isEmpty {
            book = books.first { $0.title.caseInsensitiveCompare(bookTitle) == .orderedSame }
                ?? books.first {
                    $0.title.localizedCaseInsensitiveContains(bookTitle)
                    || bookTitle.localizedCaseInsensitiveContains($0.title)
                }
        }
        guard let book else { return nil }
        let chapter = book.chapters.first { $0.id == chapterID }
            ?? book.chapters.first { $0.title == chapterTitle }
            ?? book.chapters.first { ch in
                guard let chapterTitle else { return false }
                return ch.title.localizedCaseInsensitiveContains(chapterTitle)
            }
            ?? book.chapters.first
        guard let chapter else { return nil }
        return (book, chapter)
    }

    private func applyReveal(_ reveal: PendingReveal) {
        guard let transcript else { return }
        guard let segment = findSegment(in: transcript, reveal: reveal) else { return }
        let word = reveal.kind == .word ? findWord(in: segment, reveal: reveal) : nil
        let time = (word?.start ?? segment.start) + 0.02
        player.seek(time)
        focusedSegmentID = segment.id
        focusedWordID = word?.id
        scrollSegmentID = segment.id
        revealToken += 1
        if let word {
            if textSource == .original {
                textSource = .dual
                persistSettings()
            }
            inspect(word: word)
        } else {
            selectedWord = nil
            dictionaryHits = []
        }
    }

    private func findSegment(in transcript: Transcript, reveal: PendingReveal) -> TranscriptSegment? {
        if let id = reveal.segmentID {
            if let hit = transcript.segments.first(where: { $0.id == id }) { return hit }
        }
        let t = reveal.timestamp
        if t > 0 {
            if let hit = transcript.segments.first(where: { t >= $0.start - 0.02 && t < $0.end + 0.05 }) {
                return hit
            }
        }
        if let sentence = reveal.sentenceText, !sentence.isEmpty {
            let needle = GlossEntry.normalize(sentence)
            if let hit = transcript.segments.first(where: {
                GlossEntry.normalize($0.displayText) == needle
                || GlossEntry.normalize($0.spokenText) == needle
                || GlossEntry.normalize($0.ebookText ?? "").contains(needle)
                || needle.contains(GlossEntry.normalize($0.spokenText))
            }) {
                return hit
            }
        }
        if t > 0 {
            return transcript.segments.min(by: { abs($0.start - t) < abs($1.start - t) })
        }
        return nil
    }

    private func findWord(in segment: TranscriptSegment, reveal: PendingReveal) -> TranscriptWord? {
        if let id = reveal.wordID, let hit = segment.words.first(where: { $0.id == id }) {
            return hit
        }
        if let text = reveal.wordText {
            let head = DictionaryLookup.headword(text).lowercased()
            let matches = segment.words.filter {
                DictionaryLookup.headword($0.text).lowercased() == head
            }
            if matches.count == 1 { return matches[0] }
            if let closest = matches.min(by: { abs($0.start - reveal.timestamp) < abs($1.start - reveal.timestamp) }) {
                return closest
            }
        }
        if reveal.timestamp > 0 {
            return segment.words.min(by: { abs($0.start - reveal.timestamp) < abs($1.start - reveal.timestamp) })
        }
        return segment.words.first
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.libraryPath)
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder that contains your audiobook + ebook collections."
        if panel.runModal() == .OK, let url = panel.url {
            settings.libraryPath = url.path
            persistSettings()
            Task { await rescan() }
        }
    }
}

private struct PendingReveal {
    var kind: TextRevealKind
    var timestamp: TimeInterval
    var segmentID: String?
    var wordID: String?
    var wordText: String?
    var sentenceText: String?
}
