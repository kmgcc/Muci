//
//  FeatureDiscoveryEngine.swift
//  kmgccc_player
//
//  Two-stage trigger for feature discovery prompts.
//

import Foundation

/// Decides when a feature discovery prompt may appear.
///
/// Stage one counts real listening time: only while playback runs and the
/// position advances, across launches. Stage two waits, once the threshold and
/// the cohort rule are met, for a quiet moment: the prompt slot free, the main
/// window in front and large enough, no fullscreen or transient UI, lyrics on
/// the current track, and a short pause in the user's input.
///
/// At most one discovery prompt appears per launch. Older waiting items are
/// superseded by the newest one instead of queueing up.
@MainActor
final class FeatureDiscoveryEngine {
    struct Configuration {
        var catalog: [FeatureDiscoveryItem] = FeatureDiscoveryCatalog.items
        var currentBuild: AppBuild = .current
        var gatePolicy = DiscoveryGatePolicy()
        /// Listening time is written at least this often while it grows.
        var persistInterval: TimeInterval = 10
        var accumulationTickInterval: TimeInterval = 1
        var armedRetryInterval: TimeInterval = 5
        var eventDebounce: TimeInterval = 0.3
        /// Replaces every item's listening threshold (debug fast mode).
        var playbackThresholdOverride: TimeInterval?
        /// Live engines run their own timers; tests call `evaluate()`.
        var drivesTimers = true
    }

    private(set) var candidate: FeatureDiscoveryItem?
    private(set) var record = FeatureDiscoveryRecord.initial

    var configuration: Configuration
    private let store: FeatureDiscoveryStore
    private let cohortStore: UserCohortStore
    private let coordinator: AppPromptCoordinator
    private let environment: DiscoveryEnvironment
    private let presenter: FeatureDiscoveryPresenting
    private let hasPriorInstallTraces: Bool

    private var isStarted = false
    private var hasPresentedThisLaunch = false
    private var unsavedSeconds: TimeInterval = 0
    private var lastSample: (sample: DiscoveryPlaybackSample, time: Date)?
    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var pendingEvaluation: Task<Void, Never>?

    init(
        configuration: Configuration = Configuration(),
        store: FeatureDiscoveryStore,
        cohortStore: UserCohortStore,
        coordinator: AppPromptCoordinator,
        environment: DiscoveryEnvironment,
        presenter: FeatureDiscoveryPresenting,
        hasPriorInstallTraces: Bool
    ) {
        self.configuration = configuration
        self.store = store
        self.cohortStore = cohortStore
        self.coordinator = coordinator
        self.environment = environment
        self.presenter = presenter
        self.hasPriorInstallTraces = hasPriorInstallTraces
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let now = environment.now
        cohortStore.establish(hasPriorInstallTraces: hasPriorInstallTraces, now: now)
        cohortStore.recordActiveDay(now)
        selectCandidate()
        environment.onChange = { [weak self] in self?.scheduleEvaluation() }
        evaluate()
    }

    /// Writes listening time that has not been saved yet.
    func flush() {
        guard let candidate, unsavedSeconds > 0 else { return }
        store.save(record, for: candidate.id)
        unsavedSeconds = 0
    }

    /// Advances the state machine once. Timers and App events call it; tests
    /// call it directly.
    func evaluate() {
        guard isStarted, let item = candidate, !record.phase.isTerminal else {
            updateTimer()
            return
        }

        // The user found the feature on their own.
        let target = item.action.targetSkinID
        if record.phase != .presenting,
           environment.isShowingSkin(target) || environment.isSkinSelected(target) {
            conclude(item, as: .completed, reason: "already in use")
            return
        }

        switch record.phase {
        case .pending:
            record.phase = .accumulating
            store.save(record, for: item.id)
            accumulateAndArmIfReady(item)
        case .accumulating:
            accumulateAndArmIfReady(item)
        case .armed:
            requestPresentationIfAllowed(item)
        case .presenting, .completed, .dismissed, .superseded:
            break
        }
        updateTimer()
    }

    // MARK: - Stage one: listening time

    private func requiredSeconds(for item: FeatureDiscoveryItem) -> TimeInterval {
        configuration.playbackThresholdOverride ?? item.requiredPlaybackSeconds
    }

    private func accumulateAndArmIfReady(_ item: FeatureDiscoveryItem) {
        if record.playbackSeconds < requiredSeconds(for: item) {
            accumulatePlayback()
        }
        guard record.playbackSeconds >= requiredSeconds(for: item),
              let profile = cohortStore.profile,
              item.cohortRule.isSatisfied(by: profile, now: environment.now)
        else { return }
        record.phase = .armed
        store.save(record, for: item.id)
        unsavedSeconds = 0
        Log.info("[FeatureDiscovery] \(item.id) armed after \(Int(record.playbackSeconds))s", category: .ui)
        requestPresentationIfAllowed(item)
    }

    /// Credits wall time during which the position moved forward at roughly
    /// real speed. Pauses, stalls, seeks and track changes earn nothing.
    private func accumulatePlayback() {
        let sample = environment.playbackSample()
        let now = environment.now
        defer { lastSample = (sample, now) }
        guard let previous = lastSample else { return }

        let changedTrack = sample.trackKey != previous.sample.trackKey
        if changedTrack || (previous.sample.isPlaying && !sample.isPlaying) {
            flush()
        }
        guard !changedTrack, sample.trackKey != nil,
              previous.sample.isPlaying, sample.isPlaying
        else { return }

        let advanced = sample.position - previous.sample.position
        let elapsed = now.timeIntervalSince(previous.time)
        guard advanced > 0, elapsed > 0, advanced <= elapsed * 1.5 + 0.5 else { return }
        let credit = min(advanced, elapsed)
        record.playbackSeconds += credit
        unsavedSeconds += credit
        if unsavedSeconds >= configuration.persistInterval {
            flush()
        }
    }

    // MARK: - Stage two: a quiet moment

    private func currentHold(for item: FeatureDiscoveryItem) -> DiscoveryHold? {
        configuration.gatePolicy.hold(
            surface: environment.surfaceState(),
            targetAvailable: environment.isSkinAvailable(item.action.targetSkinID),
            requiresLyrics: item.requiresLyrics,
            hasLyrics: environment.currentTrackHasLyrics(),
            lastInteraction: environment.lastUserInteraction,
            now: environment.now
        )
    }

    private func requestPresentationIfAllowed(_ item: FeatureDiscoveryItem) {
        guard !hasPresentedThisLaunch,
              !coordinator.isActive(item.promptID),
              !coordinator.isWaiting(item.promptID),
              currentHold(for: item) == nil
        else { return }
        coordinator.submit(AppPromptRequest(id: item.promptID, tier: .discovery) { [weak self] in
            self?.presentIfStillAllowed() ?? false
        })
    }

    /// Runs when the coordinator hands over the slot, possibly after a cooldown,
    /// so every condition is checked again.
    private func presentIfStillAllowed() -> Bool {
        guard let item = candidate, record.phase == .armed, !hasPresentedThisLaunch else { return false }
        if let hold = currentHold(for: item) {
            Log.debug("[FeatureDiscovery] \(item.id) held: \(hold.rawValue)", category: .ui)
            return false
        }
        guard let profile = cohortStore.profile else { return false }
        record.phase = .presenting
        hasPresentedThisLaunch = true
        updateTimer()
        presenter.present(
            item,
            cohort: profile.cohort,
            onPrimary: { [weak self] in self?.handlePrimaryAction() },
            onDismiss: { [weak self] in self?.handleDismissal() }
        )
        Log.info("[FeatureDiscovery] \(item.id) presented", category: .ui)
        return true
    }

    private func handlePrimaryAction() {
        guard let item = candidate, record.phase == .presenting else { return }
        // Persist and release the slot first, select the target, then let the
        // card's exit and the scene's entry run in the same turn.
        conclude(item, as: .completed, reason: "primary action")
        presenter.dismiss(item)
        environment.perform(item.action)
    }

    private func handleDismissal() {
        guard let item = candidate, record.phase == .presenting else { return }
        conclude(item, as: .dismissed, reason: "dismissed")
        presenter.dismiss(item)
    }

    private func conclude(_ item: FeatureDiscoveryItem, as phase: FeatureDiscoveryPhase, reason: String) {
        record.phase = phase
        store.save(record, for: item.id)
        unsavedSeconds = 0
        coordinator.finish(item.promptID)
        updateTimer()
        Log.info("[FeatureDiscovery] \(item.id) \(phase.rawValue): \(reason)", category: .ui)
    }

    // MARK: - Candidate selection

    /// Keeps the highest-priority waiting item and supersedes the rest, so an
    /// upgrade across several releases shows one prompt instead of a backlog.
    private func selectCandidate() {
        let waiting = configuration.catalog
            .filter { $0.introducedBuild <= configuration.currentBuild }
            .map { (item: $0, record: store.record(for: $0.id)) }
            .filter { !$0.record.phase.isTerminal }
            .sorted { lhs, rhs in
                lhs.item.priority != rhs.item.priority
                    ? lhs.item.priority > rhs.item.priority
                    : lhs.item.introducedBuild > rhs.item.introducedBuild
            }
        for entry in waiting.dropFirst() {
            var superseded = entry.record
            superseded.phase = .superseded
            store.save(superseded, for: entry.item.id)
            Log.info("[FeatureDiscovery] \(entry.item.id) superseded", category: .ui)
        }
        candidate = waiting.first?.item
        record = waiting.first?.record ?? .initial
        lastSample = nil
        unsavedSeconds = 0
    }

    // MARK: - Scheduling

    private func scheduleEvaluation() {
        pendingEvaluation?.cancel()
        let delay = configuration.eventDebounce
        pendingEvaluation = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    /// Ticks while listening time is counted or while an armed prompt waits
    /// for its moment; idles otherwise and wakes on App events.
    private func updateTimer() {
        let waitsToPresent = record.phase == .armed && !hasPresentedThisLaunch
        environment.setInteractionTracking(waitsToPresent)

        var interval: TimeInterval?
        if let item = candidate, environment.playbackSample().isPlaying {
            switch record.phase {
            case .accumulating where record.playbackSeconds < requiredSeconds(for: item):
                interval = configuration.accumulationTickInterval
            case .armed where waitsToPresent && environment.surfaceState().isMainWindowVisible:
                interval = configuration.armedRetryInterval
            default:
                break
            }
        }
        guard configuration.drivesTimers, interval != timerInterval else { return }
        timer?.invalidate()
        timer = nil
        timerInterval = interval
        guard let interval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluate()
            }
        }
        timer?.tolerance = interval * 0.2
    }
}

// MARK: - Debug support

extension FeatureDiscoveryEngine {
    /// Clears discovery progress and re-reads the catalog.
    func resetForDebugging() {
        flush()
        if let candidate, record.phase == .presenting {
            presenter.dismiss(candidate)
            coordinator.finish(candidate.promptID)
        }
        for item in configuration.catalog {
            store.remove(itemID: item.id)
        }
        hasPresentedThisLaunch = false
        selectCandidate()
        evaluate()
    }

    /// Replaces the cohort profile and re-evaluates.
    func simulateCohortForDebugging(_ cohort: UserCohort, installedDaysAgo: Int) {
        cohortStore.simulate(cohort, installedDaysAgo: installedDaysAgo, now: environment.now)
        evaluate()
    }

    /// Shows the first catalog item now, skipping every gate. Nothing is persisted.
    func previewForDebugging() {
        guard let item = candidate ?? configuration.catalog.first else { return }
        let cohort = cohortStore.profile?.cohort ?? .upgraded
        presenter.present(
            item,
            cohort: cohort,
            onPrimary: { [weak self] in
                self?.presenter.dismiss(item)
                self?.environment.perform(item.action)
            },
            onDismiss: { [weak self] in self?.presenter.dismiss(item) }
        )
    }
}
