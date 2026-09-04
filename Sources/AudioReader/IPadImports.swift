#if os(iOS)
import AVFoundation
import Foundation
import MediaPlayer
import OSLog
import SwiftUI
import UIKit

private let deviceImportLog = Logger(
    subsystem: "com.johnsonzhang.AudioReader",
    category: "device-book-import"
)

struct DeviceAudiobookItem: Identifiable, Sendable {
    var id: UInt64
    var title: String
    var author: String
    var duration: TimeInterval
    var assetURL: URL?
    var artworkData: Data?
    var isProtected: Bool

    var canImport: Bool { !isProtected && assetURL != nil }
}

struct DeviceAudiobookCompanionStage {
    var audio: URL
    var cleanupFolder: URL?
}

/// Tests replace only device export and chapter extraction; attachment and
/// cleanup still run through the production `addCompanion` mutation boundary.
@MainActor
struct DeviceAudiobookCompanionLoader {
    var stage: (URL) async throws -> DeviceAudiobookCompanionStage
    var chapters: (URL) async -> [EmbeddedM4BChapter]

    static let live = Self(
        stage: { assetURL in
            if assetURL.isFileURL {
                return .init(audio: assetURL, cleanupFolder: nil)
            }
            let exported = try await DeviceAudiobookLibrary.exportAudio(from: assetURL)
            return .init(audio: exported.audio, cleanupFolder: exported.folder)
        },
        chapters: { await M4BChapterExtractor.extract(from: $0) }
    )
}

@MainActor
@Observable
final class DeviceAudiobookLibrary {
    var items: [DeviceAudiobookItem] = []
    var isLoading = false
    var message: String?
    private let companionLoader: DeviceAudiobookCompanionLoader

    init(companionLoader: DeviceAudiobookCompanionLoader = .live) {
        self.companionLoader = companionLoader
    }

    var authorizationStatus: MPMediaLibraryAuthorizationStatus {
        MPMediaLibrary.authorizationStatus()
    }

    func requestAccessAndReload() async {
        let status: MPMediaLibraryAuthorizationStatus
        if authorizationStatus == .notDetermined {
            status = await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else {
            status = authorizationStatus
        }
        guard status == .authorized else {
            items = []
            message = "Media access is required to find audiobooks on this iPad."
            return
        }
        await reload()
    }

    func reload() async {
        guard authorizationStatus == .authorized else {
            await requestAccessAndReload()
            return
        }
        isLoading = true
        defer { isLoading = false }
        let queried = MPMediaQuery.audiobooks().items ?? []
        items = queried.map { item in
            let artwork = item.artwork?.image(at: CGSize(width: 360, height: 540))?.pngData()
            return DeviceAudiobookItem(
                id: item.persistentID,
                title: item.title ?? item.albumTitle ?? "Untitled audiobook",
                author: item.albumArtist ?? item.artist ?? "Unknown author",
                duration: item.playbackDuration,
                assetURL: item.assetURL,
                artworkData: artwork,
                isProtected: item.hasProtectedAsset
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let available = items.filter(\.canImport).count
        let protected = items.count - available
        message = protected > 0
            ? "Found \(available) importable and \(protected) protected audiobooks."
            : "Found \(available) audiobooks on this iPad."
    }

    /// Exports outside the library before exact-content inspection so neither a
    /// duplicate prompt nor its cancellation can change imported book state.
    func preflightAudiobook(_ item: DeviceAudiobookItem) async throws -> DeviceAudiobookImportPreflight {
        guard item.canImport, let assetURL = item.assetURL else {
            throw AudiobookImportError.protectedOrUnavailable
        }
        let markerPreflight = try AudiobookImportService.preflightDeviceAudiobook(
            deviceID: item.id,
            title: item.title,
            stagedAudio: nil
        )
        if markerPreflight.requiresConfirmation {
            deviceImportLog.info("book_import_preflight_finished message=book_import_preflight_finished component=device-book-import source=device-audiobooks outcome=success duplicate_count=1")
            return .init(identity: markerPreflight, stagingFolder: nil, stagedAudio: nil)
        }
        if assetURL.isFileURL {
            let prepared = try AudiobookImportService.stageDeviceAudiobookFile(
                assetURL,
                deviceID: item.id,
                title: item.title
            )
            deviceImportLog.info("book_import_preflight_finished message=book_import_preflight_finished component=device-book-import source=device-audiobooks outcome=success duplicate_count=\(prepared.identity.duplicates.count, privacy: .public) identity=exact-content")
            return prepared
        }
        let staged = try await Self.exportAudio(from: assetURL)
        do {
            let identity = try AudiobookImportService.preflightDeviceAudiobook(
                deviceID: item.id,
                title: item.title,
                stagedAudio: staged.audio
            )
            deviceImportLog.info("book_import_preflight_finished message=book_import_preflight_finished component=device-book-import source=device-audiobooks outcome=success duplicate_count=\(identity.duplicates.count, privacy: .public) identity=exact-content")
            return .init(identity: identity, stagingFolder: staged.folder, stagedAudio: staged.audio)
        } catch {
            try? FileManager.default.removeItem(at: staged.folder)
            throw error
        }
    }

    func importAudiobook(
        _ item: DeviceAudiobookItem,
        prepared: DeviceAudiobookImportPreflight? = nil,
        duplicatePolicy: AudiobookDuplicateImportPolicy = .keepExisting
    ) async throws -> AudiobookImportResult {
        guard item.canImport, let assetURL = item.assetURL else {
            throw AudiobookImportError.protectedOrUnavailable
        }
        let preflight: DeviceAudiobookImportPreflight
        if let prepared {
            preflight = prepared
        } else {
            preflight = try await preflightAudiobook(item)
        }
        defer { preflight.discard() }
        if let duplicate = preflight.identity.duplicates.first {
            if case .keepExisting = duplicatePolicy {
                return .init(folder: duplicate.existingFolder, createdBook: false, addedFileNames: [])
            }
            let chapters = await M4BChapterExtractor.extract(from: assetURL)
            let existing = try AudiobookImportService.confirmDeviceAudiobookMatch(
                preflight.identity,
                deviceID: item.id,
                title: item.title,
                author: item.author
            )
            try updateMetadata(for: item, chapters: chapters, in: existing)
            return .init(folder: existing, createdBook: false, addedFileNames: [])
        }
        deviceImportLog.info("book_import_started message=book_import_started component=device-book-import source=device-audiobooks confirmation=confirmed_or_not_required")
        let chapters = await M4BChapterExtractor.extract(from: assetURL)
        guard let stagedAudio = preflight.stagedAudio else { throw AudiobookImportError.exportUnavailable }

        let folder = try AudiobookImportService.newBookFolder(title: item.title)
        try AudiobookImportService.writeMarkers(source: .deviceAudiobooks, title: item.title, author: item.author, to: folder)
        try AudiobookImportService.writeDeviceID(item.id, to: folder)
        let destination = folder.appendingPathComponent(stagedAudio.lastPathComponent)
        try FileManager.default.moveItem(at: stagedAudio, to: destination)
        try AudiobookImportService.recordAudioFingerprint(for: destination, in: folder)
        try updateMetadata(for: item, chapters: chapters, in: folder)
        deviceImportLog.info("book_import_finished message=book_import_finished component=device-book-import source=device-audiobooks outcome=success created_book=true")
        return .init(folder: folder, createdBook: true, addedFileNames: [destination.lastPathComponent])
    }

    /// The selected book identity remains the owner when device audio is attached;
    /// metadata-only sync rows are first materialized in the managed library.
    func addCompanion(
        _ item: DeviceAudiobookItem,
        to book: Book,
        in libraryRoot: URL = Persistence.importedBooksURL
    ) async throws -> [String] {
        guard item.canImport, let assetURL = item.assetURL else {
            throw AudiobookImportError.protectedOrUnavailable
        }
        let requestID = UUID().uuidString
        deviceImportLog.info(
            "device_companion_started message=device_companion_started requestId=\(requestID, privacy: .public) component=device-book-import source=device-audiobooks"
        )
        do {
            let staged = try await companionLoader.stage(assetURL)
            defer {
                if let cleanupFolder = staged.cleanupFolder {
                    try? FileManager.default.removeItem(at: cleanupFolder)
                }
            }
            let chapters = await companionLoader.chapters(assetURL)
            let result = try AudiobookImportService.addCompanionFiles(
                [staged.audio],
                to: book,
                in: libraryRoot
            )
            if !result.addedFileNames.isEmpty, !chapters.isEmpty {
                try M4BChapterExtractor.save(chapters, in: result.folder)
            }
            deviceImportLog.info(
                "device_companion_finished message=device_companion_finished requestId=\(requestID, privacy: .public) component=device-book-import source=device-audiobooks outcome=success added_count=\(result.addedFileNames.count, privacy: .public)"
            )
            return result.addedFileNames
        } catch {
            deviceImportLog.error(
                "device_companion_finished message=device_companion_finished requestId=\(requestID, privacy: .public) component=device-book-import source=device-audiobooks outcome=failure error_type=\(String(reflecting: type(of: error)), privacy: .public)"
            )
            throw error
        }
    }

    fileprivate static func exportAudio(from assetURL: URL) async throws -> (folder: URL, audio: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-device-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let stagedAudio = folder.appendingPathComponent("audiobook.m4a")
            let asset = AVURLAsset(url: assetURL)
            guard let exporter = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                throw AudiobookImportError.exportUnavailable
            }
            try await exporter.export(to: stagedAudio, as: .m4a)
            return (folder, stagedAudio)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func updateMetadata(
        for item: DeviceAudiobookItem,
        chapters: [EmbeddedM4BChapter],
        in folder: URL
    ) throws {
        try M4BChapterExtractor.save(chapters, in: folder)
        if let artworkData = item.artworkData {
            try artworkData.write(to: folder.appendingPathComponent("cover.png"), options: .atomic)
        }
    }
}

#endif
