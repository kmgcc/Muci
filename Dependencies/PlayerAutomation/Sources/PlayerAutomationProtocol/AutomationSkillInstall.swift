import Darwin
import Foundation

/// Exports the Agent skill that ships inside the App bundle.
///
/// Settings shows the exported directory so users copy it into their Agent's
/// skill directory by hand, and `installPrompt` gives Agents a ready-made
/// instruction for doing the same.
public enum AutomationSkillInstaller {
    public static let skillName = "muci-automation"
    private static let legacySkillName = "kmgccc-player-automation"
    private static let legacyExecutableName = "player-automation"
    public static let fallbackBundleIdentifier = "kmgccc.player"

    public enum InstallError: Error, LocalizedError {
        case bundledSkillMissing
        case copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .bundledSkillMissing:
                return "The bundled agent skill is missing."
            case let .copyFailed(path):
                return "Could not write \(path)."
            }
        }
    }

    // MARK: - Locations

    /// The App bundle. The CLI lives at `Contents/Resources/Tools`, so the
    /// bundle is resolved from the executable path when the process is the CLI.
    public static var appBundleURL: URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL
        }
        var url = Bundle.main.executableURL
        url?.deleteLastPathComponent() // Tools
        url?.deleteLastPathComponent() // Resources
        url?.deleteLastPathComponent() // Contents
        url?.deleteLastPathComponent() // App
        guard let url, url.pathExtension == "app" else { return nil }
        return url
    }

    public static var bundleIdentifier: String {
        if let bundleURL = appBundleURL,
           let identifier = Bundle(url: bundleURL)?.bundleIdentifier {
            return identifier
        }
        if let executable = Bundle.main.executableURL,
           let identifier = exportedBundleIdentifier(executableURL: executable, supportRoot: applicationSupportRoot) {
            return identifier
        }
        return Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
    }

    private static var applicationSupportRoot: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static func supportDirectory() -> URL {
        applicationSupportRoot
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
    }

    static func exportedBundleIdentifier(executableURL: URL, supportRoot: URL) -> String? {
        let bin = executableURL.deletingLastPathComponent()
        let automation = bin.deletingLastPathComponent()
        let namespace = automation.deletingLastPathComponent()
        guard bin.lastPathComponent == "bin", automation.lastPathComponent == "Automation",
              namespace.deletingLastPathComponent().resolvingSymlinksInPath().path
                == supportRoot.resolvingSymlinksInPath().path
        else { return nil }
        return namespace.lastPathComponent
    }

    /// Stable directory users and Agents copy from. It survives App moves and
    /// is refreshed from the bundle by `syncExport`.
    public static func exportDirectory() -> URL {
        supportDirectory()
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skillName, isDirectory: true)
    }

    private static var executableDirectory: URL {
        supportDirectory().appendingPathComponent("bin", isDirectory: true)
    }

    public static func exportExecutableURL() -> URL {
        executableDirectory.appendingPathComponent("muci-automation")
    }

    public static var automationExecutableURL: URL? {
        if let bundleURL = appBundleURL {
            let candidate = bundleURL.appendingPathComponent(
                "Contents/Resources/Tools/player-automation"
            )
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        return Bundle.main.executableURL
    }

    public static func bundledSkillRoot() -> URL? {
        bundledSkillRoot(named: skillName)
    }

    private static func bundledSkillRoot(named skillName: String) -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(
                resources.appendingPathComponent("Skills/\(skillName)", isDirectory: true)
            )
        }
        if let bundleURL = appBundleURL {
            candidates.append(
                bundleURL.appendingPathComponent(
                    "Contents/Resources/Skills/\(skillName)",
                    isDirectory: true
                )
            )
        }
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path)
        }
    }

    // MARK: - Export

    /// Refresh the stable export directory from the App bundle.
    @discardableResult
    public static func syncExport(executableURL: URL) throws -> URL {
        guard let source = bundledSkillRoot(),
              let legacySource = bundledSkillRoot(named: legacySkillName) else {
            throw InstallError.bundledSkillMissing
        }
        let destination = exportDirectory()
        let legacyDestination = supportDirectory().appendingPathComponent("skill", isDirectory: true)
        try syncExecutableExport(executableURL: executableURL)
        try publish(at: destination) { try FileManager.default.copyItem(at: source, to: $0) }
        try publish(at: legacyDestination) { try FileManager.default.copyItem(at: legacySource, to: $0) }
        return destination
    }

    /// Refresh an already configured CLI before this App may change locations.
    public static func refreshExistingExecutableExport() throws {
        let legacy = executableDirectory.appendingPathComponent(legacyExecutableName)
        guard let executableURL = automationExecutableURL,
              FileManager.default.fileExists(atPath: legacy.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: legacy.path)) != nil
        else { return }
        try syncExecutableExport(executableURL: executableURL)
    }

    public static func syncExecutableExport(executableURL: URL) throws {
        try syncExecutableExport(executableURL: executableURL, in: executableDirectory)
    }

    static func syncExecutableExport(executableURL: URL, in directory: URL) throws {
        let manager = FileManager.default
        let installed = directory.appendingPathComponent(legacyExecutableName)
        let alias = directory.appendingPathComponent("muci-automation")
        // Earlier versions exported an absolute symlink into the bundle.
        // Publish the CLI itself so existing launch commands survive App moves.
        if (try? manager.destinationOfSymbolicLink(atPath: installed.path)) != nil
            || !manager.contentsEqual(atPath: installed.path, andPath: executableURL.path) {
            try publish(at: installed) { try manager.copyItem(at: executableURL, to: $0) }
        }
        if (try? manager.destinationOfSymbolicLink(atPath: alias.path)) != legacyExecutableName {
            try publish(at: alias) { temporary in
                try manager.createSymbolicLink(atPath: temporary.path, withDestinationPath: legacyExecutableName)
            }
        }
    }

    // MARK: - Prompt

    /// Instruction for Agents that install the skill themselves. It names the
    /// source and the CLI, and leaves the install location to the Agent, whose
    /// own tool decides where skills live.
    public static func installPrompt() -> String {
        """
        这是 Muci 的技能包，源目录保持原样，不要移动或改动：
        \(exportDirectory().path)

        装的时候按你所用工具的规则来：不同 Agent 的技能目录不一样，放到你的工具能加载的位置。优先建软链接而不是复制，播放器更新技能后会自动同步；一个工具只装一处，装完确认技能列表里出现 muci-automation。

        之后用 \(exportExecutableURL().path) 操作播放器。命令走本机自动化接口，播放器没在运行时会自动启动，超时重试一次即可；automation tools 不依赖播放器，可以先跑它确认通路。
        """
    }

    // MARK: - Files

    private static func publish(at destination: URL, prepare: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".export-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        try prepare(temporary)
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0
            || (errno == EEXIST && renamex_np(temporary.path, destination.path, UInt32(RENAME_SWAP)) == 0)
        else { throw InstallError.copyFailed(destination.path) }
    }
}
