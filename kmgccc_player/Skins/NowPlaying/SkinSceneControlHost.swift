import AppKit
import MotionKit
import SwiftUI

/// Ephemeral UI belongs to the host, not to each component. Commands still use the
/// existing coordinator; sheets, mandatory chrome and Quick Panel stay above the scene.
struct SkinSceneControlHost<Content: View>: View {
    let surface: SkinSurface
    let lyricsVisible: Bool
    let onExit: () -> Void
    let onRestore: () -> Void
    let onReload: () -> Void
    let onToggleLyrics: () -> Void
    /// The skin's own foreground policy, as the built-in fullscreen host applies it.
    var controlForeground: SkinPresentationPolicy.ControlForeground = .chrome
    /// Where the skin asks the Quick Panel to open.
    var panelPlacement: SkinPresentationPolicy.PanelPlacement = .center
    var trackDetailPresentation: SkinPresentationPolicy.TrackDetailPresentation = .host
    var scrollVolume = false
    @ViewBuilder let content: () -> Content

    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(LibraryViewModel.self) private var library
    @Environment(LibraryCacheServices.self) private var caches
    @Environment(AppSettings.self) private var settings
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(PlayerViewModel.self) private var player
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.motionArtworkFullscreenCoordinator) private var motionFullscreen
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.motionTokens) private var motionTokens
    @State private var controls = FullscreenBottomControlsCoordinator()
    @State private var providedControls: Set<SkinSceneControl> = []
    @State private var hitRegions = SkinSceneHitRegions()
    @State private var editingTrack: Track?
    @State private var editingExternalInfo = false
    @State private var showingSettings = false
    @State private var detailTrack: Track?
    @State private var detailDismissID: UUID?
    @State private var deletionRequest: TrackDeletionConfirmationRequest?
    @State private var showingMusicInfo = false
    @State private var volumeHUDVisible = false
    @State private var volumeHUDValue = AppSettings.defaultVolume
    @State private var volumeHUDHideTask: Task<Void, Never>?

    private var nativeContext: SkinNativeControlsContext {
        let material: LiquidGlassPillMaterialStyle = settings.fullscreenMiniPlayerGlassMaterial == .normal ? .normal : .clear
        let profile = FullscreenMiniPlayerForegroundStrategy.resolve(
            palette: theme.semanticPalette, localArtworkPolarity: nil,
            hasArtworkThemeColor: theme.palette != nil, controlForeground: controlForeground,
            colorScheme: theme.colorScheme, materialStyle: material, fullscreenArtBackgroundEnabled: settings.fullscreenArtBackgroundEnabled
        )
        return .init(
            presentation: .init(
                glassStyle: .init(colorScheme: profile.complementaryGlassColorScheme, accentColor: theme.accentColor, materialStyle: material),
                miniPlayerForegroundProfile: profile,
                primaryColor: Color(nsColor: profile.primary), iconBlendMode: profile.iconBlendMode,
                playbackMode: playback.stablePresentation.localPlaybackOrderMode ?? settings.playbackOrderMode,
                hasTrack: playback.stablePresentation.hasTrack, isShowingLyrics: lyricsVisible,
                isVolumeControlEnabled: playback.stablePresentation.isVolumeControlEnabled,
                usesAdaptiveVolumeForeground: false, showsPlaybackModeRetapTip: false,
                isMotionArtworkFullscreenActive: motionFullscreen?.isActive == true
            ),
            actions: .init(
                exitFullscreen: surface == .fullscreen ? onExit : enterFullscreen,
                toggleLyrics: onToggleLyrics,
                exitMotionArtworkFullscreen: { [weak coordinator = motionFullscreen] in
                    coordinator?.exit(motionPolicy: motionPolicy, motionTokens: motionTokens)
                },
                setQuickAppearancePanelPresented: { presented in
                    if surface == .fullscreen { controls.isQuickAppearancePanelPresented = presented }
                    else { presentSettings() }
                },
                hotZoneHoverChanged: { _ in }, centerHoverChanged: { _ in },
                leadingHoverChanged: { _ in }, trailingHoverChanged: { _ in },
                appearancePanelHoverChanged: { _ in }, progressDraggingChanged: { _ in },
                volumeAdjustingChanged: { _ in }, interaction: {},
                playbackModeChanged: { playback.setPlaybackOrderMode($0) },
                currentPlaybackModeRetapped: { _ in uiState.toggleWindowPlaybackQueue() },
                editTrackRequested: { editingTrack = $0 }, editExternalInfoRequested: { editingExternalInfo = true },
                showDetailRequested: { detailTrack = $0 }, dismissPlaybackModeRetapTip: {}
            ), controls: controls
        )
    }

    var body: some View {
        let native = nativeContext
        let sceneDetail = trackDetailPresentation == .scene ? detailTrack : nil
        content()
            .environment(\.skinNativeControls, native)
            .environment(\.skinSceneHitRegions, hitRegions)
            .environment(\.skinSceneActions, actions)
            .environment(\.skinSceneHostOverlays, SkinSceneHostOverlays(
                quickPanelVisible: controls.isQuickAppearancePanelPresented, track: sceneDetail,
                detail: sceneDetail.map { TrackDetailResolver.resolve(for: $0, libraryVM: library) }
            ))
            .onPreferenceChange(SkinSceneControlsKey.self) { providedControls = $0 }
            .overlay {
                if scrollVolume { volumeLayer(native) }
            }
            .overlay(alignment: .topTrailing) {
                if surface == .fullscreen {
                    HStack(spacing: 12) {
                        if !providedControls.contains(.fullscreen) { SkinActionButton(reportsControls: false, kind: .fullscreen, configuration: .init()) }
                        if !providedControls.contains(.lyricsToggle) { SkinActionButton(reportsControls: false, kind: .lyricsToggle, configuration: .init()) }
                        if !providedControls.contains(.quickPanel) { SkinActionButton(reportsControls: false, kind: .quickPanel, configuration: .init()) }
                    }
                    .environment(\.skinNativeControls, native)
                    .environment(\.skinSceneSurface, surface)
                    .environment(\.skinSceneActions, actions)
                    .padding(12)
                }
            }
            .overlay {
                GeometryReader { proxy in
                    if controls.isQuickAppearancePanelPresented {
                        let margin: CGFloat = 32
                        let scale = max(0.1, min(1, (proxy.size.width - 2 * margin) / 560, (proxy.size.height - 2 * margin) / 690))
                        let size = FullscreenQuickAppearancePanel.panelSize(for: scale)
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { controls.isQuickAppearancePanelPresented = false }
                            .skinControlRegion()
                        FullscreenQuickAppearancePanel(
                            scale: scale, glassStyle: native.presentation.glassStyle,
                            foregroundProfile: native.presentation.quickPanelForegroundProfile,
                            onDismiss: { controls.isQuickAppearancePanelPresented = false }
                        )
                        .frame(width: size.width, height: size.height)
                        .skinControlRegion()
                        .position(x: panelCenterX(width: proxy.size.width, panelWidth: size.width, margin: margin), y: proxy.size.height / 2)
                        // Offset rather than scale keeps the AppKit-backed controls at a stable size.
                        .transition(.opacity.combined(with: .offset(panelEntryOffset)))
                    }
                }
                .motionAnimation(.control, value: controls.isQuickAppearancePanelPresented)
            }
            .overlay {
                // The track detail as the built-in fullscreen shows it: a glass card inside the window.
                GeometryReader { proxy in
                    if trackDetailPresentation == .host, let track = detailTrack {
                        let detail = TrackDetailResolver.resolve(for: track, libraryVM: library)
                        let scale = max(0.1, min(1, (proxy.size.width - 64) / 580, (proxy.size.height - 64) / 640))
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture { detailTrack = nil }
                            .skinControlRegion()
                            .transition(.opacity)
                        FullscreenDetailReaderPanel(
                            title: detail.subtitle, attributionNote: detail.attributionNote, text: detail.text,
                            scale: scale, foregroundProfile: native.presentation.quickPanelForegroundProfile,
                            onDismiss: { detailTrack = nil }
                        )
                        .skinControlRegion()
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .transition(.opacity.combined(with: .offset(x: 0, y: 8)))
                    }
                }
                .motionAnimation(.navigation, value: detailTrack?.id)
            }
            .overlayPreferenceValue(SkinControlRegionKey.self) { anchors in
                GeometryReader { proxy in
                    SkinSceneHitRegionBridge(regions: hitRegions, rectangles: anchors.map { proxy[$0] })
                        .allowsHitTesting(false)
                }
            }
            .sheet(item: $editingTrack) { TrackEditSheet(track: $0).environmentObject(theme) }
            .sheet(isPresented: $showingMusicInfo) {
                let presentation = playback.stablePresentation
                if let snapshot = presentation.musicEnrichment {
                    MusicEnrichmentDetailView(snapshot: snapshot, title: presentation.title, artist: presentation.artist)
                        .environmentObject(theme)
                }
            }
            .trackDeletionConfirmation(item: $deletionRequest) { tracks in
                Task { await library.deleteTracks(tracks) }
            }
            .sheet(isPresented: $editingExternalInfo) {
                ExternalPlaybackInfoEditorView(
                    presentation: playback.presentation, metadataStore: caches.externalPlaybackMetadataStore,
                    onSaved: { playback.invalidateExternalPlaybackResolution(onlyOffsetChanged: $0) }
                ).environmentObject(theme)
            }
            .sheet(isPresented: $showingSettings, onDismiss: {
                AppPromptCoordinator.shared.setObstruction(.settingsSheet, active: false)
            }) {
                SettingsView(hasActiveLibrarySession: true).environmentObject(theme)
            }
            .onExitCommand(perform: detailTrack == nil ? nil : { detailTrack = nil })
            // In fullscreen, Esc reaches the fullscreen manager first; it asks transient
            // overlays to close before it leaves fullscreen.
            .onChange(of: detailTrack?.id, initial: true) { _, id in
                if id != nil, detailDismissID == nil {
                    detailDismissID = FullscreenTransientDismissCoordinator.shared.register {
                        guard detailTrack != nil else { return false }
                        detailTrack = nil
                        return true
                    }
                } else if id == nil, let registered = detailDismissID {
                    FullscreenTransientDismissCoordinator.shared.unregister(registered)
                    detailDismissID = nil
                }
            }
            .onDisappear {
                if let registered = detailDismissID { FullscreenTransientDismissCoordinator.shared.unregister(registered) }
                detailDismissID = nil
            }
    }

    /// The scroll wheel sets the volume anywhere over the scene, yielding to whatever else
    /// under the pointer scrolls and to open panels.
    private func volumeLayer(_ native: SkinNativeControlsContext) -> some View {
        GeometryReader { proxy in
            let scale = max(0.8, min(1.2, min(proxy.size.width, proxy.size.height) / 900))
            let profile = native.presentation.miniPlayerForegroundProfile
            ZStack {
                PanoramicArtworkVolumeScrollArea(
                    volume: Binding(get: { playback.presentation.volume }, set: { playback.setVolume($0) }),
                    isEnabled: playback.stablePresentation.isVolumeControlEnabled,
                    onAdjustment: adjustVolume,
                    coversWholeArea: true,
                    yields: { event in
                        controls.isQuickAppearancePanelPresented || detailTrack != nil
                            || SkinSceneScrollRegion.RegionView.claims(event) || SkinScrollYieldRegion.YieldView.claims(event)
                            || Self.scrollsUnderPointer(event)
                    }
                )
                if volumeHUDVisible {
                    VolumeScrollHUD(
                        volume: volumeHUDValue, scale: scale, foregroundProfile: profile,
                        glassStyle: .init(colorScheme: profile.complementaryGlassColorScheme,
                                          accentColor: native.presentation.glassStyle.accentColor,
                                          materialStyle: native.presentation.glassStyle.materialStyle)
                    )
                    .transition(motionPolicy != .full ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .motionAnimation(.microInteraction, value: volumeHUDVisible)
    }

    private func adjustVolume(_ adjustment: Double) {
        let current = playback.presentation.volume
        let next = VolumeControlBehavior.clamped(current + adjustment)
        guard abs(next - current) > 0.0001 else { return }
        volumeHUDValue = next
        playback.setVolume(next)
        volumeHUDHideTask?.cancel()
        volumeHUDVisible = true
        volumeHUDHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            volumeHUDVisible = false
            volumeHUDHideTask = nil
        }
    }

    /// A list, text or other scroll view under the pointer keeps its own scrolling.
    private static func scrollsUnderPointer(_ event: NSEvent) -> Bool {
        guard let content = event.window?.contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var view = content.hitTest(point)
        while let current = view {
            if current is NSScrollView { return true }
            view = current.superview
        }
        return false
    }

    private func panelCenterX(width: CGFloat, panelWidth: CGFloat, margin: CGFloat) -> CGFloat {
        switch panelPlacement {
        case .center: width / 2
        case .leading: margin + panelWidth / 2
        case .trailing: width - margin - panelWidth / 2
        }
    }

    /// The panel slides in from the edge it sits against; a centred panel rises slightly.
    private var panelEntryOffset: CGSize {
        switch panelPlacement {
        case .center: CGSize(width: 0, height: 12)
        case .leading: CGSize(width: -24, height: 0)
        case .trailing: CGSize(width: 24, height: 0)
        }
    }

    private func presentSettings() {
        AppPromptCoordinator.shared.setObstruction(.settingsSheet, active: true)
        showingSettings = true
    }

    private func enterFullscreen() { FullscreenWindowManager.shared.showFullscreenPlayerInWindow() }

    private var actions: SkinSceneActions {
        .init(
            playPause: { playback.playPause() }, previous: { playback.previous() }, next: { playback.next() },
            seek: { playback.seek(to: $0) }, setVolume: { playback.setVolume($0) },
            setPlaybackOrder: { playback.setPlaybackOrderMode($0) },
            setExternalPlaybackOrder: { playback.setAppleMusicPlaybackMode($0) },
            like: {
                guard let track = playback.stablePresentation.localTrack else { return }
                let liked = library.preferenceStats(for: track.id).manualLikeState == .liked
                Task { await library.setManualLikeState(liked ? .none : .liked, for: track) }
            },
            toggleQueue: { uiState.toggleWindowPlaybackQueue() }, toggleLyrics: onToggleLyrics,
            enterFullscreen: enterFullscreen, exit: onExit,
            openSettings: { presentSettings() }, openQuickPanel: { if surface == .fullscreen { controls.isQuickAppearancePanelPresented = true } else { presentSettings() } },
            reload: onReload, restore: onRestore,
            stop: { playback.stop() },
            playQueueIndex: { index in
                guard player.currentQueueTracks.indices.contains(index) else { return }
                playback.playTrackFromQueue(player.currentQueueTracks[index])
            },
            openTrackDetail: { detailTrack = playback.stablePresentation.localTrack },
            closeTrackDetail: { detailTrack = nil },
            openTrackEdit: { editingTrack = playback.stablePresentation.localTrack },
            openExternalInfo: { if playback.stablePresentation.source != .local { editingExternalInfo = true } },
            play: { playback.resume() }, pause: { playback.pause() }, seekAndResume: { playback.seekAndResumeIfNeeded(to: $0) },
            setLikeState: { state in
                guard let track = playback.stablePresentation.localTrack else { return }
                Task { await library.setManualLikeState(state, for: track) }
            },
            toggleDislike: {
                guard let track = playback.stablePresentation.localTrack else { return }
                let disliked = library.preferenceStats(for: track.id).manualLikeState == .disliked
                Task { await library.setManualLikeState(disliked ? .none : .disliked, for: track) }
            },
            addToPlaylist: { id in
                guard let track = playback.stablePresentation.localTrack else { return }
                Task {
                    let target: Playlist?
                    if let id { target = library.playlists.first(where: { $0.id == id }) }
                    else { target = await library.createNewPlaylist() }
                    guard let target else { return }
                    await library.addTracksToPlaylist([track], playlist: target)
                }
            },
            deleteTrack: {
                guard let track = playback.stablePresentation.localTrack else { return }
                deletionRequest = TrackDeletionConfirmationRequest(tracks: [track])
            },
            openMusicInfo: { if playback.stablePresentation.musicEnrichment != nil { showingMusicInfo = true } },
            showArtist: { navigate { library.navigateToArtist(for: $0, uiState: uiState) } },
            showAlbum: { navigate { library.navigateToAlbum(for: $0, uiState: uiState) } },
            selectOutput: { uid in
                guard settings.audioOutputDeviceUID != uid else { return }
                settings.audioOutputDeviceUID = uid
                NotificationCenter.default.post(name: .audioOutputDevicePreferenceDidChange, object: nil)
            }
        )
    }

    /// Library navigation lands in the main window, so fullscreen closes first.
    private func navigate(_ body: (Track) -> Void) {
        guard let track = playback.stablePresentation.localTrack else { return }
        if surface == .fullscreen { onExit() }
        body(track)
    }
}
