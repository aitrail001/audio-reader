import Foundation
import AVFoundation
import CoreMedia

enum PlaybackSpeedCatalog {
    static let values: [Double] = (0...30).map { step in
        (0.5 + Double(step) * 0.05).rounded(toPlaces: 2)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let power = pow(10, Double(places))
        return (self * power).rounded() / power
    }
}

@MainActor
@Observable
final class PlayerEngine {
    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    /// App-owned playback modes subscribe here so they keep working off the reader screen.
    var onTick: (@MainActor (TimeInterval) -> Void)?

    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying: Bool = false
    var playbackError: String?
    var rate: Float = 1.0 {
        didSet {
            if isPlaying { player?.rate = rate }
        }
    }
    var loop: PlaybackLoop = .off
    var loadedPath: String?
    var clipEnd: TimeInterval?
    private var mediaStart: TimeInterval = 0
    private var chapterDuration: TimeInterval?

    func load(path: String, startTime: TimeInterval = 0, duration: TimeInterval? = nil) {
        if loadedPath == path, player != nil, abs(mediaStart - startTime) < 0.001 {
            chapterDuration = duration
            seek(0)
            return
        }
        tearDown()
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        self.player = p
        self.loadedPath = path
        self.mediaStart = max(0, startTime)
        self.chapterDuration = duration
        self.currentTime = 0
        self.duration = duration ?? 0
        if mediaStart > 0 {
            p.seek(to: CMTime(seconds: mediaStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite {
                self.duration = duration ?? max(0, d.seconds - self.mediaStart)
            }
        }

        observer = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.08, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.handleTick(time)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
            }
        }
    }

    func playClip(from start: TimeInterval, to end: TimeInterval) {
        let startTime = max(0, start)
        seek(startTime)
        clipEnd = max(end, startTime + 0.25)
        play()
    }

    func play() {
        guard let player else { return }
#if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            playbackError = nil
        } catch {
            playbackError = "Audio output could not be activated: \(error.localizedDescription)"
            return
        }
#endif
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        clipEnd = nil
        player?.pause()
        isPlaying = false
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func seek(_ time: TimeInterval) {
        clipEnd = nil
        let t = max(0, min(time, duration > 0 ? duration : time))
        player?.seek(
            to: CMTime(seconds: mediaStart + t, preferredTimescale: 600),
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
        clipEnd = nil
        mediaStart = 0
        chapterDuration = nil
        playbackError = nil
    }

    private func handleTick(_ time: CMTime) {
        let seconds = max(0, time.seconds - mediaStart)
        if let limit = chapterDuration, seconds >= limit - 0.02 {
            currentTime = limit
            onTick?(currentTime)
            pause()
            return
        }
        if let clipEnd, seconds >= clipEnd - 0.02 {
            currentTime = clipEnd
            onTick?(currentTime)
            pause()
            return
        }
        if abs(currentTime - seconds) < 0.05 { return }
        currentTime = seconds
        applyLoopIfNeeded()
        onTick?(currentTime)
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
