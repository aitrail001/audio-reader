import Foundation
import AVFoundation
import CoreMedia

@MainActor
@Observable
final class PlayerEngine {
    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying: Bool = false
    var rate: Float = 1.0 {
        didSet {
            if isPlaying { player?.rate = rate }
        }
    }
    var loop: PlaybackLoop = .off
    var loadedPath: String?

    func load(path: String) {
        if loadedPath == path, player != nil { return }
        tearDown()
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        self.player = p
        self.loadedPath = path
        self.currentTime = 0
        self.duration = 0
        Task { @MainActor in
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite {
                self.duration = d.seconds
            }
        }

        observer = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.08, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                if abs(self.currentTime - seconds) < 0.05 { return }
                self.currentTime = seconds
                self.applyLoopIfNeeded()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }
    }

    func play() {
        guard let player else { return }
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func seek(_ time: TimeInterval) {
        let t = max(0, min(time, duration > 0 ? duration : time))
        player?.seek(
            to: CMTime(seconds: t, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = t
    }

    func skip(seconds: TimeInterval) {
        seek(currentTime + seconds)
    }

    func tearDown() {
        if let observer, let player {
            player.removeTimeObserver(observer)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player?.pause()
        player = nil
        observer = nil
        endObserver = nil
        isPlaying = false
        loadedPath = nil
    }

    private func applyLoopIfNeeded() {
        switch loop {
        case .off:
            return
        case .sentence:
            return // handled by AppState which knows sentence bounds
        case .ab(let start, let end):
            if currentTime >= end - 0.03 {
                seek(start)
                if isPlaying { play() }
            }
        }
    }
}
