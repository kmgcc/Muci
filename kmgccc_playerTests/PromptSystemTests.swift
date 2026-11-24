import CoreGraphics
import Foundation
@testable import kmgccc_player
import XCTest

// MARK: - Coordinator

@MainActor
final class AppPromptCoordinatorTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var presented: [String] = []

    private func makeCoordinator(launchHold: Bool = false) -> AppPromptCoordinator {
        AppPromptCoordinator(cooldownDuration: 60, startsInLaunchHold: launchHold) { [unowned self] in self.clock }
    }

    private func request(_ id: String, _ tier: AppPromptTier, accepts: Bool = true) -> AppPromptRequest {
        AppPromptRequest(id: AppPromptID(id), tier: tier) { [unowned self] in
            if accepts { self.presented.append(id) }
            return accepts
        }
    }

    func testLaunchHoldDefersUntilLaunchSequenceEnds() {
        let coordinator = makeCoordinator(launchHold: true)
        coordinator.submit(request("whatsNew", .release))
        XCTAssertTrue(presented.isEmpty)

        coordinator.endLaunchSequence()
        XCTAssertEqual(presented, ["whatsNew"])
    }

    func testPresentsByTierThenSubmissionOrder() {
        let coordinator = makeCoordinator(launchHold: true)
        coordinator.submit(request("tip", .contextualTip))
        coordinator.submit(request("discovery", .discovery))
        coordinator.submit(request("crash", .blocking))
        coordinator.submit(request("setup", .blocking))
        coordinator.endLaunchSequence()
        XCTAssertEqual(presented, ["crash"])

        coordinator.finish(AppPromptID("crash"))
        XCTAssertEqual(presented, ["crash", "setup"])
    }

    func testCooldownHoldsDiscoveryAndTipsButNotBlockingPrompts() {
        let coordinator = makeCoordinator()
        coordinator.submit(request("whatsNew", .release))
        coordinator.submit(request("discovery", .discovery))
        coordinator.submit(request("tip", .contextualTip))
        coordinator.finish(AppPromptID("whatsNew"))
        XCTAssertEqual(presented, ["whatsNew"])

        coordinator.submit(request("crash", .blocking))
        XCTAssertEqual(presented, ["whatsNew", "crash"])
        coordinator.finish(AppPromptID("crash"))

        clock += 61
        coordinator.drain()
        XCTAssertEqual(presented, ["whatsNew", "crash", "discovery"])

        // Closing a discovery prompt starts its own cooldown.
        coordinator.finish(AppPromptID("discovery"))
        XCTAssertEqual(presented.last, "discovery")
        clock += 61
        coordinator.drain()
        XCTAssertEqual(presented.last, "tip")
    }

    func testClosingATipStartsNoCooldown() {
        let coordinator = makeCoordinator()
        coordinator.submit(request("tipA", .contextualTip))
        coordinator.submit(request("tipB", .contextualTip))
        coordinator.finish(AppPromptID("tipA"))
        XCTAssertEqual(presented, ["tipA", "tipB"])
    }

    func testObstructionHoldsTheSlot() {
        let coordinator = makeCoordinator()
        coordinator.setObstruction(.settingsSheet, active: true)
        coordinator.submit(request("tip", .contextualTip))
        XCTAssertTrue(presented.isEmpty)
        XCTAssertTrue(coordinator.isWaiting(AppPromptID("tip")))

        coordinator.setObstruction(.settingsSheet, active: false)
        XCTAssertEqual(presented, ["tip"])
        XCTAssertTrue(coordinator.isActive(AppPromptID("tip")))
    }

    func testDeclinedPresentationReleasesTheSlot() {
        let coordinator = makeCoordinator(launchHold: true)
        coordinator.submit(request("stale", .release, accepts: false))
        coordinator.submit(request("tip", .contextualTip))
        coordinator.endLaunchSequence()
        XCTAssertEqual(presented, ["tip"])
        XCTAssertFalse(coordinator.isWaiting(AppPromptID("stale")))
    }

    func testFinishWithdrawsAWaitingRequest() {
        let coordinator = makeCoordinator(launchHold: true)
        coordinator.submit(request("tip", .contextualTip))
        coordinator.finish(AppPromptID("tip"))
        coordinator.endLaunchSequence()
        XCTAssertTrue(presented.isEmpty)
    }

    func testResubmittingReplacesTheQueuedRequest() {
        let coordinator = makeCoordinator(launchHold: true)
        coordinator.submit(request("tip", .contextualTip, accepts: false))
        coordinator.submit(request("tip", .contextualTip))
        coordinator.endLaunchSequence()
        XCTAssertEqual(presented, ["tip"])
    }
}

// MARK: - Feature discovery

@MainActor
private final class FakeDiscoveryEnvironment: DiscoveryEnvironment {
    var now = Date(timeIntervalSince1970: 2_000_000)
    var lastUserInteraction: Date?
    var onChange: (() -> Void)?

    var playback = DiscoveryPlaybackSample(trackKey: "track-1", isPlaying: true, position: 0)
    var hasLyrics = true
    var surface = DiscoverySurfaceState(
        isAppActive: true,
        isMainWindowVisible: true,
        mainWindowContentSize: CGSize(width: 1200, height: 800),
        isFullscreenActive: false,
        hasTransientUI: false
    )
    var availableSkins: Set<String> = ["user.zichao"]
    var selectedSkin = "default"
    var showingSkin: String?
    var performedActions: [DiscoveryAction] = []

    func playbackSample() -> DiscoveryPlaybackSample { playback }
    func currentTrackHasLyrics() -> Bool { hasLyrics }
    func surfaceState() -> DiscoverySurfaceState { surface }
    func isSkinAvailable(_ skinID: String) -> Bool { availableSkins.contains(skinID) }
    func isSkinSelected(_ skinID: String) -> Bool { selectedSkin == skinID }
    func isShowingSkin(_ skinID: String) -> Bool { showingSkin == skinID }
    func setInteractionTracking(_ enabled: Bool) {}

    func perform(_ action: DiscoveryAction) {
        performedActions.append(action)
        if case .enterEmbeddedFullscreen(let skinID) = action {
            selectedSkin = skinID
            showingSkin = skinID
        }
    }

    /// Plays for `seconds`, one evaluation per second.
    func play(_ seconds: Int, engine: FeatureDiscoveryEngine) {
        for _ in 0..<seconds {
            now += 1
            if playback.isPlaying { playback.position += 1 }
            engine.evaluate()
        }
    }
}

@MainActor
private final class FakeDiscoveryPresenter: FeatureDiscoveryPresenting {
    var presentedItems: [String] = []
    var dismissedItems: [String] = []
    var presentedCohort: UserCohort?
    private var onPrimary: (@MainActor () -> Void)?
    private var onDismiss: (@MainActor () -> Void)?

    func present(
        _ item: FeatureDiscoveryItem,
        cohort: UserCohort,
        onPrimary: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        presentedItems.append(item.id)
        presentedCohort = cohort
        self.onPrimary = onPrimary
        self.onDismiss = onDismiss
    }

    func dismiss(_ item: FeatureDiscoveryItem) {
        dismissedItems.append(item.id)
    }

    func tapPrimary() { onPrimary?() }
    func tapDismiss() { onDismiss?() }
}

@MainActor
final class FeatureDiscoveryEngineTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var environment: FakeDiscoveryEnvironment!
    private var presenter: FakeDiscoveryPresenter!
    private var coordinator: AppPromptCoordinator!

    override func setUp() async throws {
        suiteName = "PromptSystemTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        environment = FakeDiscoveryEnvironment()
        presenter = FakeDiscoveryPresenter()
        let environment = environment!
        coordinator = AppPromptCoordinator(cooldownDuration: 60, startsInLaunchHold: false) { environment.now }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private static func item(
        _ id: String = "skin.zichao.v1",
        priority: Int = 1,
        build: Int = 23,
        rule: DiscoveryCohortRule = .allUsers(newUserMinInstallDays: 3, newUserMinActiveDays: 2)
    ) -> FeatureDiscoveryItem {
        FeatureDiscoveryItem(
            id: id,
            introducedBuild: AppBuild(build),
            priority: priority,
            copy: FeatureDiscoveryCopy(
                featureName: "字潮",
                badgeForUpgradedUsers: "新皮肤",
                badgeForNewUsers: "精选皮肤",
                body: "正文",
                primaryButtonTitle: "进入",
                secondaryButtonTitle: "稍后"
            ),
            preview: .loopingVideo(
                resourceName: "clip", fileExtension: "mp4", posterName: "poster", posterExtension: "jpg"
            ),
            requiredPlaybackSeconds: 60,
            cohortRule: rule,
            requiresLyrics: true,
            action: .enterEmbeddedFullscreen(skinID: "user.zichao")
        )
    }

    private func makeEngine(
        catalog: [FeatureDiscoveryItem] = [item()],
        hasPriorInstallTraces: Bool = true
    ) -> FeatureDiscoveryEngine {
        var configuration = FeatureDiscoveryEngine.Configuration()
        configuration.catalog = catalog
        configuration.currentBuild = AppBuild(23)
        configuration.drivesTimers = false
        return FeatureDiscoveryEngine(
            configuration: configuration,
            store: FeatureDiscoveryStore(defaults: defaults),
            cohortStore: UserCohortStore(defaults: defaults),
            coordinator: coordinator,
            environment: environment,
            presenter: presenter,
            hasPriorInstallTraces: hasPriorInstallTraces
        )
    }

    // Stage one

    func testCountsOnlyListeningTime() {
        let engine = makeEngine()
        engine.start()
        environment.play(30, engine: engine)
        XCTAssertEqual(engine.record.playbackSeconds, 30, accuracy: 0.01)

        environment.playback.isPlaying = false
        environment.play(20, engine: engine)
        XCTAssertEqual(engine.record.playbackSeconds, 30, accuracy: 0.01)

        // A seek far ahead earns nothing.
        environment.playback.isPlaying = true
        engine.evaluate()
        environment.now += 1
        environment.playback.position += 120
        engine.evaluate()
        XCTAssertEqual(engine.record.playbackSeconds, 30, accuracy: 0.01)

        // A stalled position earns nothing either.
        environment.now += 5
        engine.evaluate()
        XCTAssertEqual(engine.record.playbackSeconds, 30, accuracy: 0.01)
        XCTAssertEqual(engine.record.phase, .accumulating)
    }

    func testTrackChangeEarnsNothingForTheJump() {
        let engine = makeEngine()
        engine.start()
        environment.play(10, engine: engine)
        environment.now += 1
        environment.playback = DiscoveryPlaybackSample(trackKey: "track-2", isPlaying: true, position: 0.5)
        engine.evaluate()
        XCTAssertEqual(engine.record.playbackSeconds, 10, accuracy: 0.01)
        environment.play(5, engine: engine)
        XCTAssertEqual(engine.record.playbackSeconds, 15, accuracy: 0.01)
    }

    func testListeningTimeCarriesAcrossLaunches() {
        let first = makeEngine()
        first.start()
        environment.play(40, engine: first)
        first.flush()
        XCTAssertTrue(presenter.presentedItems.isEmpty)

        let second = makeEngine()
        second.start()
        XCTAssertEqual(second.record.playbackSeconds, 40, accuracy: 0.01)
        environment.play(20, engine: second)
        XCTAssertEqual(presenter.presentedItems, ["skin.zichao.v1"])
        XCTAssertEqual(presenter.presentedCohort, .upgraded)
    }

    // Cohorts

    func testNewInstallWaitsUntilSettled() {
        let engine = makeEngine(hasPriorInstallTraces: false)
        engine.start()
        environment.play(70, engine: engine)
        XCTAssertEqual(engine.record.phase, .accumulating)
        XCTAssertTrue(presenter.presentedItems.isEmpty)

        environment.now += 3 * 86_400
        engine.evaluate()
        XCTAssertEqual(presenter.presentedItems, ["skin.zichao.v1"])
        XCTAssertEqual(presenter.presentedCohort, .newInstall)
    }

    func testCohortRule() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let rule = DiscoveryCohortRule.allUsers(newUserMinInstallDays: 3, newUserMinActiveDays: 2)
        let fresh = UserCohortProfile(cohort: .newInstall, firstLaunchDate: now, activeDayKeys: ["d1"])
        XCTAssertFalse(rule.isSatisfied(by: fresh, now: now))

        var returning = fresh
        returning.activeDayKeys = ["d1", "d2"]
        XCTAssertTrue(rule.isSatisfied(by: returning, now: now))
        XCTAssertTrue(rule.isSatisfied(by: fresh, now: now + 3 * 86_400))

        let upgraded = UserCohortProfile(cohort: .upgraded, firstLaunchDate: now, activeDayKeys: [])
        XCTAssertTrue(rule.isSatisfied(by: upgraded, now: now))
        XCTAssertFalse(DiscoveryCohortRule.upgradedUsersOnly.isSatisfied(by: fresh, now: now + 30 * 86_400))
    }

    func testCohortIsEstablishedOnce() {
        let store = UserCohortStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 5_000_000)
        store.establish(hasPriorInstallTraces: false, now: now)
        store.establish(hasPriorInstallTraces: true, now: now + 86_400)
        XCTAssertEqual(store.profile?.cohort, .newInstall)

        store.recordActiveDay(now + 86_400)
        store.recordActiveDay(now + 86_400)
        XCTAssertEqual(store.profile?.activeDayKeys.count, 2)
    }

    // Stage two

    func testGatePolicyHolds() {
        let policy = DiscoveryGatePolicy()
        let now = Date(timeIntervalSince1970: 5_000_000)
        let ready = DiscoverySurfaceState(
            isAppActive: true, isMainWindowVisible: true,
            mainWindowContentSize: CGSize(width: 1000, height: 700),
            isFullscreenActive: false, hasTransientUI: false
        )
        func hold(
            _ surface: DiscoverySurfaceState = ready,
            target: Bool = true, lyrics: Bool = true, interaction: Date? = nil
        ) -> DiscoveryHold? {
            policy.hold(
                surface: surface, targetAvailable: target, requiresLyrics: true,
                hasLyrics: lyrics, lastInteraction: interaction, now: now
            )
        }

        XCTAssertNil(hold())
        XCTAssertEqual(hold(target: false), .targetUnavailable)
        var surface = ready
        surface.isAppActive = false
        XCTAssertEqual(hold(surface), .appInactive)
        surface = ready
        surface.isMainWindowVisible = false
        XCTAssertEqual(hold(surface), .windowHidden)
        surface = ready
        surface.mainWindowContentSize = CGSize(width: 559, height: 700)
        XCTAssertEqual(hold(surface), .windowTooSmall)
        surface = ready
        surface.isFullscreenActive = true
        XCTAssertEqual(hold(surface), .fullscreenActive)
        surface = ready
        surface.hasTransientUI = true
        XCTAssertEqual(hold(surface), .transientUI)
        XCTAssertEqual(hold(lyrics: false), .lyricsMissing)
        XCTAssertEqual(hold(interaction: now - 1), .recentInteraction)
        XCTAssertNil(hold(interaction: now - 3))
    }

    func testArmedPromptWaitsForAQuietMoment() {
        let engine = makeEngine()
        engine.start()
        environment.hasLyrics = false
        environment.play(60, engine: engine)
        XCTAssertEqual(engine.record.phase, .armed)
        XCTAssertTrue(presenter.presentedItems.isEmpty)

        environment.hasLyrics = true
        environment.lastUserInteraction = environment.now
        engine.evaluate()
        XCTAssertTrue(presenter.presentedItems.isEmpty)

        environment.now += 3
        engine.evaluate()
        XCTAssertEqual(presenter.presentedItems, ["skin.zichao.v1"])
        XCTAssertEqual(engine.record.phase, .presenting)
    }

    func testDiscoveryWaitsOutTheCooldownAfterWhatsNew() {
        coordinator.submit(AppPromptRequest(id: .whatsNew, tier: .release) { true })
        let engine = makeEngine()
        engine.start()
        environment.play(60, engine: engine)
        XCTAssertTrue(presenter.presentedItems.isEmpty)

        coordinator.finish(.whatsNew)
        environment.play(30, engine: engine)
        XCTAssertTrue(presenter.presentedItems.isEmpty)

        environment.now += 31
        coordinator.drain()
        XCTAssertEqual(presenter.presentedItems, ["skin.zichao.v1"])
    }

    // Outcomes

    func testPrimaryActionCompletesReleasesSlotAndEntersTheSkin() {
        let engine = makeEngine()
        engine.start()
        environment.play(60, engine: engine)
        presenter.tapPrimary()

        XCTAssertEqual(engine.record.phase, .completed)
        XCTAssertFalse(coordinator.isActive(Self.item().promptID))
        XCTAssertEqual(presenter.dismissedItems, ["skin.zichao.v1"])
        XCTAssertEqual(environment.performedActions, [.enterEmbeddedFullscreen(skinID: "user.zichao")])
        XCTAssertEqual(FeatureDiscoveryStore(defaults: defaults).record(for: "skin.zichao.v1").phase, .completed)
    }

    func testDismissalIsFinal() {
        let engine = makeEngine()
        engine.start()
        environment.play(60, engine: engine)
        presenter.tapDismiss()
        XCTAssertEqual(engine.record.phase, .dismissed)
        XCTAssertTrue(environment.performedActions.isEmpty)

        let nextLaunch = makeEngine()
        nextLaunch.start()
        environment.play(120, engine: nextLaunch)
        XCTAssertNil(nextLaunch.candidate)
        XCTAssertEqual(presenter.presentedItems.count, 1)
    }

    func testUsingTheSkinUnpromptedCompletesDiscovery() {
        let engine = makeEngine()
        engine.start()
        environment.play(10, engine: engine)
        environment.selectedSkin = "user.zichao"
        engine.evaluate()
        XCTAssertEqual(engine.record.phase, .completed)
        environment.play(60, engine: engine)
        XCTAssertTrue(presenter.presentedItems.isEmpty)
    }

    func testInterruptedPresentationRetriesNextLaunch() {
        let engine = makeEngine()
        engine.start()
        environment.play(60, engine: engine)
        XCTAssertEqual(engine.record.phase, .presenting)

        let nextLaunch = makeEngine()
        XCTAssertEqual(FeatureDiscoveryStore(defaults: defaults).record(for: "skin.zichao.v1").phase, .armed)
        coordinator.finish(Self.item().promptID)
        environment.now += 61
        nextLaunch.start()
        XCTAssertEqual(presenter.presentedItems.count, 2)
    }

    func testOnlyTheTopItemOfABacklogSurvives() {
        let older = Self.item("skin.older.v1", priority: 0, build: 21)
        let newer = Self.item("skin.zichao.v1", priority: 1, build: 23)
        let future = Self.item("skin.future.v1", priority: 5, build: 30)
        let engine = makeEngine(catalog: [older, newer, future])
        engine.start()

        XCTAssertEqual(engine.candidate?.id, "skin.zichao.v1")
        let store = FeatureDiscoveryStore(defaults: defaults)
        XCTAssertEqual(store.record(for: "skin.older.v1").phase, .superseded)
        XCTAssertEqual(store.record(for: "skin.future.v1").phase, .pending)
    }
}

// MARK: - Install history and tips

@MainActor
final class FeatureTipStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "PromptSystemTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private static let newTip = FeatureTip(
        key: "test.newTip", introducedBuild: AppBuild(22), maxDisplayCount: 2, presentationDelay: .zero
    )
    private static let oldTip = FeatureTip(
        key: "test.oldTip", introducedBuild: AppBuild(16), maxDisplayCount: 2, presentationDelay: .zero
    )

    private func launch(_ build: Int) -> AppInstallHistory {
        let history = AppInstallHistory(defaults: defaults)
        history.recordLaunch(currentBuild: AppBuild(build))
        return history
    }

    func testInstallHistory() {
        let first = launch(21).currentLaunch
        XCTAssertEqual(first?.isFreshInstall, true)
        XCTAssertNil(first?.upgradedFromBuild)

        let relaunch = launch(21).currentLaunch
        XCTAssertEqual(relaunch?.isFreshInstall, false)
        XCTAssertNil(relaunch?.upgradedFromBuild)

        let upgrade = launch(23)
        XCTAssertEqual(upgrade.currentLaunch?.upgradedFromBuild, AppBuild(21))
        XCTAssertEqual(upgrade.installBaselineBuild, AppBuild(21))
    }

    func testFreshInstallSeesEveryTip() {
        let store = FeatureTipStore(defaults: defaults, installHistory: launch(23))
        XCTAssertTrue(store.isEligible(Self.oldTip))
        XCTAssertTrue(store.isEligible(Self.newTip))
    }

    func testUpgradedInstallSeesOnlyNewerTips() {
        _ = launch(20)
        let store = FeatureTipStore(defaults: defaults, installHistory: launch(23))
        XCTAssertFalse(store.isEligible(Self.oldTip))
        XCTAssertTrue(store.isEligible(Self.newTip))
    }

    func testDisplayBudget() {
        let history = launch(23)
        let store = FeatureTipStore(defaults: defaults, installHistory: history)
        store.recordDisplay(Self.newTip)
        XCTAssertFalse(store.isEligible(Self.newTip), "once per launch")

        let nextLaunch = FeatureTipStore(defaults: defaults, installHistory: history)
        XCTAssertTrue(nextLaunch.isEligible(Self.newTip))
        nextLaunch.recordDisplay(Self.newTip)
        XCTAssertFalse(FeatureTipStore(defaults: defaults, installHistory: history).isEligible(Self.newTip))

        let other = FeatureTipStore(defaults: defaults, installHistory: history)
        other.markDismissed(Self.oldTip)
        XCTAssertFalse(other.isEligible(Self.oldTip))
    }

    func testUpgradeResetsTipsIntroducedSinceThePreviousBuild() {
        let history = launch(21)
        let store = FeatureTipStore(defaults: defaults, installHistory: history)
        store.markDismissed(Self.newTip)
        store.markDismissed(Self.oldTip)

        let upgrade = launch(23)
        let upgraded = FeatureTipStore(defaults: defaults, installHistory: upgrade)
        upgraded.applyUpgrade(upgrade.currentLaunch!, tips: [Self.newTip, Self.oldTip])
        XCTAssertTrue(upgraded.isEligible(Self.newTip))
        XCTAssertFalse(upgraded.isEligible(Self.oldTip))
    }
}
