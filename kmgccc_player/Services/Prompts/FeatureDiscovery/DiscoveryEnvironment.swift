//
//  DiscoveryEnvironment.swift
//  kmgccc_player
//
//  What the discovery engine reads from the App, behind a seam tests replace.
//

import CoreGraphics
import Foundation

struct DiscoveryPlaybackSample: Equatable, Sendable {
    var trackKey: String?
    var isPlaying: Bool
    /// Audible song position in seconds.
    var position: TimeInterval

    static let idle = DiscoveryPlaybackSample(trackKey: nil, isPlaying: false, position: 0)
}

struct DiscoverySurfaceState: Equatable, Sendable {
    var isAppActive: Bool
    /// Main window on screen, not minimized and not fully covered.
    var isMainWindowVisible: Bool
    var mainWindowContentSize: CGSize
    /// Any fullscreen player route: embedded, system space, or one in transition.
    var isFullscreenActive: Bool
    /// A sheet, App-modal window, open menu, popover or dialog panel.
    var hasTransientUI: Bool
}

/// Reasons a discovery prompt is held back at this moment.
enum DiscoveryHold: String, Sendable {
    case targetUnavailable
    case appInactive
    case windowHidden
    case windowTooSmall
    case fullscreenActive
    case transientUI
    case lyricsMissing
    case recentInteraction
}

struct DiscoveryGatePolicy: Sendable {
    var minimumWindowSize = CGSize(width: 560, height: 480)
    var interactionQuietPeriod: TimeInterval = 2.5

    /// The first condition that holds a prompt back, or nil when it may show.
    func hold(
        surface: DiscoverySurfaceState,
        targetAvailable: Bool,
        requiresLyrics: Bool,
        hasLyrics: Bool,
        lastInteraction: Date?,
        now: Date
    ) -> DiscoveryHold? {
        if !targetAvailable { return .targetUnavailable }
        if !surface.isAppActive { return .appInactive }
        if !surface.isMainWindowVisible { return .windowHidden }
        if surface.mainWindowContentSize.width < minimumWindowSize.width
            || surface.mainWindowContentSize.height < minimumWindowSize.height {
            return .windowTooSmall
        }
        if surface.isFullscreenActive { return .fullscreenActive }
        if surface.hasTransientUI { return .transientUI }
        if requiresLyrics, !hasLyrics { return .lyricsMissing }
        if let lastInteraction, now.timeIntervalSince(lastInteraction) < interactionQuietPeriod {
            return .recentInteraction
        }
        return nil
    }
}

/// The App state discovery depends on. The live implementation reads the
/// playback coordinator, the main window and the fullscreen manager.
@MainActor
protocol DiscoveryEnvironment: AnyObject {
    var now: Date { get }
    var lastUserInteraction: Date? { get }
    /// Called when something gates depend on may have changed: activation,
    /// window state, fullscreen, sheets, menus.
    var onChange: (() -> Void)? { get set }

    func playbackSample() -> DiscoveryPlaybackSample
    func currentTrackHasLyrics() -> Bool
    func surfaceState() -> DiscoverySurfaceState
    func isSkinAvailable(_ skinID: String) -> Bool
    /// The skin is the selected fullscreen skin.
    func isSkinSelected(_ skinID: String) -> Bool
    /// The fullscreen player is on screen with this skin.
    func isShowingSkin(_ skinID: String) -> Bool
    /// Tracks pointer and keyboard input only while the engine waits to show.
    func setInteractionTracking(_ enabled: Bool)
    func perform(_ action: DiscoveryAction)
}

/// Presents the discovery card.
@MainActor
protocol FeatureDiscoveryPresenting: AnyObject {
    func present(
        _ item: FeatureDiscoveryItem,
        cohort: UserCohort,
        onPrimary: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    )
    /// Removes the card with its exit motion. Starting the action in the same
    /// turn lets the card fade over the scene that replaces it.
    func dismiss(_ item: FeatureDiscoveryItem)
}
