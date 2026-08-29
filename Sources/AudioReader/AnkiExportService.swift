import AVFoundation
import CryptoKit
import Foundation
import OSLog
import ZIPFoundation

struct AnkiAudioSource: Equatable, Sendable {
    var mediaURL: URL
    var sentenceStart: TimeInterval
    var sentenceEnd: TimeInterval
    var chapterOffset: TimeInterval
    var mediaDuration: TimeInterval?
    var isProtected: Bool

    init(
        mediaURL: URL,
        sentenceStart: TimeInterval,
        sentenceEnd: TimeInterval,
        chapterOffset: TimeInterval = 0,
        mediaDuration: TimeInterval? = nil,
        isProtected: Bool = false
    ) {
        self.mediaURL = mediaURL
        self.sentenceStart = sentenceStart
        self.sentenceEnd = sentenceEnd
        self.chapterOffset = chapterOffset
        self.mediaDuration = mediaDuration
        self.isProtected = isProtected
    }
}

struct AnkiExportCard: Equatable, Sendable, Identifiable {
    var stableID: String
    var expression: String
    var resolvedSentence: String
    var gloss: String
    var book: String
    var author: String
    var chapter: String
    var timestamp: TimeInterval
    var tags: [String]
    var audio: AnkiAudioSource?

    var id: String { stableID }

    init(
        stableID: String,
        expression: String,
        resolvedSentence: String,
        gloss: String,
        book: String,
        author: String = "",
        chapter: String,
        timestamp: TimeInterval,
        tags: [String] = [],
        audio: AnkiAudioSource? = nil
    ) {
        self.stableID = stableID
        self.expression = expression
        self.resolvedSentence = resolvedSentence
        self.gloss = gloss
        self.book = book
        self.author = author
        self.chapter = chapter
        self.timestamp = timestamp
        self.tags = tags
        self.audio = audio
    }
}

enum AnkiExportOmissionReason: String, Codable, Equatable, Sendable {
    case missingMedia = "missing_media"
    case protectedMedia = "protected_media"
    case unavailableMedia = "unavailable_media"
}

struct AnkiExportOmission: Codable, Equatable, Sendable {
    var cardID: String
    var reason: AnkiExportOmissionReason
}

struct AnkiExportReport: Codable, Equatable, Sendable {
    var cardCount: Int
    var audioClipCount: Int
    var omissions: [AnkiExportOmission]
    var archiveURL: URL
}

protocol AudioClipWriting: Sendable {
    /// The caller owns range normalization; implementations must still refuse
    /// protected/unplayable media and return the actual written duration.
    func writeClip(
        from sourceURL: URL,
        start: TimeInterval,
        end: TimeInterval,
        to destinationURL: URL
    ) async throws -> TimeInterval
}

enum AnkiAudioClipError: Error, Equatable {
    case protectedMedia
    case unavailableMedia
    case invalidRange
}

struct AVAudioClipWriter: AudioClipWriting {
    func writeClip(
        from sourceURL: URL,
        start: TimeInterval,
        end: TimeInterval,
        to destinationURL: URL
    ) async throws -> TimeInterval {
        guard sourceURL.isFileURL, FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw AnkiAudioClipError.unavailableMedia
        }
        let asset = AVURLAsset(url: sourceURL)
        guard try await !asset.load(.hasProtectedContent) else {
            throw AnkiAudioClipError.protectedMedia
        }
        guard try await asset.load(.isPlayable) else {
            throw AnkiAudioClipError.unavailableMedia
        }
        let mediaDuration = try await asset.load(.duration).seconds
        let clampedStart = max(0, start)
        let clampedEnd = min(end, mediaDuration)
        guard clampedEnd > clampedStart else { throw AnkiAudioClipError.invalidRange }
        // Imported M4A/M4B media already carries AAC. Passthrough avoids a
        // lossy second encode and MediaToolbox encoder availability differences.
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AnkiAudioClipError.unavailableMedia
        }
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: clampedStart, preferredTimescale: 600),
            end: CMTime(seconds: clampedEnd, preferredTimescale: 600)
        )
        // Clips carry only audio. Source artwork/metadata can contain private
        // library details and unnecessarily bloats every flat media file.
        exporter.metadata = []
        try await exporter.export(to: destinationURL, as: .m4a)
        return clampedEnd - clampedStart
    }
}

struct AnkiExportService {
    static let clipPadding: TimeInterval = 0.25

    private let temporaryRoot: URL
    private let fileManager: FileManager
    private let log = Logger(subsystem: "com.johnsonzhang.AudioReader", category: "anki-export")

    init(
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.temporaryRoot = temporaryRoot
        self.fileManager = fileManager
    }

    /// Builds a transport ZIP for Anki's text importer. It is intentionally not
    /// an `.apkg`: users unzip, copy flat clips into collection.media, then import TSV.
    func export(
        cards: [AnkiExportCard],
        to archiveURL: URL,
        clipWriter: any AudioClipWriting = AVAudioClipWriter()
    ) async throws -> AnkiExportReport {
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let staging = temporaryRoot.appendingPathComponent("AudioReader-Anki-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        log.info("message=anki.export component=anki-export outcome=started cards=\(cards.count, privacy: .public)")
        var clipByKey: [String: String] = [:]
        var omissions: [AnkiExportOmission] = []
        var rows: [AnkiRow] = []

        for card in cards.sorted(by: stableCardOrder) {
            try Task.checkCancellation()
            var audioReference = ""
            if let audio = card.audio {
                let outcome = try await audioOutcome(
                    cardID: card.stableID,
                    source: audio,
                    staging: staging,
                    cachedClips: &clipByKey,
                    clipWriter: clipWriter
                )
                switch outcome {
                case .clip(let filename):
                    audioReference = "[sound:\(filename)]"
                case .omitted(let omission):
                    omissions.append(omission)
                }
            }
            rows.append(AnkiRow(card: card, audioReference: audioReference))
        }

        let notes = tsv(rows: rows)
        try Data(notes.utf8).write(to: staging.appendingPathComponent("notes.tsv"), options: .atomic)
        let report = AnkiExportReport(
            cardCount: rows.count,
            audioClipCount: Set(clipByKey.values).count,
            omissions: omissions.sorted(by: omissionOrder),
            archiveURL: archiveURL
        )
        let manifest = AnkiManifest(
            format: "audioreader-anki-tsv-media-v1",
            cards: rows.map { .init(stableID: $0.card.stableID, audioFile: $0.audioFilename) },
            report: .init(
                cardCount: report.cardCount,
                audioClipCount: report.audioClipCount,
                omissions: report.omissions
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        try Task.checkCancellation()
        try fileManager.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        do {
            try fileManager.zipItem(
                at: staging,
                to: archiveURL,
                shouldKeepParent: false,
                compressionMethod: .deflate
            )
        } catch {
            try? fileManager.removeItem(at: archiveURL)
            throw error
        }
        log.info("message=anki.export component=anki-export outcome=success cards=\(report.cardCount, privacy: .public) clips=\(report.audioClipCount, privacy: .public) omitted=\(report.omissions.count, privacy: .public)")
        return report
    }

    private func audioOutcome(
        cardID: String,
        source: AnkiAudioSource,
        staging: URL,
        cachedClips: inout [String: String],
        clipWriter: any AudioClipWriting
    ) async throws -> AudioOutcome {
        guard !source.isProtected else {
            return .omitted(.init(cardID: cardID, reason: .protectedMedia))
        }
        guard source.mediaURL.isFileURL, fileManager.fileExists(atPath: source.mediaURL.path) else {
            return .omitted(.init(cardID: cardID, reason: .missingMedia))
        }
        let unclampedStart = source.chapterOffset + source.sentenceStart - Self.clipPadding
        let unclampedEnd = source.chapterOffset + source.sentenceEnd + Self.clipPadding
        let start = max(0, unclampedStart)
        let end = source.mediaDuration.map { min($0, unclampedEnd) } ?? unclampedEnd
        guard end > start else {
            return .omitted(.init(cardID: cardID, reason: .unavailableMedia))
        }
        let key = clipKey(url: source.mediaURL, start: start, end: end)
        if let filename = cachedClips[key] { return .clip(filename) }
        let filename = "audio-\(sha256(key).prefix(24)).m4a"
        let destination = staging.appendingPathComponent(filename)
        do {
            _ = try await clipWriter.writeClip(
                from: source.mediaURL,
                start: start,
                end: end,
                to: destination
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: destination)
            return .omitted(.init(cardID: cardID, reason: .unavailableMedia))
        }
        cachedClips[key] = filename
        return .clip(filename)
    }

    private func tsv(rows: [AnkiRow]) -> String {
        var lines = [
            "#separator:Tab",
            "#html:true",
            "#columns:Stable ID\tExpression\tSentence\tGloss\tBook\tAuthor\tChapter\tTimestamp\tAudio\tTags",
            "#tags column:10",
        ]
        let locale = Locale(identifier: "en_US_POSIX")
        lines += rows.map { row in
            let card = row.card
            return [
                card.stableID,
                card.expression,
                card.resolvedSentence,
                card.gloss,
                card.book,
                card.author,
                card.chapter,
                String(format: "%.3f", locale: locale, card.timestamp),
                row.audioReference,
                card.tags.sorted().map(safeTag).joined(separator: " "),
            ].map(tsvField).joined(separator: "\t")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func tsvField(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
        guard let first = escaped.first, "=+-@".contains(first) else { return escaped }
        return "'" + escaped
    }

    private func safeTag(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
    }

    private func clipKey(url: URL, start: TimeInterval, end: TimeInterval) -> String {
        "\(url.standardizedFileURL.path)|\(String(format: "%.3f", start))|\(String(format: "%.3f", end))"
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func stableCardOrder(_ lhs: AnkiExportCard, _ rhs: AnkiExportCard) -> Bool {
        if lhs.stableID != rhs.stableID { return lhs.stableID < rhs.stableID }
        return lhs.expression < rhs.expression
    }

    private func omissionOrder(_ lhs: AnkiExportOmission, _ rhs: AnkiExportOmission) -> Bool {
        if lhs.cardID != rhs.cardID { return lhs.cardID < rhs.cardID }
        return lhs.reason.rawValue < rhs.reason.rawValue
    }
}

private enum AudioOutcome {
    case clip(String)
    case omitted(AnkiExportOmission)
}

private struct AnkiRow {
    var card: AnkiExportCard
    var audioReference: String

    var audioFilename: String? {
        guard audioReference.hasPrefix("[sound:"), audioReference.hasSuffix("]") else { return nil }
        return String(audioReference.dropFirst(7).dropLast())
    }
}

private struct AnkiManifest: Codable {
    var format: String
    var cards: [Card]
    var report: Report

    struct Card: Codable {
        var stableID: String
        var audioFile: String?
    }

    struct Report: Codable {
        var cardCount: Int
        var audioClipCount: Int
        var omissions: [AnkiExportOmission]
    }
}
