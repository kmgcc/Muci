//
//  AppPromptTypes.swift
//  kmgccc_player
//
//  Shared vocabulary for prompts the App shows on its own initiative.
//

import Foundation

/// How strongly an App-initiated prompt may claim attention.
///
/// The coordinator presents lower tiers first and never interrupts a prompt
/// already on screen. Prompts the user opens themself (Settings, dialogs from
/// a menu) are outside this system.
enum AppPromptTier: Int, Comparable, CaseIterable, Sendable {
    /// Needed before normal use: crash report review, first-run onboarding.
    case blocking = 0
    /// Release announcements.
    case release = 1
    /// Feature discovery: at most one per launch, after a quiet period.
    case discovery = 2
    /// Small popovers anchored to the control they explain.
    case contextualTip = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Closing a prompt of this tier starts the cooldown. A tip never queues
    /// right behind a larger prompt, such as one that just led into the
    /// fullscreen player.
    var startsCooldown: Bool { self <= .discovery }

    /// Whether prompts of this tier wait for the cooldown to pass.
    var waitsForCooldown: Bool { self >= .discovery }
}

struct AppPromptID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

extension AppPromptID {
    static let crashReport = AppPromptID("crashReport")
    static let whatsNew = AppPromptID("whatsNew")
    static let firstRunLibrarySetup = AppPromptID("firstRunLibrarySetup")

    static func featureTip(_ key: String) -> AppPromptID {
        AppPromptID("featureTip.\(key)")
    }

    static func featureDiscovery(_ itemID: String) -> AppPromptID {
        AppPromptID("featureDiscovery.\(itemID)")
    }
}

/// A condition that holds every prompt back while it lasts.
enum AppPromptObstruction: Hashable, Sendable {
    /// Launch prompts are still being collected. Holding them until the launch
    /// settles lets priority, not arrival order, decide what shows first.
    case launchSequence
    /// A Settings sheet is open.
    case settingsSheet
}

/// A request for the single prompt slot.
///
/// `present` runs once the slot is free and returns whether the prompt
/// actually appeared. Returning `false` drops the request; the owner submits
/// again when its own context allows. The owner calls
/// `AppPromptCoordinator.finish(_:)` when the prompt closes.
struct AppPromptRequest {
    let id: AppPromptID
    let tier: AppPromptTier
    let present: @MainActor () -> Bool
}
