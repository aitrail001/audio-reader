#if os(iOS)
import AVFoundation
import Foundation
import MediaPlayer
import SwiftUI
import UIKit

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

@MainActor
@Observable
final class DeviceAudiobookLibrary {
    var items: [DeviceAudiobookItem] = []
    var isLoading = false
    var message: String?

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

    func importAudiobook(
        _ item: DeviceAudiobookItem,
        existing existingPolicy: ExistingBookImport = .skip
    ) async throws -> AudiobookImportResult {
        guard item.canImport, let assetURL = item.assetURL else {
            throw AudiobookImportError.protectedOrUnavailable
        }
        let chapters = await M4BChapterExtractor.extract(from: assetURL)
        if let existing = AudiobookImportService.existingBookFolder(deviceID: item.id) {
            if existingPolicy == .skip {
                try updateMetadata(for: item, chapters: chapters, in: existing)
                return .init(
                    folder: existing,
                    createdBook: false,
                    addedFileNames: [],
                    outcome: .alreadyImported,
                    title: item.title
                )
            }
        }

        let staging = Persistence.importedBooksURL
            .appendingPathComponent(".audioreader-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedAudio: URL
        if assetURL.isFileURL {
            let ext = assetURL.pathExtension.isEmpty ? "m4a" : assetURL.pathExtension
            stagedAudio = staging.appendingPathComponent("audiobook.\(ext)")
            try FileManager.default.copyItem(at: assetURL, to: stagedAudio)
        } else {
            stagedAudio = staging.appendingPathComponent("audiobook.m4a")
            let asset = AVURLAsset(url: assetURL)
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw AudiobookImportError.exportUnavailable
            }
            try await exporter.export(to: stagedAudio, as: .m4a)
        }

        if let existing = try AudiobookImportService.existingBookFolder(matchingAudioAt: stagedAudio) {
            if existingPolicy == .skip {
                try AudiobookImportService.writeDeviceID(item.id, to: existing)
                try updateMetadata(for: item, chapters: chapters, in: existing)
                return .init(
                    folder: existing,
                    createdBook: false,
                    addedFileNames: [],
                    outcome: .alreadyImported,
                    title: item.title
                )
            }
            let result = try AudiobookImportService.importFiles(
                [stagedAudio],
                into: Persistence.importedBooksURL,
                existing: .replace
            )
            try AudiobookImportService.writeDeviceID(item.id, to: result.folder)
            try updateMetadata(for: item, chapters: chapters, in: result.folder)
            return .init(
                folder: result.folder,
                createdBook: false,
                addedFileNames: result.addedFileNames,
                outcome: .replaced,
                title: item.title
            )
        }

        let folder = try AudiobookImportService.newBookFolder(title: item.title)
        try AudiobookImportService.writeMarkers(source: .deviceAudiobooks, title: item.title, author: item.author, to: folder)
        try AudiobookImportService.writeDeviceID(item.id, to: folder)
        let destination = folder.appendingPathComponent(stagedAudio.lastPathComponent)
        try FileManager.default.moveItem(at: stagedAudio, to: destination)
        try AudiobookImportService.recordAudioFingerprint(for: destination, in: folder)
        try updateMetadata(for: item, chapters: chapters, in: folder)
        return .init(
            folder: folder,
            createdBook: true,
            addedFileNames: [destination.lastPathComponent],
            outcome: .created,
            title: item.title
        )
    }

    private func updateMetadata(
        for item: DeviceAudiobookItem,
        chapters: [EmbeddedM4BChapter],
        in folder: URL
    ) throws {
        try AudiobookImportService.writeMarkers(
            source: .deviceAudiobooks,
            title: item.title,
            author: item.author,
            to: folder
        )
        try M4BChapterExtractor.save(chapters, in: folder)
        if let artworkData = item.artworkData {
            try artworkData.write(to: folder.appendingPathComponent("cover.png"), options: .atomic)
        }
    }
}

#endif
