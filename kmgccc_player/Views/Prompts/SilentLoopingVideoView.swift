//
//  SilentLoopingVideoView.swift
//  kmgccc_player
//
//  A muted, looping preview clip for prompt cards.
//

import AVFoundation
import AppKit
import SwiftUI

/// Loops a short bundled clip with no sound and no media session.
///
/// The player is muted, takes no part in Now Playing or AirPlay, and never
/// keeps the display awake. With Reduce Motion on, the poster stands in for
/// the clip. The player is torn down as soon as the view leaves the hierarchy.
struct SilentLoopingVideoView: NSViewRepresentable {
    let videoURL: URL
    let posterURL: URL?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> SilentLoopingVideoNSView {
        let view = SilentLoopingVideoNSView()
        view.configure(videoURL: videoURL, posterURL: posterURL, playsVideo: !reduceMotion)
        return view
    }

    func updateNSView(_ view: SilentLoopingVideoNSView, context: Context) {
        view.configure(videoURL: videoURL, posterURL: posterURL, playsVideo: !reduceMotion)
    }

    static func dismantleNSView(_ view: SilentLoopingVideoNSView, coordinator: ()) {
        view.tearDown()
    }
}

@MainActor
final class SilentLoopingVideoNSView: NSView {
    private let posterLayer = CALayer()
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var readyObservation: NSKeyValueObservation?
    private var configuredVideoURL: URL?
    private var configuredPosterURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        posterLayer.contentsGravity = .resizeAspectFill
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.opacity = 0
        layer?.addSublayer(posterLayer)
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        posterLayer.frame = bounds
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        posterLayer.contentsScale = scale
        playerLayer.contentsScale = scale
    }

    func configure(videoURL: URL, posterURL: URL?, playsVideo: Bool) {
        if posterURL != configuredPosterURL {
            configuredPosterURL = posterURL
            posterLayer.contents = posterURL.flatMap { NSImage(contentsOf: $0) }
        }
        if playsVideo {
            if videoURL != configuredVideoURL || player == nil {
                startPlayback(videoURL)
            }
        } else {
            stopPlayback()
        }
    }

    func tearDown() {
        stopPlayback()
        posterLayer.contents = nil
        configuredPosterURL = nil
    }

    private func startPlayback(_ url: URL) {
        stopPlayback()
        configuredVideoURL = url

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: player, templateItem: item)
        self.player = player

        playerLayer.player = player
        // Reveal the clip only once its first frame is ready, so the poster
        // never flashes to black.
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor [weak self] in
                self?.playerLayer.opacity = 1
            }
        }
        player.play()
    }

    private func stopPlayback() {
        readyObservation?.invalidate()
        readyObservation = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        playerLayer.player = nil
        playerLayer.opacity = 0
        configuredVideoURL = nil
    }
}
