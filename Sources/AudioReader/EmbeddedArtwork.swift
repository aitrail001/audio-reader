import AVFoundation
import Foundation

enum EmbeddedArtwork {
    static func extract(from audioURL: URL) async -> Data? {
        let asset = AVURLAsset(url: audioURL)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        let artwork = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .commonIdentifierArtwork
        )
        for item in artwork {
            if let data = try? await item.load(.dataValue), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    static func store(_ data: Data, in folder: URL) throws -> URL {
        let ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
        let destination = folder.appendingPathComponent("cover.\(ext)")
        try data.write(to: destination, options: .atomic)
        return destination
    }
}
