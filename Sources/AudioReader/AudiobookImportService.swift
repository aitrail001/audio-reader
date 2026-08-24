import CryptoKit
import Foundation

struct AudiobookImportResult: Sendable {
    var folder: URL
    var createdBook: Bool
    var addedFileNames: [String]
}

final class EbookReplacementTransaction {
    let destination: URL
    private let backup: URL
    private let originals: [(backupURL: URL, originalURL: URL)]
    private var completed = false

    init(
        destination: URL,
        backup: URL,
        originals: [(backupURL: URL, originalURL: URL)]
    ) {
        self.destination = destination
        self.backup = backup
        self.originals = originals
    }

    func commit() {
        guard !completed else { return }
        try? FileManager.default.removeItem(at: backup)
        completed = true
    }

    func rollback() throws {
        guard !completed else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        for original in originals {
            try fm.createDirectory(
                at: original.originalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.moveItem(at: original.backupURL, to: original.originalURL)
        }
        try? fm.removeItem(at: backup)
        completed = true
    }
}

enum AudiobookImportError: LocalizedError {
    case noAudioFiles
    case protectedOrUnavailable
    case exportUnavailable
    case unsafeDeletionTarget
    case invalidEbook
    case replacementRollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioFiles: "No supported MP3, M4A, M4B, AAC, WAV, or CAF audiobook files were found."
        case .protectedOrUnavailable: "This audiobook is protected or not downloaded as an accessible media file."
        case .exportUnavailable: "This audiobook cannot be copied into AudioReader for transcription."
        case .unsafeDeletionTarget: "AudioReader can only delete a book stored directly in its imported library."
        case .invalidEbook: "Choose a readable EPUB file."
        case .replacementRollbackFailed(let detail):
            "The EPUB replacement could not be rolled back completely: \(detail)"
        }
    }
}

enum AudiobookImportService {
    private static let fingerprintMarker = ".audioreader-audio-fingerprint"

    @discardableResult
    static func importFiles(_ urls: [URL], into root: URL = Persistence.importedBooksURL) throws -> AudiobookImportResult {
        let audio = urls.filter { LibraryScanner.audioExt.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else { throw AudiobookImportError.noAudioFiles }
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let fingerprint = try audioFingerprint(for: audio)
        if let existing = try existingBookFolder(matchingFingerprint: fingerprint, in: root) {
            let added = try copyCompanionFiles(from: urls, to: existing)
            return .init(folder: existing, createdBook: false, addedFileNames: added)
        }
        let title = audio.first?.deletingPathExtension().lastPathComponent ?? "Imported Audiobook"
        let folder = try newBookFolder(title: title, in: root)
        try writeMarkers(source: .files, title: title, author: nil, to: folder)
        for url in urls where isSupportedImport(url) {
            try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
        try writeMarker(fingerprint, named: fingerprintMarker, to: folder)
        return .init(folder: folder, createdBook: true, addedFileNames: urls.map(\.lastPathComponent))
    }

    @discardableResult
    static func importFolder(_ url: URL, into root: URL = Persistence.importedBooksURL) throws -> [AudiobookImportResult] {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let bookFolders = children.filter { candidate in
            (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && LibraryScanner.containsAudio(in: candidate)
        }
        let sources = bookFolders.isEmpty ? [url] : bookFolders
        guard sources.contains(where: { LibraryScanner.containsAudio(in: $0) }) else {
            throw AudiobookImportError.noAudioFiles
        }
        return try sources.map { source in
            let audio = audioFiles(in: source)
            let fingerprint = try audioFingerprint(for: audio)
            if let existing = try existingBookFolder(matchingFingerprint: fingerprint, in: root) {
                let added = try copyCompanionFiles(from: allFiles(in: source), to: existing)
                return .init(folder: existing, createdBook: false, addedFileNames: added)
            }
            let destination = try newBookFolder(title: source.lastPathComponent, in: root)
            try copyDirectoryContents(from: source, to: destination)
            try writeMarkers(source: .localFolder, title: source.lastPathComponent, author: nil, to: destination)
            try writeMarker(fingerprint, named: fingerprintMarker, to: destination)
            return .init(folder: destination, createdBook: true, addedFileNames: allFiles(in: source).map(\.lastPathComponent))
        }
    }

    @discardableResult
    static func addCompanionFiles(_ urls: [URL], to folder: URL) throws -> [String] {
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try copyCompanionFiles(from: urls, to: folder)
    }

    @discardableResult
    static func replaceEbook(_ source: URL, in folder: URL) throws -> URL {
        let replacement = try stageEbookReplacement(source, in: folder)
        replacement.commit()
        return replacement.destination
    }

    static func stageEbookReplacement(
        _ source: URL,
        in folder: URL
    ) throws -> EbookReplacementTransaction {
        guard source.pathExtension.lowercased() == "epub" else { throw AudiobookImportError.invalidEbook }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard EPUBParser.document(from: source.path) != nil else { throw AudiobookImportError.invalidEbook }

        let fm = FileManager.default
        let temporary = folder.appendingPathComponent(
            ".audioreader-ebook-replacement-\(UUID().uuidString).epub"
        )
        let backup = folder.appendingPathComponent(
            ".audioreader-ebook-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.copyItem(at: source, to: temporary)
        var originals: [(backupURL: URL, originalURL: URL)] = []
        do {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            let existingEbooks = allFiles(in: folder)
                .filter { $0.pathExtension.lowercased() == "epub" && $0 != temporary }
            for (index, existing) in existingEbooks.enumerated() {
                let backupURL = backup.appendingPathComponent("\(index)-\(existing.lastPathComponent)")
                try fm.moveItem(
                    at: existing,
                    to: backupURL
                )
                originals.append((backupURL, existing))
            }
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            try fm.moveItem(at: temporary, to: destination)
            return EbookReplacementTransaction(
                destination: destination,
                backup: backup,
                originals: originals
            )
        } catch {
            try? fm.removeItem(at: temporary)
            for original in originals.reversed() {
                try? fm.createDirectory(
                    at: original.originalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? fm.moveItem(at: original.backupURL, to: original.originalURL)
            }
            try? fm.removeItem(at: backup)
            throw error
        }
    }

    static func isReadableEbook(_ source: URL) -> Bool {
        guard source.pathExtension.lowercased() == "epub" else { return false }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        return EPUBParser.document(from: source.path) != nil
    }

    static func newBookFolder(title: String, in root: URL = Persistence.importedBooksURL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let safe = title.replacingOccurrences(of: #"[^A-Za-z0-9 _-]"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safe.isEmpty ? "Imported Audiobook" : safe
        var destination = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = root.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    static func writeMarkers(source: BookSource, title: String, author: String?, to folder: URL) throws {
        try Data(source.rawValue.utf8).write(to: folder.appendingPathComponent(".audioreader-source"), options: .atomic)
        try Data(title.utf8).write(to: folder.appendingPathComponent(".audioreader-title"), options: .atomic)
        if let author, !author.isEmpty {
            try Data(author.utf8).write(to: folder.appendingPathComponent(".audioreader-author"), options: .atomic)
        }
    }

    static func writeDeviceID(_ id: UInt64, to folder: URL) throws {
        try writeMarker(String(id), named: ".audioreader-device-id", to: folder)
    }

    static func existingBookFolder(deviceID: UInt64, in root: URL = Persistence.importedBooksURL) -> URL? {
        existingBookFolders(in: root).first {
            textMarker(named: ".audioreader-device-id", in: $0) == String(deviceID)
        }
    }

    static func existingBookFolder(matchingAudioAt url: URL, in root: URL = Persistence.importedBooksURL) throws -> URL? {
        try existingBookFolder(matchingFingerprint: audioFingerprint(for: [url]), in: root)
    }

    static func recordAudioFingerprint(for url: URL, in folder: URL) throws {
        try writeMarker(audioFingerprint(for: [url]), named: fingerprintMarker, to: folder)
    }

    static func deleteBookFolder(_ folder: URL, in root: URL = Persistence.importedBooksURL) throws {
        let safeFolder = try validatedBookFolder(folder, in: root)
        try FileManager.default.removeItem(at: safeFolder)
    }

#if os(macOS)
    static func trashBookFolder(_ folder: URL, in root: URL) throws {
        let safeFolder = try validatedBookFolder(folder, in: root)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: safeFolder, resultingItemURL: &resultingURL)
    }
#endif

    private static func isSupportedImport(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return LibraryScanner.audioExt.contains(ext)
            || LibraryScanner.ebookExt.contains(ext)
            || LibraryScanner.coverExt.contains(ext)
    }

    private static func existingBookFolder(matchingFingerprint fingerprint: String, in root: URL) throws -> URL? {
        for folder in existingBookFolders(in: root) {
            if textMarker(named: fingerprintMarker, in: folder) == fingerprint { return folder }
            let audio = audioFiles(in: folder)
            guard !audio.isEmpty else { continue }
            let existing = try audioFingerprint(for: audio)
            try? writeMarker(existing, named: fingerprintMarker, to: folder)
            if existing == fingerprint { return folder }
        }
        return nil
    }

    private static func audioFingerprint(for urls: [URL]) throws -> String {
        let digests = try urls.map(fileDigest).sorted()
        return SHA256.hash(data: Data(digests.joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func copyCompanionFiles(from urls: [URL], to folder: URL) throws -> [String] {
        var added: [String] = []
        for source in urls where isSupportedImport(source) && !LibraryScanner.audioExt.contains(source.pathExtension.lowercased()) {
            let destination = try uniqueDestination(for: source, in: folder)
            guard destination != nil else { continue }
            try FileManager.default.copyItem(at: source, to: destination!)
            added.append(destination!.lastPathComponent)
        }
        return added
    }

    private static func uniqueDestination(for source: URL, in folder: URL) throws -> URL? {
        let fm = FileManager.default
        let initial = folder.appendingPathComponent(source.lastPathComponent)
        if !fm.fileExists(atPath: initial.path) { return initial }
        if try fileDigest(source) == fileDigest(initial) { return nil }
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var suffix = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            if try fileDigest(source) == fileDigest(candidate) { return nil }
            suffix += 1
        }
    }

    private static func existingBookFolders(in root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []
    }

    private static func audioFiles(in folder: URL) -> [URL] {
        allFiles(in: folder).filter { LibraryScanner.audioExt.contains($0.pathExtension.lowercased()) }
    }

    private static func allFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private static func writeMarker(_ value: String, named name: String, to folder: URL) throws {
        try Data(value.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    private static func textMarker(named name: String, in folder: URL) -> String? {
        guard let raw = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func validatedBookFolder(_ folder: URL, in root: URL) throws -> URL {
        let safeRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let safeFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        guard safeFolder != safeRoot,
              safeFolder.deletingLastPathComponent() == safeRoot
        else {
            throw AudiobookImportError.unsafeDeletionTarget
        }
        return safeFolder
    }

    private static func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            try FileManager.default.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
        }
    }
}
