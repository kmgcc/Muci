import Darwin
import Foundation

/// The old Sparkle installer replaces the App at its original path. The new
/// App can hand off that path before opening its library or starting services.
enum InstallNameMigration {
    static func handOffIfNeeded(bundle: Bundle = .main) -> Bool {
        #if DEBUG
        return false
        #else
        guard bundle.bundleIdentifier == "kmgccc.player",
              bundle.bundleURL.lastPathComponent == "kmgccc_player.app",
              bundle.object(forInfoDictionaryKey: "KMGUpdateReleaseChannel") as? String == "production",
              !ProcessInfo.processInfo.arguments.contains("--skip-install-name-migration")
        else { return false }

        let helper = Process()
        let ready = Pipe()
        let confirm = Pipe()
        helper.executableURL = bundle.bundleURL.appendingPathComponent("Contents/Helpers/muci-install-migration")
        helper.arguments = [bundle.bundleURL.path]
        helper.standardOutput = ready
        helper.standardInput = confirm
        let reader = ready.fileHandleForReading
        let writer = confirm.fileHandleForWriting
        defer {
            try? reader.close()
            try? writer.close()
        }
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { return false }
        do {
            try helper.run()
        } catch {
            return false
        }
        var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var response: UInt8 = 0
        guard poll(&descriptor, 1, 4_000) == 1,
              descriptor.revents & Int16(POLLIN) != 0,
              read(reader.fileDescriptor, &response, 1) == 1,
              response == 49
        else { return false }
        return write(writer.fileDescriptor, &response, 1) == 1
        #endif
    }
}
