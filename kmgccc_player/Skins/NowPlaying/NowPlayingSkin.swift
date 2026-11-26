//
//  NowPlayingSkin.swift
//  myPlayer2
//
//  kmgccc_player - Now Playing Skin Protocol
//

import SwiftUI

protocol NowPlayingSkin {
    var descriptor: SkinDescriptor { get }
    var scene: SkinScene? { get }
    var parameterDefinitions: [SkinParameterDefinition] { get }

    func makeBackground(context: SkinContext) -> AnyView
    func makeArtwork(context: SkinContext) -> AnyView
    func makeOverlay(context: SkinContext) -> AnyView?
    
    /// Settings view for normal (now playing) mode
    var settingsView: AnyView? { get }
    /// Settings view for fullscreen mode (independent from normal mode)
    var fullscreenSettingsView: AnyView? { get }

    func releaseCachedResources() async
}

/// The App lyrics settings a skin actually reads on one surface.
struct SkinLyricsSettingsUse: Equatable {
    /// Native lyric surface only.
    var renderQuality = true
    var highlight = true
    var spring = true
    var preview = true
    /// Lyric fonts, also read by scenes that draw their own lyrics.
    var fonts = true
    /// The timing group; its overall advance moves every lyric clock.
    var timing = true
    /// Lead-in and near-switch gap, unused by a scene that sets its own lyric lead.
    var lineSwitchTiming = true

    init(renderQuality: Bool = true, highlight: Bool = true, spring: Bool = true, fonts: Bool = true,
         preview: Bool = true, timing: Bool = true, lineSwitchTiming: Bool = true) {
        self.renderQuality = renderQuality
        self.highlight = highlight
        self.spring = spring
        self.fonts = fonts
        self.preview = preview
        self.timing = timing
        self.lineSwitchTiming = lineSwitchTiming
    }
}

extension NowPlayingSkin {
    var scene: SkinScene? { nil }
    var parameterDefinitions: [SkinParameterDefinition] { [] }
    var id: String { descriptor.id }
    var name: String { descriptor.name }
    var detail: String { descriptor.detail }
    var systemImage: String { descriptor.systemImage }
    var isFullscreenCompatible: Bool { descriptor.surfaces.contains(.fullscreen) }
    var isNowPlayingCompatible: Bool { descriptor.surfaces.contains(.window) }
    var sceneComponents: Set<String> { (self as? PackagedSkin)?.sceneComponents ?? [] }
    /// Lyrics settings groups this skin keeps for itself (`font`, `highlight`, `spring`).
    var lyricsSkinOwnedSettings: Set<String> {
        guard let allowed = (self as? PackagedSkin)?.lyricsUserSettings else { return [] }
        return NativeLyricsConfigurationMapper.userSettingGroups.subtracting(allowed)
    }

    /// Which App lyrics settings reach this skin on `surface`, so settings list only those.
    /// Built-in skins and skins without a scene use all of them.
    func lyricsSettingsUse(on surface: SkinSurface) -> SkinLyricsSettingsUse {
        guard let package = self as? PackagedSkin,
              let mountsNative = package.sceneMountsNativeLyrics(on: surface) else { return .init() }
        let readsLyrics = mountsNative || package.sceneReadsLyrics(on: surface) == true
        // A scene that declares `lyricsLead` times its own line switches.
        let ownsLineLead = parameterDefinitions.contains { $0.id == "lyricsLead" }
        let owned = lyricsSkinOwnedSettings
        return .init(
            renderQuality: mountsNative,
            highlight: mountsNative && !owned.contains("highlight"),
            spring: mountsNative && !owned.contains("spring"),
            fonts: readsLyrics && !owned.contains("font"),
            preview: mountsNative,
            timing: readsLyrics,
            lineSwitchTiming: mountsNative || (readsLyrics && !ownsLineLead)
        )
    }

    func releaseCachedResources() async {}

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(SkinArtworkComponent(snapshot: .init(context: context)))
    }

    func makeOverlay(context: SkinContext) -> AnyView? {
        nil
    }

    var settingsView: AnyView? {
        nil
    }

    var fullscreenSettingsView: AnyView? {
        nil
    }
}
