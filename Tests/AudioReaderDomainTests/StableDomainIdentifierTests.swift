import Foundation
import Testing
@testable import AudioReaderDomain

@Suite("Stable domain identifiers")
struct StableDomainIdentifierTests {
    private let absoluteBookPath = "/Users/alex/Books/Moby-Dick"
    private let iOSContainerPath =
        "/var/mobile/Containers/Data/Application/ABC/Documents/ImportedBooks/The Ride"

    @Test("legacy Book and Chapter JSON decode into stable IDs")
    func legacyBookAndChapterJSONDecodeIntoStableIDs() throws {
        let json = Data("""
        {
          "id": "c0ffeelegacybookid",
          "title": "Moby-Dick",
          "author": "Herman Melville",
          "folderPath": "\(absoluteBookPath)",
          "coverPath": "\(absoluteBookPath)/cover.jpg",
          "ebookPath": "\(absoluteBookPath)/book.epub",
          "chapters": [
            {
              "id": "c0ffeelegacychapterid",
              "index": 0,
              "title": "Loomings",
              "audioPath": "\(absoluteBookPath)/01.m4b",
              "duration": 321.5,
              "startTime": null
            }
          ],
          "source": "localFolder"
        }
        """.utf8)

        let book = try JSONDecoder().decode(LegacyBookJSON.self, from: json)

        #expect(book.id == BookID(rawValue: "c0ffeelegacybookid"))
        #expect(book.title == "Moby-Dick")
        #expect(book.chapters.count == 1)
        #expect(book.chapters[0].id == ChapterID(rawValue: "c0ffeelegacychapterid"))
        #expect(book.chapters[0].index == 0)
        #expect(book.chapters[0].title == "Loomings")
        #expect(book.id.rawValue != absoluteBookPath)
        #expect(book.chapters[0].id.rawValue != "\(absoluteBookPath)/01.m4b")
    }

    @Test("typed IDs round-trip through Codable")
    func idsRoundTripThroughCodable() throws {
        try assertStringIDRoundTrip(UserID(rawValue: "user-1"))
        try assertStringIDRoundTrip(DeviceID(rawValue: "device-1"))
        try assertStringIDRoundTrip(BookID(rawValue: "c0ffeelegacybookid"))
        try assertStringIDRoundTrip(AssetID(rawValue: "asset-1"))
        try assertStringIDRoundTrip(ChapterID(rawValue: "c0ffeelegacychapterid"))
        try assertStringIDRoundTrip(TranscriptRevisionID(rawValue: "revision-1"))
        try assertStringIDRoundTrip(VocabularyOccurrenceID(rawValue: "occurrence-1"))
        try assertStringIDRoundTrip(ReviewEventID(rawValue: "review-1"))
        try assertStringIDRoundTrip(MutationID(rawValue: "mutation-1"))

        let version = ServerVersion(7)
        let versionData = try JSONEncoder().encode(version)
        #expect(String(data: versionData, encoding: .utf8) == "7")
        #expect(try JSONDecoder().decode(ServerVersion.self, from: versionData) == version)
    }

    @Test("newly created IDs are unique and path-independent")
    func newlyCreatedIDsAreUniqueAndPathIndependent() {
        assertGeneratedIDsAreUniqueAndPathIndependent(UserID.self)
        assertGeneratedIDsAreUniqueAndPathIndependent(DeviceID.self)
        assertGeneratedIDsAreUniqueAndPathIndependent(BookID.self)
        assertGeneratedIDsAreUniqueAndPathIndependent(AssetID.self)
        assertGeneratedIDsAreUniqueAndPathIndependent(ChapterID.self)
        assertGeneratedIDsAreUniqueAndPathIndependent(TranscriptRevisionID.self)
        assertGeneratedIDsAreUniqueAndPathIndependent(VocabularyOccurrenceID.self)
        assertGeneratedIDsAreUniqueAndPathIndependent(ReviewEventID.self)
        assertGeneratedIDsAreUniqueAndPathIndependent(MutationID.self)
    }

    @Test("no absolute path is used to derive a remote ID")
    func remoteIDsAreNotDerivedFromAbsolutePaths() throws {
        let paths = [
            absoluteBookPath,
            iOSContainerPath,
            "file://\(absoluteBookPath)",
            "~/Books/Moby-Dick",
            "\(absoluteBookPath)#0.000",
        ]

        for path in paths {
            #expect(BookID.remote(rawValue: path) == nil)
            #expect(AssetID.remote(rawValue: path) == nil)
            #expect(ChapterID.remote(rawValue: path) == nil)
        }

        let uuid = UUID().uuidString.lowercased()
        #expect(BookID.remote(rawValue: uuid) == BookID(rawValue: uuid))
        #expect(ChapterID.remote(rawValue: uuid) == ChapterID(rawValue: uuid))

        let generated = BookID.generate()
        #expect(BookID.remote(rawValue: generated.rawValue) == generated)
        #expect(!generated.rawValue.contains(absoluteBookPath))
        #expect(UUID(uuidString: generated.rawValue) != nil)

        let domainRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AudioReaderDomain", isDirectory: true)
        let joined = try String(
            contentsOf: domainRoot.appendingPathComponent("StableDomainIDs.swift"),
            encoding: .utf8
        )

        #expect(!joined.contains("SHA256"))
        #expect(!joined.contains("folderPath"))
        #expect(!joined.contains("audioPath"))
        #expect(!joined.contains("stableID"))
        #expect(!joined.contains("persistentPathIdentity"))
    }

    private func assertStringIDRoundTrip<ID: StableDomainIdentifier>(_ value: ID) throws {
        let data = try JSONEncoder().encode(value)
        #expect(String(data: data, encoding: .utf8) == "\"\(value.rawValue)\"")
        #expect(try JSONDecoder().decode(ID.self, from: data) == value)
    }

    private func assertGeneratedIDsAreUniqueAndPathIndependent<ID: StableDomainIdentifier>(
        _: ID.Type
    ) {
        var seen: Set<ID> = []
        for _ in 0..<32 {
            let id = ID.generate()
            #expect(seen.insert(id).inserted)
            #expect(!id.rawValue.contains(absoluteBookPath))
            #expect(!id.rawValue.contains("/"))
            #expect(!id.rawValue.contains("\\"))
            #expect(UUID(uuidString: id.rawValue) != nil)
        }
    }
}
