import Foundation

enum ChapterAcceptanceBatch {
    struct Defaults: Sendable {
        var bookID: String
        var bookTitle: String
        var chapterID: String
        var chapterTitle: String
        var timestamp: TimeInterval
        var segment: TranscriptSegment?
        var wordID: String?

        static let empty = Defaults(
            bookID: "",
            bookTitle: "",
            chapterID: "",
            chapterTitle: "",
            timestamp: 0,
            segment: nil,
            wordID: nil
        )
    }

    struct Result: Sendable {
        var vocab: [VocabEntry]
        var upserts: [VocabEntry]
    }

    typealias DefinitionResolver = @Sendable (String) -> DictionaryHit?
    typealias Progress = @Sendable (_ completed: Int, _ total: Int) -> Void

    static func prepare(
        glosses: [GlossEntry],
        vocab: [VocabEntry],
        segments: [TranscriptSegment],
        defaults: Defaults,
        definitionResolver: DefinitionResolver? = nil,
        progress: Progress? = nil
    ) -> Result {
        var working = vocab
        let originalCount = working.count
        var upsertOrder: [String] = []
        var upsertsByID: [String: VocabEntry] = [:]

        var segmentsBySource: [String: TranscriptSegment] = [:]
        segmentsBySource.reserveCapacity(segments.count)
        for segment in segments {
            let key = GlossEntry.normalize(segment.displayText)
            if segmentsBySource[key] == nil { segmentsBySource[key] = segment }
        }

        var wordIndices: [String: [Int]] = [:]
        var sentenceIndices: [String: [Int]] = [:]
        var phraseIndices: [PhraseKey: Int] = [:]
        wordIndices.reserveCapacity(working.count)
        sentenceIndices.reserveCapacity(working.count)
        phraseIndices.reserveCapacity(working.count)
        for (index, entry) in working.enumerated() {
            switch entry.category {
            case .word:
                wordIndices[entry.word.lowercased(), default: []].append(index)
            case .sentence:
                sentenceIndices[GlossEntry.normalize(entry.context), default: []].append(index)
            case .phrase:
                let key = PhraseKey(word: entry.word, context: entry.context)
                if phraseIndices[key] == nil { phraseIndices[key] = index }
            }
        }

        func recordUpsert(_ entry: VocabEntry) {
            if upsertsByID[entry.id] == nil { upsertOrder.append(entry.id) }
            upsertsByID[entry.id] = entry
        }

        func appendNew(_ entry: VocabEntry) -> Int {
            let index = working.count
            working.append(entry)
            recordUpsert(entry)
            return index
        }

        for (offset, gloss) in glosses.enumerated() where gloss.status == .accepted {
            let bookID = gloss.bookID ?? defaults.bookID
            let bookTitle = gloss.bookTitle ?? defaults.bookTitle
            let chapterID = gloss.chapterID ?? defaults.chapterID
            let chapterTitle = gloss.chapterTitle ?? defaults.chapterTitle
            let timestamp = gloss.timestamp ?? defaults.timestamp
            let segment = segmentsBySource[GlossEntry.normalize(gloss.source)] ?? defaults.segment
            let original = gloss.context ?? gloss.source

            if gloss.kind == .word {
                let key = gloss.source.lowercased()
                let match = wordIndices[key]?.first { index in
                    chapterID.isEmpty || working[index].chapterID == chapterID
                }
                if let match {
                    var entry = working[match]
                    if entry.translation != gloss.text
                        || entry.translationLanguage != gloss.language
                        || entry.translationModel != gloss.model {
                        entry.translation = gloss.text
                        entry.translationLanguage = gloss.language
                        entry.translationModel = gloss.model
                        working[match] = entry
                        recordUpsert(entry)
                    }
                } else {
                    let entry = VocabEntry(
                        id: UUID().uuidString,
                        word: gloss.source,
                        category: .word,
                        translation: gloss.text,
                        translationLanguage: gloss.language,
                        translationModel: gloss.model,
                        context: original,
                        spokenText: segment?.spokenText,
                        ebookText: segment?.trustedEbookText,
                        bookID: bookID,
                        bookTitle: bookTitle,
                        chapterID: chapterID,
                        chapterTitle: chapterTitle,
                        segmentID: segment?.id,
                        wordID: defaults.wordID,
                        timestamp: timestamp,
                        addedAt: Date()
                    )
                    let index = appendNew(entry)
                    wordIndices[key, default: []].append(index)
                }
            } else {
                let sentenceKey = GlossEntry.normalize(gloss.source)
                let match = sentenceIndices[sentenceKey]?.first { index in
                    chapterID.isEmpty || working[index].chapterID == chapterID || working[index].chapterID.isEmpty
                }
                if let match {
                    var entry = working[match]
                    if entry.translation != gloss.text
                        || entry.translationLanguage != gloss.language
                        || entry.translationModel != gloss.model {
                        entry.translation = gloss.text
                        entry.translationLanguage = gloss.language
                        entry.translationModel = gloss.model
                        working[match] = entry
                        recordUpsert(entry)
                    }
                } else {
                    let entry = VocabEntry(
                        id: UUID().uuidString,
                        word: String(gloss.source.prefix(80)),
                        category: .sentence,
                        translation: gloss.text,
                        translationLanguage: gloss.language,
                        translationModel: gloss.model,
                        context: gloss.source,
                        spokenText: segment?.spokenText,
                        ebookText: segment?.trustedEbookText,
                        bookID: bookID,
                        bookTitle: bookTitle,
                        chapterID: chapterID,
                        chapterTitle: chapterTitle,
                        segmentID: segment?.id,
                        timestamp: timestamp,
                        addedAt: Date()
                    )
                    let index = appendNew(entry)
                    sentenceIndices[sentenceKey, default: []].append(index)
                }

                for phrase in GlossPhrases.extract(from: gloss.text) {
                    let phraseKey = PhraseKey(word: phrase.phrase, context: gloss.source)
                    guard phraseIndices[phraseKey] == nil else { continue }
                    let hit = definitionResolver?(phrase.phrase)
                    let entry = VocabEntry(
                        id: UUID().uuidString,
                        word: phrase.phrase,
                        category: .phrase,
                        definition: hit.map { DictionaryLookup.plainPreview(from: $0.preview) },
                        dictionaryName: hit?.name,
                        dictionaryHTML: DictionaryLookup.optionalDisplayHTML(hit?.html),
                        translation: phrase.meaning,
                        translationLanguage: gloss.language,
                        translationModel: gloss.model,
                        context: gloss.source,
                        spokenText: segment?.spokenText,
                        ebookText: segment?.trustedEbookText,
                        bookID: bookID,
                        bookTitle: bookTitle,
                        chapterID: chapterID,
                        chapterTitle: chapterTitle,
                        segmentID: segment?.id,
                        timestamp: timestamp,
                        addedAt: Date()
                    )
                    phraseIndices[phraseKey] = appendNew(entry)
                }
            }
            progress?(offset + 1, glosses.count)
        }

        if working.count > originalCount {
            let newEntries = Array(working[originalCount...]).reversed()
            working = Array(newEntries) + Array(working[..<originalCount])
        }
        return Result(
            vocab: working,
            upserts: upsertOrder.compactMap { upsertsByID[$0] }
        )
    }

    private struct PhraseKey: Hashable {
        var word: String
        var context: String

        init(word: String, context: String) {
            self.word = word.lowercased()
            self.context = GlossEntry.normalize(context)
        }
    }
}
