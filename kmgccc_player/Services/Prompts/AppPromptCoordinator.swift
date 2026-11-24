//
//  AppPromptCoordinator.swift
//  kmgccc_player
//
//  The single exit for prompts the App shows on its own initiative.
//

import Foundation

/// Owns the one slot that App-initiated prompts share.
///
/// - At most one managed prompt is visible at a time.
/// - Waiting requests present by tier, then in submission order.
/// - Closing a blocking, release or discovery prompt starts a cooldown;
///   discovery prompts and contextual tips wait it out, so a new prompt never
///   follows right behind the one the user just closed.
/// - The coordinator starts in the launch hold. The launch sequence submits
///   its prompts and then calls `endLaunchSequence()`.
@MainActor
final class AppPromptCoordinator {
    static let shared = AppPromptCoordinator()

    static let defaultCooldown: TimeInterval = 60

    struct ActivePrompt: Equatable {
        let id: AppPromptID
        let tier: AppPromptTier
    }

    private(set) var activePrompt: ActivePrompt?
    /// Seconds that discovery prompts and tips wait after a larger prompt closes.
    var cooldownDuration: TimeInterval

    private var queue: [AppPromptRequest] = []
    private var obstructions: Set<AppPromptObstruction>
    private var cooldownEndsAt: Date?
    private var cooldownWakeTask: Task<Void, Never>?
    private var isDraining = false
    private let now: () -> Date

    init(
        cooldownDuration: TimeInterval = AppPromptCoordinator.defaultCooldown,
        startsInLaunchHold: Bool = true,
        now: @escaping () -> Date = Date.init
    ) {
        self.cooldownDuration = cooldownDuration
        self.obstructions = startsInLaunchHold ? [.launchSequence] : []
        self.now = now
    }

    func submit(_ request: AppPromptRequest) {
        guard activePrompt?.id != request.id else { return }
        if let index = queue.firstIndex(where: { $0.id == request.id }) {
            queue[index] = request
        } else {
            queue.append(request)
        }
        drain()
    }

    func withdraw(_ id: AppPromptID) {
        queue.removeAll { $0.id == id }
    }

    /// Ends the visible prompt `id`, or withdraws it if it is still waiting.
    func finish(_ id: AppPromptID) {
        guard let active = activePrompt, active.id == id else {
            withdraw(id)
            return
        }
        activePrompt = nil
        if active.tier.startsCooldown {
            cooldownEndsAt = now().addingTimeInterval(cooldownDuration)
        }
        Log.debug("[Prompts] finished \(id)", category: .ui)
        drain()
    }

    func setObstruction(_ obstruction: AppPromptObstruction, active: Bool) {
        if active {
            obstructions.insert(obstruction)
        } else {
            obstructions.remove(obstruction)
            drain()
        }
    }

    func endLaunchSequence() {
        setObstruction(.launchSequence, active: false)
    }

    func isActive(_ id: AppPromptID) -> Bool {
        activePrompt?.id == id
    }

    func isWaiting(_ id: AppPromptID) -> Bool {
        queue.contains { $0.id == id }
    }

    /// Presents the next eligible request if the slot allows it now. The
    /// coordinator calls this itself; tests with an injected clock call it
    /// after moving time forward.
    func drain() {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while activePrompt == nil, obstructions.isEmpty, let index = nextRequestIndex() {
            let request = queue[index]
            if request.tier.waitsForCooldown, let end = cooldownEndsAt, now() < end {
                scheduleCooldownWake(at: end)
                return
            }
            queue.remove(at: index)
            // Claim the slot before presenting, so a presenter that submits or
            // finishes synchronously sees a consistent state.
            let claim = ActivePrompt(id: request.id, tier: request.tier)
            activePrompt = claim
            if request.present() {
                if activePrompt == claim {
                    Log.debug("[Prompts] presented \(request.id)", category: .ui)
                }
            } else if activePrompt == claim {
                activePrompt = nil
            }
        }
    }

    /// Clears the cooldown and queued requests. Debug tools only.
    func resetForDebugging() {
        queue.removeAll()
        cooldownEndsAt = nil
        cooldownWakeTask?.cancel()
        cooldownWakeTask = nil
    }

    private func nextRequestIndex() -> Int? {
        // `min(by:)` keeps the first of equal elements, preserving FIFO order
        // within a tier.
        queue.indices.min { queue[$0].tier < queue[$1].tier }
    }

    private func scheduleCooldownWake(at date: Date) {
        guard cooldownWakeTask == nil else { return }
        let delay = max(0, date.timeIntervalSince(now()))
        cooldownWakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.cooldownWakeTask = nil
            self.drain()
        }
    }
}
