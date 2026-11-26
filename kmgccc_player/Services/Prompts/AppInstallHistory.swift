//
//  AppInstallHistory.swift
//  kmgccc_player
//
//  Records which build this install ran before, for release-state gates.
//

import Foundation

/// What this process learned about the install when it launched.
struct AppLaunchRecord: Equatable, Sendable {
    let currentBuild: AppBuild
    /// The build that ran last; nil on the first launch of a fresh install.
    let lastLaunchedBuild: AppBuild?

    var isFreshInstall: Bool { lastLaunchedBuild == nil }

    /// The previous build when this launch is the first after an upgrade.
    var upgradedFromBuild: AppBuild? {
        guard let lastLaunchedBuild, lastLaunchedBuild < currentBuild else { return nil }
        return lastLaunchedBuild
    }
}

/// Build history behind feature tips, What's New and feature discovery.
///
/// Data written by 2.3.4 (Build 15) and later is the oldest this reads.
@MainActor
final class AppInstallHistory {
    static let shared = AppInstallHistory()

    private enum Keys {
        static let previousInstalledBuild = "kmgccc_player.previousInstalledBuild"
        static let latestInstalledBuild = "kmgccc_player.latestInstalledBuild"
    }

    private let defaults: UserDefaults
    private(set) var currentLaunch: AppLaunchRecord?

    init(defaults: UserDefaults = PromptDefaults.store) {
        self.defaults = defaults
    }

    /// The build this install ran before its most recent upgrade.
    /// `legacyBaseline` for an install that has never been upgraded.
    var installBaselineBuild: AppBuild {
        build(forKey: Keys.previousInstalledBuild) ?? .legacyBaseline
    }

    /// Records this launch once per process and returns what it found.
    @discardableResult
    func recordLaunch(currentBuild: AppBuild = .current) -> AppLaunchRecord {
        if let currentLaunch { return currentLaunch }

        let lastLaunched = build(forKey: Keys.latestInstalledBuild)
        if lastLaunched == nil {
            setBuild(.legacyBaseline, forKey: Keys.previousInstalledBuild)
        } else if let lastLaunched, lastLaunched != currentBuild {
            setBuild(lastLaunched, forKey: Keys.previousInstalledBuild)
        }
        setBuild(currentBuild, forKey: Keys.latestInstalledBuild)

        let record = AppLaunchRecord(currentBuild: currentBuild, lastLaunchedBuild: lastLaunched)
        currentLaunch = record
        Log.debug(
            "[InstallHistory] launch build=\(currentBuild) last=\(lastLaunched?.description ?? "none") baseline=\(installBaselineBuild)",
            category: .ui
        )
        return record
    }

    private func build(forKey key: String) -> AppBuild? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return AppBuild(defaults.integer(forKey: key))
    }

    private func setBuild(_ build: AppBuild, forKey key: String) {
        defaults.set(build.rawValue, forKey: key)
    }
}

#if DEBUG
extension AppInstallHistory {
    /// Makes the coming `recordLaunch()` see `lastLaunchedBuild` as the build
    /// that ran before; nil replays a fresh install.
    func seedForDebugging(lastLaunchedBuild: AppBuild?) {
        guard currentLaunch == nil else { return }
        defaults.removeObject(forKey: Keys.previousInstalledBuild)
        if let lastLaunchedBuild {
            setBuild(lastLaunchedBuild, forKey: Keys.latestInstalledBuild)
        } else {
            defaults.removeObject(forKey: Keys.latestInstalledBuild)
        }
    }
}
#endif
