import Foundation
import SwiftUI

@MainActor
final class SkinSceneRuntimeMetrics {
    static let shared = SkinSceneRuntimeMetrics()
    struct Record { var nodes: Int; var frames: UInt64 = 0; var audioReaders: Int = 0 }
    /// One GPU layer's frame pacing since its scene mounted. Times in seconds.
    struct Pacing {
        var frames: UInt64 = 0
        /// Frames that came more than one and a half display frames after the previous one.
        var late: UInt64 = 0
        /// Ticks skipped because the previous frame still waited for its drawable.
        var skipped: UInt64 = 0
        var worstGap = 0.0
        var waitTotal = 0.0
        var worstWait = 0.0
        /// Presents that waited more than 4 ms for a drawable.
        var longWaits: UInt64 = 0
    }
    private(set) var records: [String: Record] = [:]
    /// Keyed by the scene's metrics ID, a slash, and the layer node's ID.
    private(set) var pacing: [String: Pacing] = [:]
    func mount(_ id: String, nodes: Int) {
        records[id] = Record(nodes: nodes)
        pacing = pacing.filter { !$0.key.hasPrefix(id + "/") }
    }
    func unmount(_ id: String) {
        records.removeValue(forKey: id)
        pacing = pacing.filter { !$0.key.hasPrefix(id + "/") }
    }
    func frame(_ id: String, audioReaders: Int) { records[id]?.frames &+= 1; records[id]?.audioReaders = audioReaders }
    func pace(_ key: String, _ update: (inout Pacing) -> Void) { update(&pacing[key, default: Pacing()]) }
}

extension EnvironmentValues {
    @Entry var skinSceneMetricsID = ""
}
