//
//  FeatureDiscoveryItem.swift
//  kmgccc_player
//
//  Static description of one feature discovery prompt.
//

import Foundation

/// Who may see a discovery item.
enum DiscoveryCohortRule: Equatable, Sendable {
    /// Only installs that existed before this feature.
    case upgradedUsersOnly
    /// Upgraded installs right away; a fresh install once it has been
    /// installed `newUserMinInstallDays` days or used on
    /// `newUserMinActiveDays` distinct days.
    case allUsers(newUserMinInstallDays: Int, newUserMinActiveDays: Int)

    func isSatisfied(by profile: UserCohortProfile, now: Date) -> Bool {
        switch self {
        case .upgradedUsersOnly:
            return profile.cohort == .upgraded
        case .allUsers(let minInstallDays, let minActiveDays):
            guard profile.cohort == .newInstall else { return true }
            let installedSeconds = now.timeIntervalSince(profile.firstLaunchDate)
            return installedSeconds >= TimeInterval(minInstallDays) * 86_400
                || profile.activeDayKeys.count >= minActiveDays
        }
    }
}

enum DiscoveryPreviewAsset: Equatable, Sendable {
    /// A silent looping clip from the App bundle, with a still poster for
    /// Reduce Motion.
    case loopingVideo(resourceName: String, fileExtension: String, posterName: String, posterExtension: String)
}

enum DiscoveryAction: Equatable, Sendable {
    /// Selects the fullscreen skin, then opens the fullscreen player inside
    /// the main window.
    case enterEmbeddedFullscreen(skinID: String)

    /// The skin this action introduces; discovery ends once the user is
    /// already there.
    var targetSkinID: String {
        switch self {
        case .enterEmbeddedFullscreen(let skinID): skinID
        }
    }
}

struct FeatureDiscoveryCopy: Equatable, Sendable {
    let featureName: String
    let badgeForUpgradedUsers: String
    let badgeForNewUsers: String
    let body: String
    let primaryButtonTitle: String
    let secondaryButtonTitle: String

    func badge(for cohort: UserCohort) -> String {
        cohort == .upgraded ? badgeForUpgradedUsers : badgeForNewUsers
    }
}

struct FeatureDiscoveryItem: Identifiable, Equatable, Sendable {
    /// Stable persistence key, e.g. "skin.zichao.v1". Change the suffix to
    /// introduce the same feature again.
    let id: String
    /// The item takes effect from this build on.
    let introducedBuild: AppBuild
    /// Among waiting items the highest priority wins; the rest are superseded.
    let priority: Int
    let copy: FeatureDiscoveryCopy
    let preview: DiscoveryPreviewAsset
    let requiredPlaybackSeconds: TimeInterval
    let cohortRule: DiscoveryCohortRule
    let requiresLyrics: Bool
    let action: DiscoveryAction

    var promptID: AppPromptID { .featureDiscovery(id) }
}
