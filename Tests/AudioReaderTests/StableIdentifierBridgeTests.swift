import Foundation
import Testing
import AudioReaderDomain
@testable import AudioReader

@Suite("Book and Chapter typed ID bridge")
struct StableIdentifierBridgeTests {
    @Test("legacy Book and Chapter JSON decode into stable IDs without rewriting stored strings")
    func legacyBookJSONDecodesIntoTypedIDs() throws {
        let json = Data("""
        {
          "id": "c0ffeelegacybookid",
          "title": "Moby-Dick",
          "author": "Herman Melville",
          "folderPath": "/Users/alex/Books/Moby-Dick",
          "coverPath": null,
          "ebookPath": "/Users/alex/Books/Moby-Dick/book.epub",
          "chapters": [
            {
              "id": "c0ffeelegacychapterid",
              "index": 0,
              "title": "Loomings",
              "audioPath": "/Users/alex/Books/Moby-Dick/01.m4b",
              "duration": 321.5
            }
          ],
          "source": "localFolder"
        }
        """.utf8)

        let book = try JSONDecoder().decode(Book.self, from: json)

        #expect(book.id == "c0ffeelegacybookid")
        #expect(book.bookID == BookID(rawValue: "c0ffeelegacybookid"))
        #expect(book.chapters[0].id == "c0ffeelegacychapterid")
        #expect(book.chapters[0].chapterID == ChapterID(rawValue: "c0ffeelegacychapterid"))

        let encoded = try JSONEncoder().encode(book)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["id"] as? String == "c0ffeelegacybookid")
        #expect(object["bookID"] == nil)
    }
}
