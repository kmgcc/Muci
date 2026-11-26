import SwiftUI
import MotionKit

/// The App's factories for the component names `SkinComponentContract` advertises.
extension SkinComponentContract {
    static func register(in catalog: SkinComponentCatalog) {
        for name in SkinBuiltinSceneTemplates.names {
            catalog.register("template." + name) { snapshot, _ in SkinBuiltinTemplatePart(name: name, snapshot: snapshot) }
        }
        for (id, target) in aliases {
            catalog.register(id) { [weak catalog] snapshot, configuration in
                catalog?.makeComponent(target, snapshot: snapshot, configuration: configuration)
            }
        }
        catalog.register("artwork.classicFrame", isInteractive: true) { snapshot, config in SkinClassicCoverPart(snapshot: snapshot, configuration: config, appleStyle: false) }
        catalog.register("visualizer.pillSpectrum") { snapshot, config in SkinPillSpectrumPart(snapshot: snapshot, configuration: config) }
        catalog.register("control.playPause", isInteractive: true) { _, config in SkinAnimatedButtonPart(configuration: config, skip: false) }
        catalog.register("control.skip", isInteractive: true) { _, config in SkinAnimatedButtonPart(configuration: config, skip: true) }
        catalog.register("control.previous", isInteractive: true) { _, config in SkinAnimatedButtonPart(configuration: config, skip: true, previous: true) }
        catalog.register("control.next", isInteractive: true) { _, config in SkinAnimatedButtonPart(configuration: config, skip: true, previous: false) }
        catalog.register("control.expandableVolume", isInteractive: true) { _, config in SkinExpandableVolumePart(configuration: config) }
        catalog.register("control.actionButton", isInteractive: true) { _, config in SkinActionButton(kind: SkinActionButton.Kind(rawValue: config.text("kind", fallback: "playPause")) ?? .playPause, configuration: config) }
        catalog.register("control.glassButton", isInteractive: true) { _, config in SkinGlassButtonPart(configuration: config) }
        catalog.register("control.glassTriplePill", isInteractive: true) { _, config in SkinGlassTriplePart(configuration: config) }
        catalog.register("transition.bokeh") { snapshot, config in SkinBokehPart(snapshot: snapshot, configuration: config) }
        catalog.register("lyrics.panel") { _, config in SkinLyricsPanelPart(configuration: config) }
        catalog.register("visualizer.progressSpectrum", isInteractive: true) { snapshot, config in SkinProgressSpectrumPart(snapshot: snapshot, configuration: config) }
        for behavior in ["autoHide", "lyricsEndAutoHide", "scrollVolume", "pointerOcclusion", "windowDrag"] {
            catalog.registerContainer("behavior." + behavior) { _, config, children in SkinBehaviorComponent(kind: behavior, configuration: config, content: children) }
        }
        catalog.registerContainer("menu.trackContext") { _, config, children in SkinTrackMenuComponent(content: children, configuration: config) }
        catalog.registerContainer("menu.player") { _, config, children in
            SkinTrackMenuComponent(content: children, configuration: config, defaultSections: SkinTrackMenuComponent.allSections)
        }
        catalog.register("control.dislike", isInteractive: true) { _, config in SkinLikeComponent(configuration: config, dislike: true) }
        catalog.register("control.outputDevice", isInteractive: true) { _, config in SkinOutputDeviceComponent(configuration: config) }
        catalog.register("control.progressLine", isInteractive: true) { _, config in SkinProgressLinePart(configuration: config) }
        catalog.register("control.actionStack", isInteractive: true) { _, config in SkinActionStackPart(configuration: config) }
        catalog.register("control.playbackModeStack", isInteractive: true) { _, config in SkinPlaybackModeStackPart(configuration: config) }
        catalog.register("artwork.appleStyle") { snapshot, config in SkinClassicCoverPart(snapshot: snapshot, configuration: config, appleStyle: true) }
        catalog.register("artwork.rotatingDisc") { snapshot, config in SkinRotatingDiscPart(snapshot: snapshot, configuration: config) }
        catalog.register("artwork.coverGradientBlur") { snapshot, _ in SkinCoverGradientBlurArtworkPart(snapshot: snapshot) }
        for part in ["shell", "label", "reels", "waveform", "overlay", "kmgLook"] {
            catalog.register("cassette." + part) { snapshot, config in SkinCassettePart(snapshot: snapshot, part: part, configuration: config) }
        }
        catalog.register("background.host") { snapshot, config in SkinHostBackgroundPart(snapshot: snapshot, configuration: config) }
        catalog.register("background.unifiedMesh") { snapshot, _ in UnifiedNowPlayingBackground(context: snapshot.context) }
        catalog.register("background.amllMesh") { snapshot, config in SkinAppleMeshPart(snapshot: snapshot, configuration: config) }
        catalog.register("background.coverGradientBlur") { snapshot, config in SkinCoverBlurPart(snapshot: snapshot, configuration: config) }
        catalog.register("background.art") { snapshot, _ in SkinArtBackgroundPart(snapshot: snapshot) }
        catalog.register("background.artworkBlur") { snapshot, config in
            SkinBackgroundComponent(snapshot: snapshot, configuration: .init(values: config.values.merging(["mode": .text("artwork")]) { _, new in new }))
        }
        catalog.register("background.dimming") { _, config in SkinDimmingPart(intensity: config.number("intensity", fallback: 0.2)) }
        catalog.register("text.marquee") { snapshot, config in
            SeamlessMarqueeText(text: config.text("text", fallback: snapshot.track?.title ?? ""), style: .custom(fontSize: config.number("fontSize", fallback: 24)), fontWeight: .regular, color: config.color(fallback: snapshot.theme.accentColor), speed: config.number("speed", fallback: 24))
        }
        catalog.register("text.trackDescription", isInteractive: true) { _, config in SkinTrackDescriptionComponent(configuration: config) }
        catalog.register("panel.queue", isInteractive: true) { _, _ in SkinSceneQueuePanel() }
        for (id, action) in [("panel.quickAppearance", "quickPanel"), ("panel.trackDetail", "detail"), ("sheet.trackEdit", "edit"), ("sheet.externalInfo", "external"), ("sheet.settings", "settings")] {
            catalog.register(id, isInteractive: true) { _, config in SkinPanelLauncher(action: action, configuration: config) }
        }
    }
}

/// The host's art background, configured per surface the way the window and fullscreen hosts do.
struct SkinArtBackgroundPart: View {
    let snapshot: SkinSceneSnapshot
    var surface: SkinSurface?
    var resourceProfile: SkinPresentationPolicy.ArtBackgroundResourceProfile = .standard
    var isArtworkLoading = false
    @StateObject private var controller = BKArtBackgroundController()
    @Environment(\.skinSceneIsActive) private var active
    @Environment(\.skinSceneSurface) private var sceneSurface
    var body: some View {
        let fullscreen = (surface ?? sceneSurface) == .fullscreen
        BKArtBackgroundView(controller: controller, trackID: snapshot.track?.id, artworkData: snapshot.track?.artworkData,
                            isPlaying: active && snapshot.playback.isPlaying, artworkFileURL: snapshot.track?.artworkFileURL,
                            animationEnabled: active && snapshot.context.motionPolicy == .full,
                            resourceProfile: .init(skinProfile: resourceProfile),
                            dotRenderStyle: fullscreen ? .solidCircles : .dotGrid,
                            motionProfile: fullscreen ? .fullscreenBalanced : .window,
                            initialPalette: snapshot.theme.artworkPalette.isEmpty ? nil : snapshot.theme.artworkPalette,
                            isArtworkLoading: isArtworkLoading)
            .allowsHitTesting(false)
    }
}

/// A black veil; adaptive nodes account for it when they read the backdrop.
private struct SkinDimmingPart: View {
    let intensity: Double
    @Environment(\.skinBackdropReadability) private var backdrop
    var body: some View {
        Color.black.opacity(intensity).allowsHitTesting(false)
            .onChange(of: intensity, initial: true) { _, value in backdrop?.setDimming(value) }
    }
}

private struct SkinPanelLauncher: View {
    let action: String
    let configuration: SkinComponentConfiguration
    @Environment(\.skinSceneActions) private var actions
    var body: some View {
        Button(configuration.text("title", fallback: title), action: invoke).buttonStyle(AppPanelButtonStyle())
    }
    private var title: String {
        switch action {
        case "quickPanel": "快速外观"
        case "detail": "歌曲详情"
        case "edit", "external": "编辑信息"
        default: "设置"
        }
    }
    private func invoke() {
        switch action {
        case "quickPanel": actions.openQuickPanel()
        case "detail": actions.openTrackDetail()
        case "edit": actions.openTrackEdit()
        case "external": actions.openExternalInfo()
        default: actions.openSettings()
        }
    }
}
