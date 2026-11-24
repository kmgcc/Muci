import Foundation

/// The registry owns existing paths. These locations are used for adoption and creation.
nonisolated enum LibraryLocationStore {
    private static var musicDirectory: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static var defaultLibraryRootURL: URL {
        #if DEBUG
        if let root = DebugLibraryIsolation.rootURL { return root.appendingPathComponent("Library", isDirectory: true) }
        #endif
        return musicDirectory.appendingPathComponent(LibraryPaths.rootDirectoryName, isDirectory: true)
    }

    static var factoryDefaultRootURLs: [URL] {
        #if DEBUG
        if DebugLibraryIsolation.rootURL != nil { return [defaultLibraryRootURL] }
        #endif
        return [
            musicDirectory.appendingPathComponent(LibraryPaths.legacyRootDirectoryName, isDirectory: true),
            defaultLibraryRootURL
        ]
    }

    static func existingFactoryDefaultRoot(in candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
