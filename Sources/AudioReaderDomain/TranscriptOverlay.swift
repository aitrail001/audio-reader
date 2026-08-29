import CryptoKit
import Foundation

public struct TranscriptOverlayProvenance: Codable, Equatable, Sendable {
    public var deviceID: String
    public var actorID: String?
    public var createdAt: Date

    public init(deviceID: String, actorID: String? = nil, createdAt: Date) {
        self.deviceID = deviceID
        self.actorID = actorID
        self.createdAt = createdAt
    }
}

/// A correction targets immutable transcript content through `baseFingerprint`.
/// A mismatched base is kept for audit/conflict recovery but must never render.
public struct StoredTranscriptOverlay: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var chapterID: ChapterID
    public var segmentID: String
    public var baseFingerprint: String
    public var correctedText: String
    public var correctedStart: TimeInterval
    public var correctedEnd: TimeInterval
    public var provenance: TranscriptOverlayProvenance
    public var updatedAt: Date

    public init(
        id: String,
        chapterID: ChapterID,
        segmentID: String,
        baseFingerprint: String,
        correctedText: String,
        correctedStart: TimeInterval,
        correctedEnd: TimeInterval,
        provenance: TranscriptOverlayProvenance,
        updatedAt: Date
    ) {
        self.id = id
        self.chapterID = chapterID
        self.segmentID = segmentID
        self.baseFingerprint = baseFingerprint
        self.correctedText = correctedText
        self.correctedStart = correctedStart
        self.correctedEnd = correctedEnd
        self.provenance = provenance
        self.updatedAt = updatedAt
    }

    public static func stableID(chapterID: ChapterID, segmentID: String) -> String {
        "\(escaped(chapterID.rawValue)):\(escaped(segmentID))"
    }

    private static func escaped(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// A candidate identity includes its content and server revision because all
/// edits to one segment intentionally share the overlay's stable entity ID.
public struct StoredTranscriptOverlayCandidate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var overlay: StoredTranscriptOverlay
    public var revision: Int64

    public init(overlay: StoredTranscriptOverlay, revision: Int64, id: String? = nil) {
        self.overlay = overlay
        self.revision = revision
        self.id = id ?? Self.stableID(overlay: overlay, revision: revision)
    }

    public static func stableID(overlay: StoredTranscriptOverlay, revision: Int64) -> String {
        struct Payload: Encodable {
            var overlay: StoredTranscriptOverlay
            var revision: Int64
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Payload(overlay: overlay, revision: revision))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct StoredTranscriptOverlayState: Equatable, Sendable {
    public var current: StoredTranscriptOverlayCandidate
    public var conflicts: [StoredTranscriptOverlayCandidate]

    public init(
        current: StoredTranscriptOverlayCandidate,
        conflicts: [StoredTranscriptOverlayCandidate]
    ) {
        self.current = current
        self.conflicts = conflicts
    }
}

public enum TranscriptOverlayMergeOutcome: Equatable, Sendable {
    case inserted
    case replacedCurrent
    case conflictRetained
    case unchanged
}

public enum TranscriptOverlayValidationError: String, Codable, Error, Equatable, Sendable {
    case missingSegment
    case wrongChapter
    case emptyText
    case negativeTiming
    case durationTooShort
    case outsideChapterBounds
    case overlapsNeighbor
}

public enum TranscriptOverlayApplicationStatus: Codable, Equatable, Sendable {
    case applied
    case staleBase
    case invalid(TranscriptOverlayValidationError)
}

public struct ResolvedTranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var displayText: String
    public var base: StoredTranscriptSegment
    public var appliedOverlayID: String?

    public init(
        id: String,
        start: TimeInterval,
        end: TimeInterval,
        displayText: String,
        base: StoredTranscriptSegment,
        appliedOverlayID: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.displayText = displayText
        self.base = base
        self.appliedOverlayID = appliedOverlayID
    }
}

public struct ResolvedTranscript: Equatable, Sendable {
    public var base: StoredTranscript
    public var segments: [ResolvedTranscriptSegment]
    public var statuses: [String: TranscriptOverlayApplicationStatus]
    public var retainedOverlays: [StoredTranscriptOverlay]

    public init(
        base: StoredTranscript,
        segments: [ResolvedTranscriptSegment],
        statuses: [String: TranscriptOverlayApplicationStatus],
        retainedOverlays: [StoredTranscriptOverlay]
    ) {
        self.base = base
        self.segments = segments
        self.statuses = statuses
        self.retainedOverlays = retainedOverlays
    }
}

public enum TranscriptOverlayResolver {
    public static let minimumDuration: TimeInterval = 0.25

    /// Fingerprints only immutable source fields. Overlay text/timing never feed
    /// the next fingerprint, so restore and conflict checks remain deterministic.
    public static func baseFingerprint(for segment: StoredTranscriptSegment) -> String {
        struct FingerprintPayload: Encodable {
            var id: String
            var start: TimeInterval
            var end: TimeInterval
            var words: [StoredTranscriptWord]
            var ebookText: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = FingerprintPayload(
            id: segment.id,
            start: segment.start,
            end: segment.end,
            words: segment.words,
            ebookText: segment.ebookText
        )
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Resolves all presentation consumers through the same validated overlay
    /// view while preserving the immutable base transcript on the result.
    public static func resolve(
        base: StoredTranscript,
        overlays: [StoredTranscriptOverlay],
        chapterDuration: TimeInterval? = nil
    ) -> ResolvedTranscript {
        let selected = Dictionary(
            overlays.sorted { $0.updatedAt < $1.updatedAt }.map { ($0.segmentID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var statuses: [String: TranscriptOverlayApplicationStatus] = [:]
        var resolved: [ResolvedTranscriptSegment] = []

        for (index, segment) in base.segments.enumerated() {
            let original = ResolvedTranscriptSegment(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                displayText: segment.displayText,
                base: segment
            )
            guard let overlay = selected[segment.id] else {
                resolved.append(original)
                continue
            }
            guard overlay.chapterID == base.chapterID else {
                statuses[overlay.id] = .invalid(.wrongChapter)
                resolved.append(original)
                continue
            }
            guard overlay.baseFingerprint == baseFingerprint(for: segment) else {
                statuses[overlay.id] = .staleBase
                resolved.append(original)
                continue
            }
            if let error = validationError(
                overlay,
                index: index,
                baseSegments: base.segments,
                chapterDuration: chapterDuration
            ) {
                statuses[overlay.id] = .invalid(error)
                resolved.append(original)
                continue
            }
            statuses[overlay.id] = .applied
            resolved.append(
                ResolvedTranscriptSegment(
                    id: segment.id,
                    start: overlay.correctedStart,
                    end: overlay.correctedEnd,
                    displayText: overlay.correctedText.trimmingCharacters(in: .whitespacesAndNewlines),
                    base: segment,
                    appliedOverlayID: overlay.id
                )
            )
        }

        for overlay in overlays where !base.segments.contains(where: { $0.id == overlay.segmentID }) {
            statuses[overlay.id] = .invalid(.missingSegment)
        }
        return ResolvedTranscript(
            base: base,
            segments: resolved,
            statuses: statuses,
            retainedOverlays: overlays.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.id < rhs.id
            }
        )
    }

    private static func validationError(
        _ overlay: StoredTranscriptOverlay,
        index: Int,
        baseSegments: [StoredTranscriptSegment],
        chapterDuration: TimeInterval?
    ) -> TranscriptOverlayValidationError? {
        guard !overlay.correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .emptyText
        }
        guard overlay.correctedStart >= 0, overlay.correctedEnd >= 0 else {
            return .negativeTiming
        }
        guard overlay.correctedEnd - overlay.correctedStart >= minimumDuration else {
            return .durationTooShort
        }
        if let chapterDuration, overlay.correctedEnd > chapterDuration {
            return .outsideChapterBounds
        }
        if index > 0, overlay.correctedStart < baseSegments[index - 1].end {
            return .overlapsNeighbor
        }
        if index + 1 < baseSegments.count, overlay.correctedEnd > baseSegments[index + 1].start {
            return .overlapsNeighbor
        }
        return nil
    }
}

public extension StoredTranscriptSegment {
    var spokenText: String {
        words.map(\.text).joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayText: String {
        guard individualEbookMatchTrusted == true,
              documentEbookUseAllowed == true,
              let ebookText,
              !ebookText.isEmpty
        else { return spokenText }
        return ebookText
    }
}
