import SwiftUI

/// The App's side of a skin scene: data feeds from its services, the backdrop readability
/// map, and library artwork. `SkinSceneHost` installs it; the engine sees only the protocol.
struct SkinSceneAppHost: SkinSceneHostAdapter {
    func feeds(_ request: SkinSceneFeedRequest) -> AnyView {
        AnyView(SkinSceneFeeds(data: request.data, program: request.program, snapshot: request.snapshot,
                               viewport: request.viewport, parameters: request.parameters))
    }

    func backdrop(_ scene: AnyView, snapshot: SkinSceneSnapshot, size: CGSize, enabled: Bool) -> AnyView {
        AnyView(SkinSceneBackdropRoot(content: scene, snapshot: snapshot, size: size, enabled: enabled))
    }

    func adaptive(_ node: AnyView, reading: Binding<SkinBackdropReading?>) -> AnyView {
        AnyView(node.modifier(SkinAdaptiveBackdropProbe(reading: reading)))
    }

    func trackArtwork(id: UUID, fills: Bool) -> AnyView {
        AnyView(SkinQueueTrackArtwork(trackID: id, fills: fills))
    }
}

/// A lease on the shared analysis Hub and LED provider. A scene holds at most one, only while
/// a visible node reads audio and local playback is running.
@MainActor
final class SkinSceneAudioLease {
    private var consumerID: UUID?
    private var ledConsumerID: UUID?
    private var provider: LEDMeterServiceProvider?
    private var generation: UInt64 = 0

    func update(_ audio: SkinSceneAudio, provider: LEDMeterServiceProvider, source: PlaybackSource,
                active: Bool, isPlaying: Bool, usesLED: Bool) {
        let next: SkinSceneAudio.Availability = !active ? .inactive : (source != .local ? .externalAudioUnavailable : (isPlaying ? .localAudio : .inactive))
        let keepsPausedFrame = active && source == .local && !isPlaying
        guard next != audio.availability || (next == .localAudio && usesLED != (ledConsumerID != nil)) else { return }
        release(audio, clear: !keepsPausedFrame)
        audio.availability = next
        guard next == .localAudio else { return }
        self.provider = provider
        provider.acquireSession()
        let expected = generation
        consumerID = AudioAnalysisHub.shared.addConsumer { [weak self, weak audio] frame in
            Task { @MainActor [weak self, weak audio] in
                guard let self, let audio, self.generation == expected, audio.availability == .localAudio else { return }
                audio.receive(magnitudes: frame.magnitudes, pcm: frame.pcmSamples, sampleRate: Double(frame.sampleRate), fftSize: frame.fftSize,
                              rms: Double(frame.rms), peak: Double(frame.peak), fastRMS: Double(frame.fastRMS), fastPeak: Double(frame.fastPeak))
            }
        }
        if usesLED {
            ledConsumerID = provider.addFrameConsumer { [weak self, weak audio] metrics, _ in
                guard let self, let audio, self.generation == expected else { return }
                audio.receiveMeter(level: Double(metrics.level), leds: metrics.leds.map(Double.init))
            }
        }
    }

    func stop(_ audio: SkinSceneAudio) {
        release(audio, clear: true)
        audio.availability = .inactive
    }

    private func release(_ audio: SkinSceneAudio, clear: Bool) {
        generation &+= 1
        if let consumerID { AudioAnalysisHub.shared.removeConsumer(consumerID) }
        if let ledConsumerID { provider?.removeFrameConsumer(ledConsumerID) }
        consumerID = nil
        ledConsumerID = nil
        provider?.releaseSession()
        provider = nil
        if clear { audio.clear() }
    }
}
