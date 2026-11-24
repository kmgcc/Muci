import SwiftUI
import MotionKit

/// The component names a host implements. The compiler and author tools read this table; the
/// host's factories live with the host (`SkinHostComponents`).
enum SkinComponentContract {
    static let aliases: [String: String] = [
        "lyrics.native": "native.lyrics", "artwork.basic": "native.artwork", "text.trackInfo": "native.trackInfo",
        "control.miniPlayer": "native.miniPlayer", "control.leadingCapsule": "native.actionsCapsule",
        "control.volumeCapsule": "native.volumeCapsule", "control.transport": "native.transport",
        "control.progress": "native.progress", "control.volume": "native.volume",
        "control.playbackMode": "native.playbackMode", "control.like": "native.like", "control.queue": "native.queue",
        "control.lyricsToggle": "native.lyricsToggle", "control.fullscreen": "native.fullscreen",
        "control.settings": "native.settings", "control.quickPanel": "native.quickPanel",
        "visualizer.capsuleSpectrum": "native.spectrum",
        "visualizer.led": "native.led", "visualizer.waveform": "native.waveform",
    ]
    /// Whole preset layers of the bundled skins, rendered exactly as the skin draws them.
    static let presetSkinIDs = [ClassicLEDSkin.id, AppleStyleSkin.skinID, RotatingCoverSkin.id, "kmgccc.cassette", "fullscreen.coverGradientBlur"]
    static var presetParts: Set<String> {
        Set(presetSkinIDs.flatMap { id in SkinPresetComponent.Part.allCases.map { "builtin.\(id).\($0.rawValue)" } })
    }
    static func isKnown(_ id: String) -> Bool { ids.contains(id) || presetParts.contains(id) }

    /// Author options NativeLyricsConfigurationMapper reads. Render scale, caches and timing offsets stay with the App.
    static let lyricsProps: Set<String> = [
        "alignAnchor", "alignOffset", "alignPosition", "alwaysPostpositionBackground", "backdropColor", "bakeSettledBlur",
        "blendOpacity", "bottomText", "channelBlend", "coverBlurBackgroundColor", "coverBlurBackgroundInactiveColor",
        "coverBlurBackgroundKaraokeActiveColor", "coverBlurFullscreenGenericMode", "coverBlurFullscreenGenericProfile",
        "coverBlurFullscreenThemeColor", "coverBlurHideActiveMainLine", "coverBlurLineTimingInactiveColor",
        "coverBlurLineTimingSubInactiveColor", "coverBlurMainActiveColor", "coverBlurMainGlowColor", "coverBlurMainInactiveColor",
        "coverBlurRenderLayer", "coverBlurSubColor", "coverBlurSuppressEmphasisGlow", "currentBlendMode", "enableBlur",
        "enableEmphasis", "enableGlow", "enableScale", "enableSpring", "fontFamilyCJK", "fontFamilyLatin", "fontFamilyMain",
        "fontFamilyTranslation", "fontSize", "fontWeight", "fullscreenActiveColor", "fullscreenAppleStyleMode",
        "fullscreenBackgroundBaseOpacity", "fullscreenBackgroundColor", "fullscreenBackgroundInactiveColor",
        "fullscreenBackgroundKaraokeActiveColor", "fullscreenBackgroundKaraokeOpacity", "fullscreenEmphasisGlowColor",
        "fullscreenInactiveColor", "fullscreenLineTimingInactiveColor", "fullscreenLineTimingSubInactiveColor",
        "fullscreenLyricDodgeMode", "fullscreenSubColor", "glowRadiusScale", "hidePassedLines", "highlightBlendMode",
        "hoverBackground", "inactiveBlendMode", "interludeDotScale", "leadInMs", "lineTimingOnly", "maskCharacter",
        "mixBlendMode", "motion", "nearSwitchGapMs", "obscenity", "palette", "preserveCompletedHighlight",
        "romanizationLanguage", "showRomanization", "showRuby", "showTranslation", "springBounce", "springDuration",
        "surface", "textColor", "translationFontSize", "translationFontWeight", "translationLanguage", "wordFadeWidth",
        "wordHighlightMode", "topFadeRange", "bottomFadeRange", "topEdgeOpacity", "bottomEdgeOpacity", "maximumWidth",
        // Author-level shorthands, resolved by the mapper on every App update.
        "highlight", "hierarchy", "activeColor", "inactiveLevel", "translationLevel", "hierarchyBase", "userSettings",
    ]
    static let parts: Set<String> = [
        "artwork.classicFrame", "artwork.appleStyle", "artwork.rotatingDisc", "artwork.coverGradientBlur",
        "cassette.shell", "cassette.label", "cassette.reels", "cassette.waveform", "cassette.overlay", "cassette.kmgLook",
        "background.host", "background.unifiedMesh", "background.amllMesh", "background.coverGradientBlur", "background.art", "background.artworkBlur", "background.dimming",
        "text.marquee", "text.trackDescription", "panel.queue", "panel.quickAppearance", "panel.trackDetail", "sheet.trackEdit", "sheet.externalInfo", "sheet.settings",
        "control.playPause", "control.previous", "control.next", "control.skip", "control.expandableVolume", "control.actionButton", "control.glassButton", "control.glassTriplePill", "transition.bokeh",
        "behavior.autoHide", "behavior.lyricsEndAutoHide", "behavior.scrollVolume", "behavior.pointerOcclusion", "behavior.windowDrag", "menu.trackContext", "menu.player",
        "control.dislike", "control.outputDevice",
        "control.progressLine", "control.actionStack", "control.playbackModeStack",
        "lyrics.panel", "visualizer.progressSpectrum", "visualizer.pillSpectrum",
    ]
    static var ids: Set<String> { Set(aliases.keys).union(parts).union(SkinBuiltinSceneTemplates.ids) }
    static var capabilities: Set<String> { Set(ids.map { $0 + "@1" }) }
}

extension EnvironmentValues {
    @Entry var skinComponentConfiguration = SkinComponentConfiguration()
}
