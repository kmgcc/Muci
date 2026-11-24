//
//  FeatureTipStore.swift
//  kmgccc_player
//
//  Display budget for in-context tips.
//

import Foundation

/// Persists how often each tip appeared and whether the user dismissed it.
///
/// A tip appears at most once per launch and at most `maxDisplayCount` times
/// in total. Its explicit "got it" action dismisses it for good.
@MainActor
final class FeatureTipStore {
    static let shared = FeatureTipStore(installHistory: .shared)

    private enum Keys {
        static let dismissedPrefix = "kmgccc_player.dismissedFeatureTip."
        static let displayCountPrefix = "kmgccc_player.featureTipDisplayCount."
    }

    private let defaults: UserDefaults
    private let installHistory: AppInstallHistory
    private var claimedThisLaunch = Set<String>()

    init(defaults: UserDefaults = PromptDefaults.store, installHistory: AppInstallHistory) {
        self.defaults = defaults
        self.installHistory = installHistory
    }

    func isEligible(_ tip: FeatureTip) -> Bool {
        !claimedThisLaunch.contains(tip.key)
            && !isDismissed(tip)
            && displayCount(tip) < tip.maxDisplayCount
            && isInAudience(tip)
    }

    /// Spends one display. Call when the tip has become visible.
    func recordDisplay(_ tip: FeatureTip) {
        defaults.set(displayCount(tip) + 1, forKey: Keys.displayCountPrefix + tip.key)
        claimedThisLaunch.insert(tip.key)
    }

    func markDismissed(_ tip: FeatureTip) {
        defaults.set(true, forKey: Keys.dismissedPrefix + tip.key)
    }

    /// Resets tips introduced after `launch`'s previous build, so a revised
    /// tip reaches upgrading users again.
    func applyUpgrade(_ launch: AppLaunchRecord, tips: [FeatureTip] = FeatureTip.all) {
        guard let previous = launch.upgradedFromBuild else { return }
        for tip in tips {
            guard let introduced = tip.introducedBuild,
                  previous < introduced, introduced <= launch.currentBuild
            else { continue }
            defaults.removeObject(forKey: Keys.dismissedPrefix + tip.key)
            defaults.removeObject(forKey: Keys.displayCountPrefix + tip.key)
            Log.debug("[FeatureTips] reset \(tip.key) for upgrade from Build \(previous)", category: .ui)
        }
    }

    /// Clears every tip's budget. Debug tools only.
    func resetForDebugging() {
        claimedThisLaunch.removeAll()
        for tip in FeatureTip.all {
            defaults.removeObject(forKey: Keys.dismissedPrefix + tip.key)
            defaults.removeObject(forKey: Keys.displayCountPrefix + tip.key)
        }
    }

    private func isDismissed(_ tip: FeatureTip) -> Bool {
        defaults.bool(forKey: Keys.dismissedPrefix + tip.key)
    }

    private func displayCount(_ tip: FeatureTip) -> Int {
        defaults.integer(forKey: Keys.displayCountPrefix + tip.key)
    }

    private func isInAudience(_ tip: FeatureTip) -> Bool {
        guard let introduced = tip.introducedBuild else { return true }
        return installHistory.installBaselineBuild < introduced
    }
}
