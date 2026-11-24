//
//  FeatureDiscoveryStore.swift
//  kmgccc_player
//
//  Persisted progress of each feature discovery item.
//

import Foundation

enum FeatureDiscoveryPhase: String, Codable, Sendable {
    /// Registered, not yet counting.
    case pending
    /// Counting playback toward the threshold.
    case accumulating
    /// Ready; waits for a quiet, suitable moment.
    case armed
    /// On screen. Stored as `armed`, so an interrupted presentation retries.
    case presenting
    /// The user tried the feature, from the prompt or on their own.
    case completed
    /// The user closed the prompt.
    case dismissed
    /// A newer item replaced this one before it was shown.
    case superseded

    var isTerminal: Bool {
        switch self {
        case .completed, .dismissed, .superseded: true
        case .pending, .accumulating, .armed, .presenting: false
        }
    }
}

struct FeatureDiscoveryRecord: Codable, Equatable, Sendable {
    var phase: FeatureDiscoveryPhase
    var playbackSeconds: TimeInterval

    static let initial = FeatureDiscoveryRecord(phase: .pending, playbackSeconds: 0)
}

@MainActor
final class FeatureDiscoveryStore {
    private static let keyPrefix = "kmgccc_player.featureDiscovery.item."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = PromptDefaults.store) {
        self.defaults = defaults
    }

    func record(for itemID: String) -> FeatureDiscoveryRecord {
        guard let data = defaults.data(forKey: Self.keyPrefix + itemID),
              var record = try? JSONDecoder().decode(FeatureDiscoveryRecord.self, from: data)
        else { return .initial }
        if record.phase == .presenting { record.phase = .armed }
        return record
    }

    func save(_ record: FeatureDiscoveryRecord, for itemID: String) {
        var stored = record
        if stored.phase == .presenting { stored.phase = .armed }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.keyPrefix + itemID)
    }

    func remove(itemID: String) {
        defaults.removeObject(forKey: Self.keyPrefix + itemID)
    }
}
