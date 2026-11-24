//
//  LiveDiscoveryEnvironment.swift
//  kmgccc_player
//
//  Reads discovery conditions from the running App.
//

import AppKit
import Combine
import Foundation

@MainActor
final class LiveDiscoveryEnvironment: DiscoveryEnvironment {
    var onChange: (() -> Void)?
    private(set) var lastUserInteraction: Date?

    private weak var appSession: AppSessionHost?
    private var notificationTokens: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var interactionMonitor: Any?
    private var menuTrackingDepth = 0

    init(appSession: AppSessionHost) {
        self.appSession = appSession
        installObservers()
    }

    var now: Date { Date() }

    func playbackSample() -> DiscoveryPlaybackSample {
        guard let coordinator = appSession?.playbackCoordinator else { return .idle }
        let presentation = coordinator.presentation
        guard presentation.hasTrack else { return .idle }
        let trackKey = presentation.localTrack?.id.uuidString
            ?? presentation.externalStableKey
            ?? "\(presentation.title)\u{1F}\(presentation.artist)"
        return DiscoveryPlaybackSample(
            trackKey: trackKey,
            isPlaying: presentation.isPlaying,
            position: coordinator.audiblePlaybackTime
        )
    }

    func currentTrackHasLyrics() -> Bool {
        LyricsSurfaceManager.shared.hasPlaybackLyrics
    }

    func surfaceState() -> DiscoverySurfaceState {
        guard let window = AppKitMainSplitWindowController.mainWindow else {
            return DiscoverySurfaceState(
                isAppActive: NSApp.isActive,
                isMainWindowVisible: false,
                mainWindowContentSize: .zero,
                isFullscreenActive: false,
                hasTransientUI: false
            )
        }
        let fullscreen = FullscreenWindowManager.shared
        return DiscoverySurfaceState(
            isAppActive: NSApp.isActive,
            isMainWindowVisible: window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible),
            mainWindowContentSize: window.contentView?.bounds.size ?? .zero,
            isFullscreenActive: fullscreen.usesFullscreenPlayerUI
                || fullscreen.isEmbeddedFullscreenSurfaceMounted
                || fullscreen.isTransitioning
                || window.styleMask.contains(.fullScreen),
            hasTransientUI: hasTransientUI(over: window)
        )
    }

    func isSkinAvailable(_ skinID: String) -> Bool {
        SkinRegistry.registeredDescriptor(for: skinID)?.surfaces.contains(.fullscreen) == true
    }

    func isSkinSelected(_ skinID: String) -> Bool {
        AppSettings.shared.selectedFullscreenSkinID == skinID
    }

    func isShowingSkin(_ skinID: String) -> Bool {
        FullscreenWindowManager.shared.usesFullscreenPlayerUI && isSkinSelected(skinID)
    }

    func setInteractionTracking(_ enabled: Bool) {
        if enabled {
            guard interactionMonitor == nil else { return }
            interactionMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel, .keyDown]
            ) { [weak self] event in
                self?.lastUserInteraction = Date()
                return event
            }
        } else if let monitor = interactionMonitor {
            NSEvent.removeMonitor(monitor)
            interactionMonitor = nil
        }
    }

    func perform(_ action: DiscoveryAction) {
        switch action {
        case .enterEmbeddedFullscreen(let skinID):
            // Select first, so the fullscreen scene's first frame is the target skin.
            AppSettings.shared.selectedFullscreenSkinID = skinID
            FullscreenWindowManager.shared.showFullscreenPlayerInWindow()
        }
    }

    // MARK: - Events

    /// A sheet, App-modal window, open menu, popover or dialog panel.
    private func hasTransientUI(over window: NSWindow) -> Bool {
        if window.attachedSheet != nil || NSApp.modalWindow != nil || menuTrackingDepth > 0 {
            return true
        }
        if window.childWindows?.contains(where: \.isVisible) == true {
            return true
        }
        return NSApp.windows.contains { other in
            other !== window && other.isVisible && other is NSPanel && other.canBecomeKey
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let windowEvents: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didEndSheetNotification,
            NSWindow.willCloseNotification,
        ]
        for name in windowEvents {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }
        notificationTokens.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTrackingDepth += 1 }
        })
        notificationTokens.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                self.onChange?()
            }
        })

        FullscreenWindowManager.shared.$presentationMode
            .removeDuplicates()
            .sink { [weak self] _ in self?.onChange?() }
            .store(in: &cancellables)

        // Playback start, pause and track changes wake the engine's timers.
        appSession?.$playbackCoordinator
            .sink { [weak self] coordinator in
                guard let coordinator else { return }
                self?.observePlayback(of: coordinator)
            }
            .store(in: &cancellables)
    }

    private func observePlayback(of coordinator: PlaybackCoordinator) {
        withObservationTracking {
            _ = coordinator.presentation.isPlaying
            _ = coordinator.presentation.localTrack?.id
            _ = coordinator.presentation.externalStableKey
        } onChange: { [weak self, weak coordinator] in
            Task { @MainActor [weak self, weak coordinator] in
                guard let self, let coordinator,
                      self.appSession?.playbackCoordinator === coordinator
                else { return }
                self.onChange?()
                self.observePlayback(of: coordinator)
            }
        }
    }
}

extension FeatureDiscoveryEngine {
    /// The engine wired to the running App.
    static func makeLive(
        appSession: AppSessionHost,
        coordinator: AppPromptCoordinator,
        hasPriorInstallTraces: Bool
    ) -> FeatureDiscoveryEngine {
        var configuration = Configuration()
        let store = FeatureDiscoveryStore()
        let cohortStore = UserCohortStore()
        #if DEBUG
        PromptDebugLaunchOptions.current.prepare(
            &configuration, coordinator: coordinator, cohortStore: cohortStore
        )
        #endif
        return FeatureDiscoveryEngine(
            configuration: configuration,
            store: store,
            cohortStore: cohortStore,
            coordinator: coordinator,
            environment: LiveDiscoveryEnvironment(appSession: appSession),
            presenter: MainWindowFeatureDiscoveryPresenter(),
            hasPriorInstallTraces: hasPriorInstallTraces
        )
    }
}
