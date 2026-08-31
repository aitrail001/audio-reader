import CryptoKit
import Foundation
import OSLog

struct AudiobookImportResult: Sendable {
    var folder: URL
    var createdBook: Bool
    var addedFileNames: [String]
}

struct AudiobookImportDuplicate: Identifiable, Sendable {
    var existingFolder: URL
    var title: String

    var id: String { existingFolder.standardizedFileURL.path }
}

struct AudiobookImportPreflight: Sendable {
    var duplicates: [AudiobookImportDuplicate]
    var enrichesExistingBook: Bool

    var requiresConfirmation: Bool { !duplicates.isEmpty }
}

struct DeviceAudiobookImportPreflight: Sendable {
    let identity: AudiobookImportPreflight
    let stagingFolder: URL?
    let stagedAudio: URL?

    /// Pending confirmation owns temporary export bytes and must discard them
    /// on cancel; this folder is never inside the imported-books library.
    func discard() {
        guard let stagingFolder else { return }
        let safeTemporaryRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL
        let safeFolder = stagingFolder.resolvingSymlinksInPath().standardizedFileURL
        guard safeFolder.deletingLastPathComponent() == safeTemporaryRoot,
              safeFolder.lastPathComponent.hasPrefix("AudioReader-device-import-")
        else { return }
        try? FileManager.default.removeItem(at: safeFolder)
    }
}

enum AudiobookDuplicateImportPolicy: Sendable {
    case keepExisting
    case confirmedReimport
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
    case noSupportedBookFiles
    case protectedOrUnavailable
    case exportUnavailable
    case unsafeDeletionTarget
    case invalidEbook
    case duplicateConfirmationMissing
    case replacementRollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioFiles: "No supported MP3, M4A, M4B, AAC, WAV, or CAF audiobook files were found."
        case .noSupportedBookFiles: "No supported audiobook audio or readable EPUB files were found."
        case .protectedOrUnavailable: "This audiobook is protected or not downloaded as an accessible media file."
        case .exportUnavailable: "This audiobook cannot be copied into AudioReader for transcription."
        case .unsafeDeletionTarget: "AudioReader can only delete a book stored directly in its imported library."
        case .invalidEbook: "Choose a readable EPUB file."
        case .duplicateConfirmationMissing: "The matching imported book could not be confirmed."
        case .replacementRollbackFailed(let detail):
            "The EPUB replacement could not be rolled back completely: \(detail)"
        }
    }
}

enum AudiobookImportService {
    private static let log = Logger(subsystem: "com.johnsonzhang.AudioReader", category: "book-import")
    private static let fingerprintMarker = ".audioreader-audio-fingerprint"
    private static let ebookSectionsMarker = ".audioreader-ebook-sections"

    @discardableResult
    /// Classifies a selection before any library folder or marker is created.
    /// Callers must present confirmation when `requiresConfirmation` is true.
    static func preflightFiles(
        _ urls: [URL],
        into root: URL = Persistence.importedBooksURL
    ) throws -> AudiobookImportPreflight {
        let requestID = UUID().uuidString
        log.info("book_import_preflight_started message=book_import_preflight_started requestId=\(requestID, privacy: .public) component=book-import source=files selected_count=\(urls.count, privacy: .public)")
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        do {
            let result = preflight(for: [try importPlan(for: urls, in: root)])
            log.info("book_import_preflight_finished message=book_import_preflight_finished requestId=\(requestID, privacy: .public) component=book-import source=files outcome=success duplicate_count=\(result.duplicates.count, privacy: .public) enrichment=\(result.enrichesExistingBook, privacy: .public)")
            return result
        } catch {
            log.error("book_import_preflight_finished message=book_import_preflight_finished requestId=\(requestID, privacy: .public) component=book-import source=files outcome=failure error_type=\(String(reflecting: type(of: error)), privacy: .public)")
            throw error
        }
    }

    static func preflightFolder(
        _ url: URL,
        into root: URL = Persistence.importedBooksURL
    ) throws -> AudiobookImportPreflight {
        let requestID = UUID().uuidString
        log.info("book_import_preflight_started message=book_import_preflight_started requestId=\(requestID, privacy: .public) component=book-import source=folder")
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let sources = importSourceFolders(in: url)
            guard sources.contains(where: { LibraryScanner.containsBookMedia(in: $0) }) else {
                throw AudiobookImportError.noSupportedBookFiles
            }
            let result = preflight(for: try sources.map { source in
                try importPlan(for: allFiles(in: source), in: root)
            })
            log.info("book_import_preflight_finished message=book_import_preflight_finished requestId=\(requestID, privacy: .public) component=book-import source=folder outcome=success duplicate_count=\(result.duplicates.count, privacy: .public) enrichment=\(result.enrichesExistingBook, privacy: .public)")
            return result
        } catch {
            log.error("book_import_preflight_finished message=book_import_preflight_finished requestId=\(requestID, privacy: .public) component=book-import source=folder outcome=failure error_type=\(String(reflecting: type(of: error)), privacy: .public)")
            throw error
        }
    }

    @discardableResult
    static func importFiles(
        _ urls: [URL],
        into root: URL = Persistence.importedBooksURL,
        duplicatePolicy: AudiobookDuplicateImportPolicy = .keepExisting
    ) throws -> AudiobookImportResult {
        log.info("book_import_started source=files selected_count=\(urls.count, privacy: .public)")
        let audio = urls.filter { LibraryScanner.audioExt.contains($0.pathExtension.lowercased()) }
        let ebooks = urls.filter { LibraryScanner.ebookExt.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty || !ebooks.isEmpty else { throw AudiobookImportError.noSupportedBookFiles }
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let plan = try importPlan(for: urls, in: root)
        if case .enrich(let existing) = plan {
            let added = try copyCompanionFiles(from: urls, to: existing)
            log.info("book_import_finished source=files outcome=enriched added_count=\(added.count, privacy: .public)")
            return .init(folder: existing, createdBook: false, addedFileNames: added)
        }
        if case .duplicate(let duplicate) = plan, duplicatePolicy == .keepExisting {
            log.info("book_import_finished source=files outcome=duplicate_kept confirmation=required")
            return .init(folder: duplicate.existingFolder, createdBook: false, addedFileNames: [])
        }
        let fingerprint = try audio.isEmpty ? nil : audioFingerprint(for: audio)
        let ebookDocument = ebooks.first.flatMap { EPUBParser.document(from: $0.path) }
        guard audio.isEmpty == false || ebookDocument != nil else { throw AudiobookImportError.invalidEbook }
        let title = ebookDocument?.title
            ?? audio.first?.deletingPathExtension().lastPathComponent
            ?? ebooks.first?.deletingPathExtension().lastPathComponent
            ?? "Imported Book"
        let folder = try newBookFolder(title: title, in: root)
        try writeMarkers(source: .files, title: title, author: ebookDocument?.author, to: folder)
        for url in urls where isSupportedImport(url) {
            try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
        try storeEmbeddedEbookCoverIfNeeded(in: folder)
        if let fingerprint { try writeMarker(fingerprint, named: fingerprintMarker, to: folder) }
        if audio.isEmpty { try writeMarker("1", named: ebookSectionsMarker, to: folder) }
        log.info("book_import_finished source=files outcome=created audio_count=\(audio.count, privacy: .public) ebook_count=\(ebooks.count, privacy: .public)")
        return .init(folder: folder, createdBook: true, addedFileNames: urls.map(\.lastPathComponent))
    }

    @discardableResult
    static func importFolder(
        _ url: URL,
        into root: URL = Persistence.importedBooksURL,
        duplicatePolicy: AudiobookDuplicateImportPolicy = .keepExisting
    ) throws -> [AudiobookImportResult] {
        log.info("book_import_started source=folder")
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let sources = importSourceFolders(in: url)
        guard sources.contains(where: { LibraryScanner.containsBookMedia(in: $0) }) else {
            throw AudiobookImportError.noSupportedBookFiles
        }
        let prepared = try sources.map { source -> (URL, [URL], ImportPlan) in
            let files = allFiles(in: source)
            let audio = files.filter { LibraryScanner.audioExt.contains($0.pathExtension.lowercased()) }
            if audio.isEmpty {
                let ebooks = files.filter { LibraryScanner.ebookExt.contains($0.pathExtension.lowercased()) }
                guard ebooks.contains(where: isReadableEbook) else {
                    throw AudiobookImportError.invalidEbook
                }
            }
            return (source, files, try importPlan(for: files, in: root))
        }
        let results: [AudiobookImportResult] = try prepared.map { source, files, plan in
            let audio = files.filter { LibraryScanner.audioExt.contains($0.pathExtension.lowercased()) }
            let fingerprint = try audio.isEmpty ? nil : audioFingerprint(for: audio)
            if case .enrich(let existing) = plan {
                let added = try copyCompanionFiles(from: files, to: existing)
                return .init(folder: existing, createdBook: false, addedFileNames: added)
            }
            if case .duplicate(let duplicate) = plan, duplicatePolicy == .keepExisting {
                return .init(folder: duplicate.existingFolder, createdBook: false, addedFileNames: [])
            }
            let destination = try newBookFolder(title: source.lastPathComponent, in: root)
            try copyDirectoryContents(from: source, to: destination)
            try storeEmbeddedEbookCoverIfNeeded(in: destination)
            try writeMarkers(source: .localFolder, title: source.lastPathComponent, author: nil, to: destination)
            if let fingerprint { try writeMarker(fingerprint, named: fingerprintMarker, to: destination) }
            if audio.isEmpty { try writeMarker("1", named: ebookSectionsMarker, to: destination) }
            return .init(folder: destination, createdBook: true, addedFileNames: files.map(\.lastPathComponent))
        }
        log.info("book_import_finished source=folder outcome=success book_count=\(results.count, privacy: .public)")
        return results
    }

    @discardableResult
    static func addCompanionFiles(_ urls: [URL], to folder: URL) throws -> [String] {
        log.info("book_attachment_started selected_count=\(urls.count, privacy: .public)")
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let added = try copyCompanionFiles(from: urls, to: folder)
        log.info("book_attachment_finished outcome=success added_count=\(added.count, privacy: .public)")
        return added
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
                .filter {
                    guard $0.pathExtension.lowercased() == "epub", $0 != temporary else {
                        return false
                    }
                    let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    // Regular files preserve legacy replacement behavior. An
                    // expanded package is installed only when it is readable;
                    // otherwise the directory remains a collision blocker.
                    return values?.isRegularFile == true
                        || (values?.isDirectory == true && isReadableEbook($0))
                }
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

    /// Device imports use the same exact-audio identity as Files imports. The
    /// staged file must live outside the library so this check stays read-only.
    static func preflightDeviceAudiobook(
        deviceID: UInt64,
        title: String,
        stagedAudio: URL?,
        in root: URL = Persistence.importedBooksURL
    ) throws -> AudiobookImportPreflight {
        if let existing = existingBookFolder(deviceID: deviceID, in: root) {
            return .init(
                duplicates: [.init(existingFolder: existing, title: title)],
                enrichesExistingBook: false
            )
        }
        guard let stagedAudio else {
            return .init(duplicates: [], enrichesExistingBook: false)
        }
        return try preflightFiles([stagedAudio], into: root)
    }

    /// File-backed device assets use this same staging implementation in tests
    /// and on iPad; non-file media exports into an equivalent temporary folder.
    static func stageDeviceAudiobookFile(
        _ source: URL,
        deviceID: UInt64,
        title: String,
        in root: URL = Persistence.importedBooksURL
    ) throws -> DeviceAudiobookImportPreflight {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-device-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
            let stagedAudio = folder.appendingPathComponent("audiobook.\(ext)")
            try FileManager.default.copyItem(at: source, to: stagedAudio)
            let identity = try preflightDeviceAudiobook(
                deviceID: deviceID,
                title: title,
                stagedAudio: stagedAudio,
                in: root
            )
            return .init(identity: identity, stagingFolder: folder, stagedAudio: stagedAudio)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Confirmation authorizes attaching device identity and metadata to the
    /// exact Files import; cancellation never calls this mutation boundary.
    @discardableResult
    static func confirmDeviceAudiobookMatch(
        _ preflight: AudiobookImportPreflight,
        deviceID: UInt64,
        title: String,
        author: String
    ) throws -> URL {
        guard let folder = preflight.duplicates.first?.existingFolder else {
            throw AudiobookImportError.duplicateConfirmationMissing
        }
        try writeMarkers(source: .deviceAudiobooks, title: title, author: author, to: folder)
        try writeDeviceID(deviceID, to: folder)
        log.info("book_import_finished message=book_import_finished component=device-book-import source=device-audiobooks outcome=confirmed_enrichment created_book=false")
        return folder
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

    private enum ImportPlan {
        case newBook
        case enrich(URL)
        case duplicate(AudiobookImportDuplicate)
    }

    /// Identity is content-derived: audio hashes exact bytes while EPUB hashes
    /// normalized publication metadata, section order, headings, and text.
    private static func importPlan(for urls: [URL], in root: URL) throws -> ImportPlan {
        let audio = urls.filter { LibraryScanner.audioExt.contains($0.pathExtension.lowercased()) }
        let ebooks = urls.filter { LibraryScanner.ebookExt.contains($0.pathExtension.lowercased()) }
        let covers = urls.filter { LibraryScanner.coverExt.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty || !ebooks.isEmpty else { throw AudiobookImportError.noSupportedBookFiles }
        let documents = ebooks.compactMap { EPUBParser.document(from: $0.path) }
        guard audio.isEmpty == false || documents.isEmpty == false else {
            throw AudiobookImportError.invalidEbook
        }

        var matches: [URL] = []
        if !audio.isEmpty {
            let fingerprint = try audioFingerprint(for: audio)
            if let folder = try existingBookFolder(
                matchingFingerprint: fingerprint,
                in: root,
                recordsDiscoveredFingerprint: false
            ) {
                matches.append(folder)
            }
        }
        for document in documents {
            let fingerprint = ebookFingerprint(for: document)
            if let folder = existingBookFolder(matchingEbookFingerprint: fingerprint, in: root),
               !matches.contains(where: { $0.standardizedFileURL == folder.standardizedFileURL }) {
                matches.append(folder)
            }
        }
        guard matches.count == 1, let existing = matches.first else {
            if let existing = matches.first {
                return .duplicate(.init(
                    existingFolder: existing,
                    title: documents.first?.title ?? importedTitle(in: existing)
                ))
            }
            return .newBook
        }

        let existingFiles = allFiles(in: existing)
        let addsMissingAudio = !audio.isEmpty
            && !existingFiles.contains { LibraryScanner.audioExt.contains($0.pathExtension.lowercased()) }
        let addsMissingEbook = !ebooks.isEmpty
            && !existingFiles.contains { LibraryScanner.ebookExt.contains($0.pathExtension.lowercased()) }
        let addsMissingCover = !covers.isEmpty
            && !existingFiles.contains { LibraryScanner.coverExt.contains($0.pathExtension.lowercased()) }
        if addsMissingAudio || addsMissingEbook || addsMissingCover {
            return .enrich(existing)
        }
        return .duplicate(.init(
            existingFolder: existing,
            title: documents.first?.title ?? importedTitle(in: existing)
        ))
    }

    private static func preflight(for plans: [ImportPlan]) -> AudiobookImportPreflight {
        AudiobookImportPreflight(
            duplicates: plans.compactMap { plan in
                guard case .duplicate(let duplicate) = plan else { return nil }
                return duplicate
            },
            enrichesExistingBook: plans.contains { plan in
                if case .enrich = plan { return true }
                return false
            }
        )
    }

    private static func importedTitle(in folder: URL) -> String {
        textMarker(named: ".audioreader-title", in: folder) ?? folder.lastPathComponent
    }

    private static func existingBookFolder(matchingEbookFingerprint fingerprint: String, in root: URL) -> URL? {
        existingBookFolders(in: root).first { folder in
            allFiles(in: folder)
                .filter { LibraryScanner.ebookExt.contains($0.pathExtension.lowercased()) }
                .compactMap { EPUBParser.document(from: $0.path) }
                .contains { ebookFingerprint(for: $0) == fingerprint }
        }
    }

    private static func ebookFingerprint(for document: EPUBDocument) -> String {
        let normalized = ([document.title ?? "", document.author ?? ""] + document.sections.flatMap {
            [$0.title, String($0.navigationLevel), $0.text]
        })
        .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func existingBookFolder(
        matchingFingerprint fingerprint: String,
        in root: URL,
        recordsDiscoveredFingerprint: Bool = true
    ) throws -> URL? {
        for folder in existingBookFolders(in: root) {
            if textMarker(named: fingerprintMarker, in: folder) == fingerprint { return folder }
            let audio = audioFiles(in: folder)
            guard !audio.isEmpty else { continue }
            let existing = try audioFingerprint(for: audio)
            if recordsDiscoveredFingerprint {
                try? writeMarker(existing, named: fingerprintMarker, to: folder)
            }
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

    struct AssetDigest: Equatable, Sendable {
        var contentHash: String
        var byteCount: Int64
        var regularFileCount: Int
        var isDirectory: Bool
    }

    /// Expanded EPUBs are hashed by stable relative path and regular-file bytes;
    /// Finder and AudioReader metadata never change publication identity.
    static func assetDigest(_ url: URL) throws -> AssetDigest {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isRegularFile == true {
            var hasher = SHA256()
            let byteCount = try hashFileContents(url, into: &hasher)
            return AssetDigest(
                contentHash: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                byteCount: byteCount,
                regularFileCount: 1,
                isDirectory: false
            )
        }
        guard values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else { throw CocoaError(.fileReadUnknown) }
        let root = url.standardizedFileURL.path.hasSuffix("/")
            ? url.standardizedFileURL.path
            : url.standardizedFileURL.path + "/"
        var files: [(relativePath: String, url: URL)] = []
        for case let candidate as URL in enumerator {
            guard try candidate.resourceValues(forKeys: Set(keys)).isRegularFile == true else { continue }
            let standardized = candidate.standardizedFileURL.path
            guard standardized.hasPrefix(root) else { continue }
            let relativePath = String(standardized.dropFirst(root.count))
            guard !isEphemeralAssetMetadata(relativePath) else { continue }
            files.append((relativePath, candidate))
        }
        files.sort { $0.relativePath < $1.relativePath }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        for file in files {
            let pathBytes = Data(file.relativePath.utf8)
            hasher.update(data: Data("path:\(pathBytes.count):".utf8))
            hasher.update(data: pathBytes)
            hasher.update(data: Data("\n".utf8))
            let size = try hashFileContents(file.url, into: &hasher)
            byteCount += size
            hasher.update(data: Data("\nsize:\(size)\n".utf8))
        }
        return AssetDigest(
            contentHash: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount: byteCount,
            regularFileCount: files.count,
            isDirectory: true
        )
    }

    private static func isEphemeralAssetMetadata(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { component in
            let name = String(component)
            return name == ".DS_Store"
                || name == "Thumbs.db"
                || name == "__MACOSX"
                || name.hasPrefix("._")
                || name.hasPrefix(".audioreader-")
        }
    }

    private static func hashFileContents(_ url: URL, into hasher: inout SHA256) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var byteCount: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
            byteCount += Int64(data.count)
        }
        return byteCount
    }

    /// Asset persistence reuses the same bounded file hash as duplicate import.
    static func fileDigest(_ url: URL) throws -> String {
        var hasher = SHA256()
        _ = try hashFileContents(url, into: &hasher)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func copyCompanionFiles(from urls: [URL], to folder: URL) throws -> [String] {
        var planned: [(source: URL, destination: URL)] = []
        var reservedDestinations: Set<String> = []
        for source in urls where isSupportedImport(source) {
            if LibraryScanner.ebookExt.contains(source.pathExtension.lowercased()),
               !isReadableEbook(source) {
                throw AudiobookImportError.invalidEbook
            }
            guard let destination = try uniqueDestination(
                for: source,
                in: folder,
                reservedDestinations: reservedDestinations
            ) else { continue }
            reservedDestinations.insert(destination.standardizedFileURL.path)
            planned.append((source, destination))
        }

        var copied: [URL] = []
        do {
            for item in planned {
                try FileManager.default.copyItem(at: item.source, to: item.destination)
                copied.append(item.destination)
            }
            let audio = audioFiles(in: folder)
            if !audio.isEmpty {
                try writeMarker(audioFingerprint(for: audio), named: fingerprintMarker, to: folder)
            }
            try storeEmbeddedEbookCoverIfNeeded(in: folder)
            return planned.map(\.destination.lastPathComponent)
        } catch {
            for destination in copied.reversed() {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }

    /// EPUB cover metadata is materialized once so library grids and the reader
    /// never have to unzip a publication while rendering SwiftUI views.
    private static func storeEmbeddedEbookCoverIfNeeded(in folder: URL) throws {
        let files = allFiles(in: folder)
        guard !files.contains(where: { LibraryScanner.coverExt.contains($0.pathExtension.lowercased()) }),
              let epub = files.first(where: { LibraryScanner.ebookExt.contains($0.pathExtension.lowercased()) }),
              let cover = EPUBParser.document(from: epub.path)?.cover
        else { return }
        let destination = folder.appendingPathComponent("cover.\(cover.fileExtension)")
        try cover.data.write(to: destination, options: .atomic)
        log.info("book_import_cover_materialized format=\(cover.fileExtension, privacy: .public)")
    }

    /// Collision checks keep expanded EPUB packages semantic and never pass a
    /// directory to the regular-file digest path.
    private static func uniqueDestination(
        for source: URL,
        in folder: URL,
        reservedDestinations: Set<String>
    ) throws -> URL? {
        let fm = FileManager.default
        let initial = folder.appendingPathComponent(source.lastPathComponent)
        if !fm.fileExists(atPath: initial.path),
           !reservedDestinations.contains(initial.standardizedFileURL.path) {
            return initial
        }
        if fm.fileExists(atPath: initial.path), try sameImportContent(source, initial) { return nil }
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var suffix = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path),
               !reservedDestinations.contains(candidate.standardizedFileURL.path) {
                return candidate
            }
            if fm.fileExists(atPath: candidate.path), try sameImportContent(source, candidate) { return nil }
            suffix += 1
        }
    }

    private static func sameImportContent(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let lhsExtension = lhs.pathExtension.lowercased()
        let rhsExtension = rhs.pathExtension.lowercased()
        if LibraryScanner.ebookExt.contains(lhsExtension),
           LibraryScanner.ebookExt.contains(rhsExtension) {
            guard let lhsDocument = EPUBParser.document(from: lhs.path),
                  let rhsDocument = EPUBParser.document(from: rhs.path)
            else { return false }
            return ebookFingerprint(for: lhsDocument) == ebookFingerprint(for: rhsDocument)
        }
        let lhsIsRegular = try lhs.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        let rhsIsRegular = try rhs.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        guard lhsIsRegular, rhsIsRegular else { return false }
        return try fileDigest(lhs) == fileDigest(rhs)
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

    /// A folder with direct media is one logical book; otherwise recurse into
    /// collection folders until book folders are found, without title guessing.
    private static func importSourceFolders(in folder: URL) -> [URL] {
        if containsDirectBookMedia(in: folder) { return [folder] }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .flatMap(importSourceFolders)
    }

    private static func containsDirectBookMedia(in folder: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.contains { url in
            let ext = url.pathExtension.lowercased()
            return LibraryScanner.audioExt.contains(ext) || LibraryScanner.ebookExt.contains(ext)
        }
    }

    private static func audioFiles(in folder: URL) -> [URL] {
        allFiles(in: folder).filter { LibraryScanner.audioExt.contains($0.pathExtension.lowercased()) }
    }

    private static func allFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true,
               LibraryScanner.ebookExt.contains(url.pathExtension.lowercased()) {
                // An expanded EPUB is one publication; package internals must
                // not be interpreted as independent import candidates.
                files.append(url)
                enumerator.skipDescendants()
            } else if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
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
