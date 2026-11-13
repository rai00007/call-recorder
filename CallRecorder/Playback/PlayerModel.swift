import Foundation
import AVFoundation

@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var rate: Float = 1
    private let player: AVPlayer
    private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = t.seconds
                if self.isPlaying, self.duration > 0, t.seconds >= self.duration - 0.05 { self.isPlaying = false }
            }
        }
        Task { duration = (try? await player.currentItem?.asset.load(.duration).seconds) ?? 0 }
    }
    deinit { if let o = observer { player.removeTimeObserver(o) } }

    func play() { player.defaultRate = rate; player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }
    func seek(to t: TimeInterval) {
        let clamped = min(max(0, t), duration > 0 ? duration : t)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func setRate(_ r: Float) {
        rate = r; player.defaultRate = r
        if isPlaying { player.rate = r }
    }
}
