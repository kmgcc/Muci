import XCTest
@testable import kmgccc_player

/// The automation-facing lyrics status memo must survive repeated reads with
/// unchanged lyric inputs and drop on any lyrics mutation — deriving the
/// status regexes the whole TTML document, so a missed invalidation would
/// report a stale wordSynced/lineSynced state to automation clients.
@MainActor
final class TrackLyricsStatusMemoTests: XCTestCase {
    func testMemoSurvivesRepeatedReadsWithUnchangedInputs() {
        let track = Track(
            title: "秦皇岛",
            fileBookmarkData: Data(),
            ttmlLyricText: "<tt><body><p>line</p></body></tt>"
        )
        var computeCount = 0
        let first = track.memoizedLyricsStatus {
            computeCount += 1
            return "wordSynced"
        }
        XCTAssertEqual(first, "wordSynced")
        XCTAssertEqual(track.memoizedLyricsStatus(compute: failCompute), "wordSynced")
        XCTAssertEqual(computeCount, 1)
    }

    func testWritingTTMLTextDropsMemo() {
        let track = Track(title: "t", fileBookmarkData: Data())
        XCTAssertEqual(track.memoizedLyricsStatus { "none" }, "none")
        track.ttmlLyricText = "<tt><body><p>a</p></body></tt>"
        XCTAssertEqual(track.memoizedLyricsStatus { "lineSynced" }, "lineSynced")
        // Re-assigning even the same text must drop the memo again.
        track.ttmlLyricText = "<tt><body><p>a</p></body></tt>"
        XCTAssertEqual(track.memoizedLyricsStatus { "wordSynced" }, "wordSynced")
    }

    func testWritingPlainLyricsTextDropsMemo() {
        let track = Track(title: "t", fileBookmarkData: Data())
        XCTAssertEqual(track.memoizedLyricsStatus { "plain" }, "plain")
        track.lyricsText = "[00:01.00] line"
        XCTAssertEqual(track.memoizedLyricsStatus { "lineSynced" }, "lineSynced")
    }

    func testLyricsFileNameChangeDropsMemoViaKeyMismatch() {
        let track = Track(
            title: "t",
            fileBookmarkData: Data(),
            lyricsFileName: "lyrics.lrc"
        )
        XCTAssertEqual(track.memoizedLyricsStatus { "lineSynced" }, "lineSynced")
        track.lyricsFileName = "notes.txt"
        XCTAssertEqual(track.memoizedLyricsStatus { "plain" }, "plain")
    }

    func testTransientReleaseDropsMemo() {
        let track = Track(
            title: "t",
            fileBookmarkData: Data(),
            ttmlLyricText: "<tt><body><p>a</p></body></tt>"
        )
        XCTAssertEqual(track.memoizedLyricsStatus { "wordSynced" }, "wordSynced")
        track.releaseTransientMediaResources()
        XCTAssertEqual(track.memoizedLyricsStatus { "none" }, "none")
    }

    private func failCompute() -> String {
        XCTFail("memoized status must be returned without recomputing")
        return "none"
    }
}
