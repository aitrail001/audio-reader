import Foundation

enum VocabSentencePlayback {
    static let fallbackDuration: TimeInterval = 6

    static func bounds(
        for entry: VocabEntry,
        transcript: Transcript?
    ) -> (start: TimeInterval, end: TimeInterval) {
        let fallbackStart = max(0, entry.timestamp)
        let fallback = (fallbackStart, fallbackStart + fallbackDuration)
        guard let transcript else { return fallback }

        if let segmentID = entry.segmentID,
           let segment = transcript.segments.first(where: { $0.id == segmentID }) {
            return clamped(segment)
        }

        if let containing = containingSegment(for: entry.timestamp, in: transcript.segments) {
            return clamped(containing)
        }

        if let nearest = transcript.segments.min(by: {
            abs($0.start - entry.timestamp) < abs($1.start - entry.timestamp)
        }), abs(nearest.start - entry.timestamp) < 0.4 {
            return clamped(nearest)
        }

        let normalized = GlossEntry.normalize(entry.context)
        if !normalized.isEmpty,
           let segment = transcript.segments.first(where: {
               GlossEntry.normalize($0.spokenText) == normalized
                   || GlossEntry.normalize($0.displayText) == normalized
           }) {
            return clamped(segment)
        }

        return fallback
    }

    private static func containingSegment(
        for timestamp: TimeInterval,
        in segments: [TranscriptSegment]
    ) -> TranscriptSegment? {
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            if timestamp >= segment.start,
               timestamp < segment.end || (isLast && timestamp <= segment.end + 0.05) {
                return segment
            }
        }
        return nil
    }

    private static func clamped(_ segment: TranscriptSegment) -> (start: TimeInterval, end: TimeInterval) {
        (segment.start, max(segment.end, segment.start + 0.25))
    }
}
