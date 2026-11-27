import AVFoundation
import SwiftData
import XCTest
@testable import kmgccc_player

/// The automation metadata patch must converge the visible library state
/// (section grouping, refresh trigger) through the repository's in-memory
/// snapshot instead of a full disk rescan, and must re-read tracks from disk
/// when their sidecar write failed so disk stays authoritative.
@MainActor
final class LibraryAutomationPatchRefreshTests: XCTestCase {
    func testBatchMetadataPatchConvergesVisibleStateWithoutFullReload() async throws {
        let fixture = try makeFixture(initialFileCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let previousDeferred = AppSettings.shared.deferImportEnrichment
        AppSettings.shared.deferImportEnrichment = true
        defer { AppSettings.shared.deferImportEnrichment = previousDeferred }

        let host = try makeHost(registryURL: fixture.registryURL)
        let entries = LibraryImportSourceEntry.makeEntries(from: [fixture.sourceRoot])
        _ = try await host.createMusicLibrary(
            mode: .managed,
            parentURL: fixture.libraryParent,
            displayName: "Automation Patch Refresh",
            initialImportSelection: LibraryInitialImportSelection(
                urls: [fixture.sourceRoot],
                playlistSourceEntries: entries
            )
        )
        let session = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        let vm = session.libraryViewModel
        guard case .loaded = vm.state else {
            return XCTFail("session VM should be loaded after library creation, got \(vm.state)")
        }

        let tracksBefore = await session.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracksBefore.count, 2)
        let generationBefore = vm.loadGeneration
        let triggerBefore = vm.refreshTrigger

        let newArtist = "Automation Patch Artist 甲"
        let outcome = try await vm.applyMetadataPatchForAutomation(
            trackIDs: tracksBefore.map(\.id),
            patch: makePatch(artist: newArtist, description: "批量描述")
        )

        XCTAssertEqual(Set(outcome.updatedTrackIDs), Set(tracksBefore.map(\.id)))
        XCTAssertTrue(outcome.skippedTrackIDs.isEmpty)
        XCTAssertTrue(outcome.conflictedTrackIDs.isEmpty)
        for track in vm.allTracks {
            XCTAssertEqual(track.userDescription, "批量描述")
            XCTAssertEqual(track.artist, newArtist)
        }

        // Section grouping must have converged to the new artist in memory.
        XCTAssertEqual(
            vm.runtimeArtists.map(\.key),
            [LibraryNormalization.normalizeArtist(newArtist)]
        )

        XCTAssertEqual(
            vm.loadGeneration,
            generationBefore,
            "metadata patch must converge without a full library reload"
        )
        XCTAssertGreaterThan(vm.refreshTrigger, triggerBefore)

        await session.quiesce()
        await session.close()
    }

    func testMetadataPatchBumpsLibraryContentEpoch() async throws {
        let fixture = try makeFixture(initialFileCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let previousDeferred = AppSettings.shared.deferImportEnrichment
        AppSettings.shared.deferImportEnrichment = true
        defer { AppSettings.shared.deferImportEnrichment = previousDeferred }

        let host = try makeHost(registryURL: fixture.registryURL)
        let entries = LibraryImportSourceEntry.makeEntries(from: [fixture.sourceRoot])
        _ = try await host.createMusicLibrary(
            mode: .managed,
            parentURL: fixture.libraryParent,
            displayName: "Automation Patch Epoch",
            initialImportSelection: LibraryInitialImportSelection(
                urls: [fixture.sourceRoot],
                playlistSourceEntries: entries
            )
        )
        let session = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        let vm = session.libraryViewModel

        // Reading library content alone must not bump the epoch: the
        // Automation revision cache relies on it as a change signal.
        let epochAfterLoad = vm.libraryContentEpoch
        _ = vm.allTracks.count
        _ = vm.playlists.count
        XCTAssertEqual(vm.libraryContentEpoch, epochAfterLoad)

        let outcome = try await vm.applyMetadataPatchForAutomation(
            trackIDs: vm.allTracks.map(\.id),
            patch: makePatch(artist: "Epoch Artist 甲")
        )
        XCTAssertEqual(outcome.conflictedTrackIDs.isEmpty, true)
        XCTAssertFalse(outcome.updatedTrackIDs.isEmpty)
        XCTAssertGreaterThan(vm.libraryContentEpoch, epochAfterLoad)

        // The in-place auxiliary broadcast (no array reassignment) must bump
        // the epoch too — in-place Track mutations bypass the didSet signal.
        let epochBeforeNotify = vm.libraryContentEpoch
        vm.notifyTrackAuxiliaryDataChanged(trackIDs: [vm.allTracks[0].id])
        XCTAssertGreaterThan(vm.libraryContentEpoch, epochBeforeNotify)

        await session.quiesce()
        await session.close()
    }

    func testMetadataPatchReReadsFailedSidecarFromDisk() async throws {
        let fixture = try makeFixture(initialFileCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let previousDeferred = AppSettings.shared.deferImportEnrichment
        AppSettings.shared.deferImportEnrichment = true
        defer { AppSettings.shared.deferImportEnrichment = previousDeferred }

        let host = try makeHost(registryURL: fixture.registryURL)
        let entries = LibraryImportSourceEntry.makeEntries(from: [fixture.sourceRoot])
        _ = try await host.createMusicLibrary(
            mode: .managed,
            parentURL: fixture.libraryParent,
            displayName: "Automation Patch Failure Re-read",
            initialImportSelection: LibraryInitialImportSelection(
                urls: [fixture.sourceRoot],
                playlistSourceEntries: entries
            )
        )
        let session = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        let vm = session.libraryViewModel
        guard case .loaded = vm.state else {
            return XCTFail("session VM should be loaded after library creation, got \(vm.state)")
        }

        let tracksForFailureTest = await session.repository.fetchTracks(in: nil)
        let track = try XCTUnwrap(tracksForFailureTest.first)
        let originalDescription = track.userDescription

        // A read-only track folder makes the atomic sidecar write fail.
        let trackFolder = session.context.paths.trackFolderURL(for: track.id)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: trackFolder.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: trackFolder.path
            )
        }

        let outcome = try await vm.applyMetadataPatchForAutomation(
            trackIDs: [track.id],
            patch: makePatch(description: "不应生效的描述")
        )

        XCTAssertTrue(outcome.updatedTrackIDs.isEmpty)
        XCTAssertEqual(outcome.skippedTrackIDs, [track.id])
        // Disk stays authoritative: the failed in-memory change is re-read
        // back from the untouched sidecar instead of lingering until the
        // next full reload.
        let trackAfter = try XCTUnwrap(vm.allTracks.first { $0.id == track.id })
        XCTAssertEqual(trackAfter.userDescription, originalDescription)
        XCTAssertNotEqual(trackAfter.userDescription, "不应生效的描述")

        await session.quiesce()
        await session.close()
    }

    // MARK: - Harness (mirrors LibraryReimportGrowthIntegrationTests)

    private struct Fixture {
        let root: URL
        let sourceRoot: URL
        let libraryParent: URL
        let registryURL: URL
    }

    private func makeFixture(initialFileCount: Int) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let libraryParent = root.appendingPathComponent("Library Parent", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libraryParent, withIntermediateDirectories: true)
        for index in 1...initialFileCount {
            try writeWAV(to: sourceRoot.appendingPathComponent("\(index).wav"))
        }
        return Fixture(
            root: root,
            sourceRoot: sourceRoot,
            libraryParent: libraryParent,
            registryURL: root.appendingPathComponent("registry.json")
        )
    }

    private func makeHost(registryURL: URL) throws -> AppSessionHost {
        let schema = Schema([TrackIndexEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let host = AppSessionHost(
            modelContainer: container,
            initialLibraryContext: nil,
            registryStore: try kmgccc_player.MusicLibraryRegistryStore(fileURL: registryURL),
            sessionFactory: LibrarySessionFactory()
        )
        // Session-bound source scans borrow slots from the App scheduler.
        // These fixtures bypass setupDependencies(), which starts it in the App.
        host.backgroundWorkScheduler.start()
        return host
    }

    private func writeWAV(to url: URL, sampleValue: Float = 0) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        )
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)
        )
        buffer.frameLength = 4_410
        if let channelData = buffer.floatChannelData?[0] {
            for frame in 0..<Int(buffer.frameLength) {
                channelData[frame] = sampleValue
            }
        }
        try audioFile.write(from: buffer)
    }

    private func makePatch(
        artist: String? = nil,
        description: String? = nil
    ) -> LibraryAutomationMetadataPatch {
        var fields: Set<String> = []
        if artist != nil { fields.insert("artist") }
        if description != nil { fields.insert("description") }
        return LibraryAutomationMetadataPatch(
            fields: fields,
            title: nil,
            artist: artist,
            album: nil,
            albumArtist: nil,
            userDescription: description,
            genreTags: nil,
            language: nil,
            labelOrCompany: nil,
            releaseDate: nil,
            qqMusicSongMid: nil,
            metadataSource: nil,
            metadataFetchedAt: nil,
            metadataConfidence: nil,
            musicBrainzReleaseID: nil,
            lyricsTimeOffsetMs: nil,
            artistCredits: nil
        )
    }
}
