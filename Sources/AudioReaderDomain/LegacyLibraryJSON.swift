import Foundation

/// Decodes current library Book JSON, mapping string `id` fields onto typed IDs.
public struct LegacyBookJSON: Codable, Sendable, Equatable {
    public var id: BookID
    public var title: String
    public var chapters: [LegacyChapterJSON]
}

/// Decodes current library Chapter JSON, mapping string `id` fields onto typed IDs.
public struct LegacyChapterJSON: Codable, Sendable, Equatable {
    public var id: ChapterID
    public var index: Int
    public var title: String
}
