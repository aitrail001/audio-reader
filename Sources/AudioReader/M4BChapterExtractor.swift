import AVFoundation
import Foundation

struct EmbeddedM4BChapter: Codable, Hashable, Sendable {
    var title: String
    var start: TimeInterval
    var duration: TimeInterval
}

enum M4BChapterExtractor {
    private static let sidecarName = ".audioreader-chapters.json"

    static func extract(from url: URL) async -> [EmbeddedM4BChapter] {
        let asset = AVURLAsset(url: url)
        guard let locales = try? await asset.load(.availableChapterLocales) else { return [] }

        var groups: [AVTimedMetadataGroup] = []
        for locale in locales {
            if let localized = try? await asset.loadChapterMetadataGroups(
                withTitleLocale: locale,
                containingItemsWithCommonKeys: []
            ), !localized.isEmpty {
                groups = localized
                break
            }
        }
        if groups.isEmpty {
            groups = (try? await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: Locale.preferredLanguages
            )) ?? []
        }

        var chapters: [EmbeddedM4BChapter] = []
        for (index, group) in groups.enumerated() {
            let start = group.timeRange.start.seconds
            let duration = group.timeRange.duration.seconds
            guard start.isFinite, duration.isFinite, duration > 0 else { continue }
            var title: String?
            for item in group.items {
                guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                if item.commonKey == .commonKeyTitle {
                    title = value
                    break
                }
                if title == nil { title = value }
            }
            chapters.append(.init(
                title: title ?? "Chapter \(index + 1)",
                start: start,
                duration: duration
            ))
        }
        return chapters
    }

    static func makeChapters(audioPath: String, metadata: [EmbeddedM4BChapter]) -> [Chapter] {
        metadata.enumerated().map { index, item in
            Chapter(
                id: LibraryScanner.stableID("\(audioPath)#\(String(format: "%.3f", item.start))"),
                index: index,
                title: item.title,
                audioPath: audioPath,
                duration: item.duration,
                startTime: item.start
            )
        }
    }

    static func save(_ metadata: [EmbeddedM4BChapter], in folder: URL) throws {
        guard !metadata.isEmpty else { return }
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: folder.appendingPathComponent(sidecarName), options: .atomic)
    }

    static func load(in folder: URL) -> [EmbeddedM4BChapter] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(sidecarName)) else { return [] }
        return (try? JSONDecoder().decode([EmbeddedM4BChapter].self, from: data)) ?? []
    }
}
