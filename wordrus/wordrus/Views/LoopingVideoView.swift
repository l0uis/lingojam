import SwiftUI
import AVFoundation
import UIKit

/// Silent, endlessly looping video loaded from an asset-catalog data set.
///
/// The clips are drawn on white, so the player layer multiplies onto whatever
/// sits behind it — white drops out and the paper background shows through,
/// the same way a transparent PNG would.
struct LoopingVideoView: UIViewRepresentable {
    /// Name of the `.dataset` in Assets.xcassets holding the movie.
    let dataAssetName: String
    /// Seconds to hold on the last frame before starting again; 0 loops
    /// seamlessly.
    var pauseBetweenLoops: TimeInterval = 0

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.load(dataAssetName: dataAssetName, pauseBetweenLoops: pauseBetweenLoops)
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: ()) {
        uiView.stop()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private var looper: AVPlayerLooper?
        private var endObserver: NSObjectProtocol?
        private var readyObservation: NSKeyValueObservation?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            playerLayer.videoGravity = .resizeAspect
            playerLayer.compositingFilter = "multiplyBlendMode"
            // Hidden until the first frame decodes, then faded in, so the
            // clip doesn't pop in a beat after the screen appears.
            playerLayer.opacity = 0
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.duration = 0.25
                    layer.opacity = 1
                    layer.add(fade, forKey: "fadeIn")
                }
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func load(dataAssetName: String, pauseBetweenLoops: TimeInterval) {
            guard let url = Self.fileURL(forDataAsset: dataAssetName) else { return }
            let player = AVQueuePlayer()
            // Decorative clip: no sound, and don't keep the screen awake.
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            if pauseBetweenLoops > 0 {
                // Play once, hold the last frame, then rewind and go again.
                let item = AVPlayerItem(url: url)
                player.insert(item, after: nil)
                player.actionAtItemEnd = .pause
                endObserver = NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.didPlayToEndTimeNotification,
                    object: item,
                    queue: .main
                ) { [weak self, weak player] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + pauseBetweenLoops) {
                        guard let self, let player, self.playerLayer.player === player else { return }
                        player.seek(to: .zero) { _ in player.play() }
                    }
                }
            } else {
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            }
            playerLayer.player = player
            player.play()
        }

        func stop() {
            readyObservation = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            playerLayer.player?.pause()
            looper?.disableLooping()
            looper = nil
            playerLayer.player = nil
        }

        /// AVPlayer can't read straight from an `NSDataAsset`, so the movie is
        /// written to a temp file first. Rewritten every time so a replaced
        /// asset never plays a stale copy.
        private static func fileURL(forDataAsset name: String) -> URL? {
            guard let asset = NSDataAsset(name: name) else { return nil }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name).mov")
            do {
                try asset.data.write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }
    }
}
