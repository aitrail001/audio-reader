#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
enum MacAudiobookImporter {
    static func chooseFiles(libraryRoot: URL) throws -> Int? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .epub, .image]
        panel.prompt = "Import"
        panel.message = "Choose audiobook audio and/or EPUB files, and optionally a cover image."
        guard panel.runModal() == .OK else { return nil }
        try AudiobookImportService.importFiles(panel.urls, into: libraryRoot)
        return panel.urls.count
    }

    static func chooseFolder(libraryRoot: URL) throws -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Folder"
        panel.message = "Choose one book folder, or a folder containing audiobook and/or EPUB folders."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try AudiobookImportService.importFolder(url, into: libraryRoot)
        return url.lastPathComponent
    }

    static func chooseCompanionFiles(for book: Book) throws -> [String]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .epub, .image]
        panel.prompt = "Add to Book"
        panel.message = "Choose audio, an EPUB, and/or cover artwork for \(book.title)."
        guard panel.runModal() == .OK else { return nil }
        return try AudiobookImportService.addCompanionFiles(
            panel.urls,
            to: URL(fileURLWithPath: book.folderPath, isDirectory: true)
        )
    }

    static func chooseEbook(for book: Book, replacingExisting: Bool) throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.epub]
        panel.prompt = replacingExisting ? "Replace EPUB" : "Add EPUB"
        panel.message = replacingExisting
            ? "Choose a replacement EPUB for \(book.title)."
            : "Choose a companion EPUB for \(book.title)."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    static func chooseAudio(for book: Book) throws -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Add Audio"
        panel.message = "Choose audiobook audio for \(book.title)."
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }
}
#endif
