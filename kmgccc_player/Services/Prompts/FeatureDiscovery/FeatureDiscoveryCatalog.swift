//
//  FeatureDiscoveryCatalog.swift
//  kmgccc_player
//
//  Local registry of feature discovery items.
//

import Foundation

/// Every feature discovery item the App knows. Adding a new skin or major
/// feature introduction means adding an item here.
enum FeatureDiscoveryCatalog {
    static let zichaoSkin = FeatureDiscoveryItem(
        id: "skin.zichao.v1",
        introducedBuild: AppBuild(23),
        priority: 1,
        copy: FeatureDiscoveryCopy(
            featureName: "字潮",
            badgeForUpgradedUsers: "新皮肤",
            badgeForNewUsers: "精选皮肤",
            body: "当字如潮水涌来，让心仪的音乐沁透每一片星空",
            primaryButtonTitle: "进入字潮",
            secondaryButtonTitle: "稍后"
        ),
        preview: .loopingVideo(
            resourceName: "zichao-preview",
            fileExtension: "mp4",
            posterName: "zichao-preview-poster",
            posterExtension: "jpg"
        ),
        requiredPlaybackSeconds: 60,
        cohortRule: .allUsers(newUserMinInstallDays: 3, newUserMinActiveDays: 2),
        requiresLyrics: true,
        action: .enterEmbeddedFullscreen(skinID: "user.zichao")
    )

    static let items: [FeatureDiscoveryItem] = [zichaoSkin]
}
