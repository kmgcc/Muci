import Foundation
import Testing
@testable import AutomationTool
@testable import PlayerAutomationProtocol

@Test func bothExportedCommandsSurviveMovingTheBundle() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    let oldBundle = root.appendingPathComponent("kmgccc_player.app")
    let bin = root.appendingPathComponent("kmgccc.player/Automation/bin")
    try manager.createDirectory(at: oldBundle, withIntermediateDirectories: true)
    try manager.createDirectory(at: bin, withIntermediateDirectories: true)
    let packaged = oldBundle.appendingPathComponent("player-automation")
    let oldCommand = bin.appendingPathComponent("player-automation")
    let newCommand = bin.appendingPathComponent("muci-automation")
    let script = Data("#!/bin/sh\nexit 0\n".utf8)
    try script.write(to: packaged)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packaged.path)
    try manager.createSymbolicLink(at: oldCommand, withDestinationURL: packaged)

    try AutomationSkillInstaller.syncExecutableExport(executableURL: packaged, in: bin)
    try manager.moveItem(at: oldBundle, to: root.appendingPathComponent("Muci.app"))

    #expect(try Data(contentsOf: oldCommand) == script)
    #expect(try Data(contentsOf: newCommand) == script)
    #expect(manager.isExecutableFile(atPath: oldCommand.path))
    #expect(manager.isExecutableFile(atPath: newCommand.path))
}

@Test func automationLaunchKeepsLegacyOverrideAndTestNamespace() {
    let support = URL(fileURLWithPath: "/tmp/application-support", isDirectory: true)
    let cli = support.appendingPathComponent("kmgccc.player.test/Automation/bin/muci-automation")
    let identifier = AutomationSkillInstaller.exportedBundleIdentifier(executableURL: cli, supportRoot: support)
    #expect(identifier == "kmgccc.player.test")
    #expect(AutomationAppLauncher.arguments(for: nil, bundleIdentifier: identifier ?? "") == ["-b", "kmgccc.player.test"])
    #expect(AutomationAppLauncher.arguments(for: "kmgccc_player", bundleIdentifier: "kmgccc.player") == ["-b", "kmgccc.player"])
    #expect(AutomationAppLauncher.arguments(for: "Other App", bundleIdentifier: "kmgccc.player") == ["-a", "Other App"])
}
