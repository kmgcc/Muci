//
//  WhatsNewConfig.swift
//  myPlayer2
//
//  kmgccc_player - WhatsNew presentation configuration and state management
//

import Foundation
import WhatsNewKit

enum WhatsNewConfig {

    static let targetBuild = AppBuild(27)
    static let whatsNewVersion = WhatsNew.Version(major: 2, minor: 5, patch: 0)

    private static let lastSeenBuildKey = "kmgccc_player.lastSeenWhatsNewBuild"

    private static var defaults: UserDefaults { PromptDefaults.store }

    private static var lastSeenBuild: AppBuild? {
        guard defaults.object(forKey: lastSeenBuildKey) != nil else { return nil }
        return AppBuild(defaults.integer(forKey: lastSeenBuildKey))
    }

    /// The welcome overview belongs to the first launch of a fresh install.
    @MainActor
    static var shouldShowWelcome: Bool {
        AppInstallHistory.shared.currentLaunch?.isFreshInstall == true && lastSeenBuild == nil
    }

    @MainActor
    static func shouldShowWhatsNew() -> Bool {
        guard AppInstallHistory.shared.currentLaunch?.isFreshInstall == false else { return false }
        guard let lastSeenBuild else { return true }
        return lastSeenBuild < targetBuild
    }

    @MainActor
    static func shouldShowAnnouncement() -> Bool {
        shouldShowWelcome || shouldShowWhatsNew()
    }

    static func markAsSeen() {
        defaults.set(targetBuild.rawValue, forKey: lastSeenBuildKey)
    }

    #if DEBUG
    /// Sets the build whose announcement the user last saw; nil forgets it.
    static func seedLastSeenForDebugging(_ build: AppBuild?) {
        if let build {
            defaults.set(build.rawValue, forKey: lastSeenBuildKey)
        } else {
            defaults.removeObject(forKey: lastSeenBuildKey)
        }
    }
    #endif
}
