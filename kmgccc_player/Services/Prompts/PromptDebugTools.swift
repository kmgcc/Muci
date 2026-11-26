//
//  PromptDebugTools.swift
//  kmgccc_player
//
//  Debug-build switches for the prompt system.
//

#if DEBUG
import Foundation
import SwiftUI

/// Launch environment switches, read once at launch.
///
/// - `KMGCCC_DEBUG_PROMPTS_SANDBOX=<name>` keeps install history, What's New,
///   tip budgets and discovery progress in the domain
///   `kmgccc.player.debug.prompts.<name>` instead of the real one.
/// - `KMGCCC_DEBUG_INSTALL_HISTORY=fresh|upgrade:<build>` makes this launch
///   look like a fresh install, or like the first launch after upgrading from
///   `<build>`.
/// - `KMGCCC_DEBUG_PROMPTS_RESET=1` empties the sandbox before the launch.
/// - `KMGCCC_DEBUG_COHORT=upgraded|new|new-settled` replaces the cohort
///   (`new` installed today, `new-settled` installed three days ago).
/// - `KMGCCC_DEBUG_PROMPTS_FAST=1` shortens the listening threshold and the
///   prompt cooldown to a few seconds.
///
/// Switches that write prompt state act only inside a sandbox.
struct PromptDebugLaunchOptions {
    enum InstallHistorySeed: Equatable {
        case fresh
        case upgrade(from: AppBuild)
    }

    static let fastPlaybackSeconds: TimeInterval = 5
    static let fastCooldown: TimeInterval = 5
    private static let sandboxPrefix = "kmgccc.player.debug.prompts."

    var sandboxSuiteName: String?
    var installHistorySeed: InstallHistorySeed?
    var resetsState = false
    var fastMode = false
    var simulatedCohort: (cohort: UserCohort, installedDaysAgo: Int)?

    static let current = PromptDebugLaunchOptions(environment: ProcessInfo.processInfo.environment)

    init(environment: [String: String]) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if let name = environment["KMGCCC_DEBUG_PROMPTS_SANDBOX"], !name.isEmpty,
           name.unicodeScalars.allSatisfy(allowed.contains) {
            sandboxSuiteName = Self.sandboxPrefix + name
        }
        switch environment["KMGCCC_DEBUG_INSTALL_HISTORY"] {
        case "fresh":
            installHistorySeed = .fresh
        case let value? where value.hasPrefix("upgrade:"):
            installHistorySeed = AppBuild(from: String(value.dropFirst("upgrade:".count))).map { .upgrade(from: $0) }
        default:
            installHistorySeed = nil
        }
        resetsState = environment["KMGCCC_DEBUG_PROMPTS_RESET"] == "1"
        fastMode = environment["KMGCCC_DEBUG_PROMPTS_FAST"] == "1"
        switch environment["KMGCCC_DEBUG_COHORT"] {
        case "upgraded": simulatedCohort = (.upgraded, 0)
        case "new": simulatedCohort = (.newInstall, 0)
        case "new-settled": simulatedCohort = (.newInstall, 3)
        default: simulatedCohort = nil
        }
    }

    private var writesState: Bool {
        resetsState || installHistorySeed != nil || simulatedCohort != nil
    }

    /// Runs before the launch is recorded: empties the sandbox and seeds the
    /// install history.
    @MainActor
    func prepareBeforeLaunchRecord(history: AppInstallHistory) {
        guard let sandboxSuiteName else {
            if writesState {
                Log.warning(
                    "[PromptDebug] reset, install history and cohort switches need KMGCCC_DEBUG_PROMPTS_SANDBOX; ignored",
                    category: .ui
                )
            }
            return
        }
        if resetsState {
            PromptDefaults.store.removePersistentDomain(forName: sandboxSuiteName)
            Log.info("[PromptDebug] sandbox emptied", category: .ui)
        }
        switch installHistorySeed {
        case .fresh:
            history.seedForDebugging(lastLaunchedBuild: nil)
            WhatsNewConfig.seedLastSeenForDebugging(nil)
        case .upgrade(let build):
            history.seedForDebugging(lastLaunchedBuild: build)
            WhatsNewConfig.seedLastSeenForDebugging(build)
        case nil:
            break
        }
        if let installHistorySeed {
            Log.info("[PromptDebug] install history seeded: \(installHistorySeed)", category: .ui)
        }
    }

    /// Runs when the discovery engine is built.
    @MainActor
    func prepare(
        _ configuration: inout FeatureDiscoveryEngine.Configuration,
        coordinator: AppPromptCoordinator,
        cohortStore: UserCohortStore
    ) {
        if sandboxSuiteName != nil, let simulatedCohort {
            cohortStore.simulate(
                simulatedCohort.cohort, installedDaysAgo: simulatedCohort.installedDaysAgo, now: Date()
            )
        }
        if fastMode {
            configuration.playbackThresholdOverride = Self.fastPlaybackSeconds
            coordinator.cooldownDuration = Self.fastCooldown
        }
    }
}

/// The 调试 menu's prompt section.
struct PromptDebugCommands: Commands {
    @ObservedObject var appSession: AppSessionHost

    var body: some Commands {
        CommandMenu("调试") {
            Section("功能引导") {
                Button("立即预览引导卡片") {
                    appSession.featureDiscovery?.previewForDebugging()
                }
                Button("重置引导与提示") {
                    AppPromptCoordinator.shared.resetForDebugging()
                    FeatureTipStore.shared.resetForDebugging()
                    appSession.featureDiscovery?.resetForDebugging()
                }
                Button("快速模式：收听 5 秒、冷却 5 秒") {
                    AppPromptCoordinator.shared.cooldownDuration = PromptDebugLaunchOptions.fastCooldown
                    appSession.featureDiscovery?.configuration.playbackThresholdOverride =
                        PromptDebugLaunchOptions.fastPlaybackSeconds
                    appSession.featureDiscovery?.evaluate()
                }
            }
            Section("用户群") {
                Button("模拟升级用户") {
                    appSession.featureDiscovery?.simulateCohortForDebugging(.upgraded, installedDaysAgo: 0)
                }
                Button("模拟新用户：今天安装") {
                    appSession.featureDiscovery?.simulateCohortForDebugging(.newInstall, installedDaysAgo: 0)
                }
                Button("模拟新用户：安装满 3 天") {
                    appSession.featureDiscovery?.simulateCohortForDebugging(.newInstall, installedDaysAgo: 3)
                }
            }
        }
    }
}
#endif
