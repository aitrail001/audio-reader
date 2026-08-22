import Foundation
import Speech
import AVFoundation
import CoreMedia

enum TranscriptionError: LocalizedError {
    case unavailable
    case noAudio
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "On-device speech transcription is not available on this Mac."
        case .noAudio: "Could not open the audio file."
        case .cancelled: "Transcription was cancelled."
        case .failed(let s): s
        }
    }
}

struct TranscriptionProgress: Sendable {
    var fraction: Double
    var message: String
}

actor Transcriber {
    private var analyzer: SpeechAnalyzer?

    func transcribe(
        chapter: Chapter,
        ebookPath: String?,
        progress: @Sendable @escaping (TranscriptionProgress) -> Void,
        checkpoint: @Sendable @escaping (String, [TranscriptSegment]) -> Void
    ) async throws -> Transcript {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }

        progress(.init(fraction: 0.02, message: "Preparing speech model…"))

        let requested = Locale(identifier: "en-US")
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) ?? requested

        let speech = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [speech]) {
            progress(.init(fraction: 0.05, message: "Installing English speech assets…"))
            try await request.downloadAndInstall()
        }

        let url = URL(fileURLWithPath: chapter.audioPath)
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.noAudio
        }

        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let engine = SpeechAnalyzer(modules: [speech])
        self.analyzer = engine

        progress(.init(fraction: 0.08, message: "Listening…"))

        let collector = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in speech.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                let words = words(from: result)
                guard !words.isEmpty else { continue }
                let seg = TranscriptSegment(
                    id: UUID().uuidString,
                    start: words.first?.start ?? result.range.start.seconds,
                    end: words.last?.end ?? result.range.end.seconds,
                    words: words,
                    ebookText: nil,
                    alignmentScore: nil
                )
                segments.append(seg)
                let frac = min(0.92, 0.08 + (seg.end / max(duration, 1)) * 0.84)
                progress(.init(fraction: frac, message: "Transcribing \(formatClock(seg.end)) / \(formatClock(duration))"))
                if segments.count == 1 || segments.count % 6 == 0 {
                    checkpoint(locale.identifier, segments)
                }
            }
            return segments
        }

        do {
            if let last = try await engine.analyzeSequence(from: audioFile) {
                try await engine.finalizeAndFinish(through: last)
            } else {
                try await engine.finalizeAndFinishThroughEndOfInput()
            }
        } catch is CancellationError {
            await engine.cancelAndFinishNow()
            collector.cancel()
            throw TranscriptionError.cancelled
        } catch {
            await engine.cancelAndFinishNow()
            collector.cancel()
            throw TranscriptionError.failed(error.localizedDescription)
        }

        let segments = try await collector.value
        checkpoint(locale.identifier, segments)
        progress(.init(fraction: 0.94, message: "Saved. Aligning with ebook…"))

        var aligned = segments
        var didAlign = false
        if let ebookPath, let ebookText = EPUBParser.extractText(from: ebookPath) {
            aligned = Aligner.align(segments: segments, ebookText: ebookText)
            didAlign = aligned.contains { $0.ebookText != nil }
        }

        progress(.init(fraction: 1.0, message: "Done"))

        return Transcript(
            chapterID: chapter.id,
            audioPath: chapter.audioPath,
            createdAt: Date(),
            locale: locale.identifier,
            segments: aligned,
            source: "SpeechAnalyzer",
            ebookAligned: didAlign
        )
    }

    func cancel() async {
        await analyzer?.cancelAndFinishNow()
    }

    private func words(from result: SpeechTranscriber.Result) -> [TranscriptWord] {
        var out: [TranscriptWord] = []
        for run in result.text.runs {
            let token = String(result.text[run.range].characters)
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let range = run.audioTimeRange
            let start = range?.start.seconds ?? result.range.start.seconds
            let end = range?.end.seconds ?? result.range.end.seconds
            let conf: Double?
            if let c = run.transcriptionConfidence {
                conf = Double(c)
            } else {
                conf = nil
            }
            out.append(
                TranscriptWord(
                    id: UUID().uuidString,
                    text: token,
                    start: start,
                    end: max(end, start + 0.04),
                    confidence: conf
                )
            )
        }
        return out
    }
}

func formatClock(_ t: TimeInterval) -> String {
    guard t.isFinite && t >= 0 else { return "0:00" }
    let total = Int(t.rounded(.down))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}
