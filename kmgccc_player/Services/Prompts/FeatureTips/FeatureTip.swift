//
//  FeatureTip.swift
//  kmgccc_player
//
//  In-context tips: small popovers anchored to the control they explain.
//

import Foundation

/// One in-context tip.
///
/// The anchoring surface decides when the tip is relevant, then asks
/// `AppPromptCoordinator` for the slot at the `.contextualTip` tier.
/// `FeatureTipStore` keeps the display budget.
struct FeatureTip: Hashable, Sendable {
    let key: String
    /// Installs whose baseline predates this build see the tip; nil reaches
    /// every install. An upgrade across this build resets the tip's budget,
    /// so raising it re-introduces a revised tip.
    let introducedBuild: AppBuild?
    let maxDisplayCount: Int
    /// How long the trigger must hold before the tip asks for the slot.
    let presentationDelay: Duration

    var promptID: AppPromptID { .featureTip(key) }
}

extension FeatureTip {
    static let playbackModeRetap = FeatureTip(
        key: "fullscreen.playbackModeRetap",
        introducedBuild: nil,
        maxDisplayCount: 2,
        presentationDelay: .seconds(3)
    )

    static let shiftRangeSelection = FeatureTip(
        key: "playlist.shiftRangeSelection",
        introducedBuild: AppBuild(16),
        maxDisplayCount: 2,
        presentationDelay: .zero
    )

    static let automaticCrashReports = FeatureTip(
        key: "dataSharing.automaticCrashReports",
        introducedBuild: AppBuild(8),
        maxDisplayCount: 2,
        presentationDelay: .seconds(3)
    )

    static let scrollWheelVolume = FeatureTip(
        key: "fullscreen.scrollWheelVolume",
        introducedBuild: AppBuild(10),
        maxDisplayCount: 1,
        presentationDelay: .seconds(5)
    )

    static let all: [FeatureTip] = [
        .playbackModeRetap,
        .shiftRangeSelection,
        .automaticCrashReports,
        .scrollWheelVolume,
    ]
}

extension AppPromptCoordinator {
    /// Asks for the slot on behalf of `tip`.
    ///
    /// `show` runs when the slot is free and the tip still has budget. It
    /// re-checks the anchor's context, shows the tip and returns `true`, or
    /// returns `false` when the moment has passed. Only a shown tip spends a
    /// display. The anchor calls `finishTip(_:)` when the tip closes or its
    /// surface goes away.
    func requestTip(
        _ tip: FeatureTip,
        store: FeatureTipStore = .shared,
        show: @escaping @MainActor () -> Bool
    ) {
        guard store.isEligible(tip) else { return }
        submit(AppPromptRequest(id: tip.promptID, tier: .contextualTip) {
            guard store.isEligible(tip), show() else { return false }
            store.recordDisplay(tip)
            return true
        })
    }

    func finishTip(_ tip: FeatureTip) {
        finish(tip.promptID)
    }
}
