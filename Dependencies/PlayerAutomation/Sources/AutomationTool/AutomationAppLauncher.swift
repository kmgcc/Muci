import Foundation
import PlayerAutomationProtocol

enum AutomationAppLauncher {
    static func arguments(
        for appOverride: String?,
        bundleIdentifier: String = AutomationSkillInstaller.bundleIdentifier
    ) -> [String] {
        if let appOverride, !appOverride.isEmpty, appOverride != "kmgccc_player" {
            // The former stock path can disappear after an in-place update.
            let url = URL(fileURLWithPath: appOverride)
            if !appOverride.hasPrefix("/") ||
                url.lastPathComponent != "kmgccc_player.app" ||
                FileManager.default.fileExists(atPath: url.path) {
                return ["-a", appOverride]
            }
        }
        return ["-b", bundleIdentifier]
    }

    static func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments(for: ProcessInfo.processInfo.environment["KMGCCC_PLAYER_APP"])
        try process.run()
    }
}
