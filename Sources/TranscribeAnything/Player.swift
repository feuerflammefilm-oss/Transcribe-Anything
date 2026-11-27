import AVFoundation
import Foundation

@MainActor
final class Player: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var rate: Float = 1.0

    private var player: AVPlayer?
    private var observer: Any?
    private(set) var url: URL?

    func load(_ url: URL, duration: Double) {
        guard url != self.url else { return }
        stop()
        self.url = url
        self.duration = duration
        let p = AVPlayer(url: url)
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                self.isPlaying = (self.player?.rate ?? 0) > 0
            }
        }
        player = p
        currentTime = 0
    }

    func stop() {
        if let observer, let player { player.removeTimeObserver(observer) }
        player?.pause()
        player = nil
        observer = nil
        isPlaying = false
        url = nil
    }

    func toggle() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
            isPlaying = false
        } else {
            player.playImmediately(atRate: rate)
            isPlaying = true
        }
    }

    func seek(_ t: Double, play: Bool = false) {
        guard let player else { return }
        let target = max(0, min(t, duration))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        if play && player.rate == 0 { toggle() }
    }

    func skip(_ delta: Double) { seek(currentTime + delta) }

    func setRate(_ r: Float) {
        rate = r
        if let player, player.rate > 0 { player.rate = r }
    }
}
