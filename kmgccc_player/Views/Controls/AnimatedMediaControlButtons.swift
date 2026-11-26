//
//  AnimatedMediaControlButtons.swift
//  myPlayer2
//
//  kmgccc_player - Shared animated media control buttons for the Window Mini
//  Player and the Fullscreen Mini Player. Single implementation, two size
//  profiles. State motion uses MotionKit semantic tokens; the three-arrow
//  relay keeps its staged choreography while using the same Apple spring
//  vocabulary as the other control states.
//
//  Play/pause motion is driven by SwiftUI system springs; the skip relay runs
//  as Core Animation keyframes sampled from the same MotionKit springs, so a
//  busy main thread during the track switch never stops it. No per-frame
//  timers, no display links. Idle cost is zero.
//

import AppKit
import CoreImage
import MotionKit
import SwiftUI

// MARK: - Metrics

/// Lightweight size profile shared by every animated media control.
/// Hit targets and visual symbol sizes are deliberately separate: the hit
/// area stays generous even when the painted symbol is small.
struct AnimatedMediaControlMetrics: Equatable, Sendable {
    /// Square hit target (clickable area), points.
    var hitSize: CGFloat
    /// Side of the square stage the play/pause symbol is drawn into.
    var playSymbolSize: CGFloat
    /// Side of the square stage the skip (previous/next) arrows occupy.
    var navSymbolSize: CGFloat

    /// One arrow-lane pitch in the demo's 134-unit viewBox (arrows sit 40 apart).
    var navLaneWidth: CGFloat { navSymbolSize * (40 / 134) }
    /// Standby arrow entry inset (demo uses -15 units).
    var navStandbyEnterOffset: CGFloat { navSymbolSize * (15 / 134) }

    /// Window Mini Player: original 26 pt hit targets. Play stays the visual
    /// anchor; the skip stage is larger than the play stage because the demo
    /// arrows only fill ~60% of their viewBox.
    static let windowMiniPlayer = AnimatedMediaControlMetrics(
        hitSize: 26,
        playSymbolSize: 18,
        navSymbolSize: 28
    )

    /// Fullscreen Mini Player: derived from the responsive bar scale so it
    /// tracks the existing `controlSize` hit footprint exactly.
    static func fullscreenMiniPlayer(scale: CGFloat) -> AnimatedMediaControlMetrics {
        AnimatedMediaControlMetrics(
            hitSize: 36 * scale,
            playSymbolSize: 20 * scale,
            navSymbolSize: 35 * scale
        )
    }
}

// MARK: - Shared press/cancel/release hit area

/// Owns the pointer lifecycle shared by all media buttons:
/// - press while the pointer is inside,
/// - cancel the whole session once the pointer leaves (no command fires),
/// - release while still inside commits the action.
private struct AnimatedControlHitArea<Content: View>: View {
    let hitSize: CGFloat
    let enabled: Bool
    let label: Text
    let content: Content
    let onPress: () -> Void
    let onCancel: () -> Void
    let onRelease: () -> Void

    @State private var isHolding = false
    @State private var sessionCancelled = false

    private var bounds: CGRect {
        CGRect(origin: .zero, size: CGSize(width: hitSize, height: hitSize))
    }

    var body: some View {
        content
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
            .gesture(dragGesture, including: .all)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { commitFromKeyboard() }
            .accessibilityLabel(label)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard enabled else { return }
                if sessionCancelled { return }
                let slopBounds = bounds.insetBy(dx: -8, dy: -8)
                if slopBounds.contains(value.location) {
                    if !isHolding {
                        isHolding = true
                        onPress()
                    }
                } else if isHolding {
                    isHolding = false
                    sessionCancelled = true
                    onCancel()
                }
            }
            .onEnded { value in
                guard enabled else { return }
                if isHolding {
                    isHolding = false
                    if sessionCancelled {
                        onCancel()
                    } else {
                        onRelease()
                    }
                }
                sessionCancelled = false
            }
    }

    private func commitFromKeyboard() {
        guard enabled, !isHolding else { return }
        onRelease()
    }
}

// MARK: - Play / Pause

/// Animated play/pause button. The visible symbol follows the *source of
/// truth* `isPlaying`; the component never keeps a long-lived rival state.
/// Rapid re-clicks interrupt any in-flight animation cleanly because every
/// gesture phase retargets the same pair of state values.
struct AnimatedPlayPauseButton: View {
    let isPlaying: Bool
    let enabled: Bool
    let metrics: AnimatedMediaControlMetrics
    let color: Color
    let disabledColor: Color
    let blendMode: BlendMode
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy

    @State private var showingPlaySymbol: Bool
    @State private var symbolScale: CGFloat = 1
    @State private var symbolOpacity: CGFloat = 1
    @State private var handoffTask: Task<Void, Never>?
    @State private var isUserAnimating = false

    init(
        isPlaying: Bool,
        enabled: Bool,
        metrics: AnimatedMediaControlMetrics,
        color: Color,
        disabledColor: Color,
        blendMode: BlendMode = .normal,
        action: @escaping () -> Void
    ) {
        self.isPlaying = isPlaying
        self.enabled = enabled
        self.metrics = metrics
        self.color = color
        self.disabledColor = disabledColor
        self.blendMode = blendMode
        self.action = action
        // Playing shows the pause bars; paused shows the play triangle.
        _showingPlaySymbol = State(initialValue: !isPlaying)
    }

    var body: some View {
        AnimatedControlHitArea(
            hitSize: metrics.hitSize,
            enabled: enabled,
            label: Text(isPlaying ? "Pause" : "Play"),
            content: symbolStage
                .frame(width: metrics.playSymbolSize, height: metrics.playSymbolSize),
            onPress: press,
            onCancel: cancelPress,
            onRelease: release
        )
        .onChange(of: isPlaying) { _, newValue in
            syncToExternalState(newValue)
        }
        .onDisappear {
            handoffTask?.cancel()
            handoffTask = nil
            isUserAnimating = false
        }
    }

    // MARK: Symbol stage

    private var symbolStage: some View {
        ZStack {
            MediaControlPlaySymbol()
                .scaleEffect(showingPlaySymbol ? symbolScale : 0.001)
                .opacity(showingPlaySymbol ? symbolOpacity : 0)

            MediaControlPauseSymbol()
                .scaleEffect(showingPlaySymbol ? 0.001 : symbolScale)
                .opacity(showingPlaySymbol ? 0 : symbolOpacity)
        }
        .foregroundStyle(enabled ? color : disabledColor)
        .compositingGroup()
        .blendMode(enabled ? blendMode : .normal)
    }

    // MARK: Gesture phases

    private func press() {
        // A new press takes ownership of the symbol: any pending handoff from
        // a previous release must not fire mid-press and reset the values.
        cancelHandoff()
        isUserAnimating = true
        let targetScale: CGFloat = motionPolicy == .full ? 0.48 : 0.85
        let targetOpacity: CGFloat = motionPolicy == .full ? 0.88 : 0.9
        withAnimation(pressAnimation) {
            symbolScale = targetScale
            symbolOpacity = targetOpacity
        }
    }

    private func cancelPress() {
        cancelHandoff()
        isUserAnimating = false
        withAnimation(cancelAnimation) {
            symbolScale = 1
            symbolOpacity = 1
        }
    }

    private func release() {
        cancelHandoff()
        isUserAnimating = true

        // 1) Old symbol exits very fast.
        withAnimation(exitAnimation) {
            symbolScale = 0
            symbolOpacity = 0
        }
        // 2) The other symbol becomes the active one.
        showingPlaySymbol.toggle()

        if motionPolicy != .full {
            // Reduce Motion: gentle direct crossfade, no spring handoff.
            withAnimation(enterAnimation) {
                symbolScale = 1
                symbolOpacity = 1
            }
            isUserAnimating = false
        } else {
            // 3) 40 ms handoff delay, then the new symbol springs in from 0.05.
            handoffTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    symbolScale = 0.05
                    symbolOpacity = 0
                }
                withAnimation(enterAnimation) {
                    symbolScale = 1
                    symbolOpacity = 1
                }
                try? await Task.sleep(for: .milliseconds(380))
                guard !Task.isCancelled else { return }
                isUserAnimating = false
            }
        }

        // 4) Let the exit transaction reach the render server before the
        // playback state changes trigger the rest of the UI graph.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func cancelHandoff() {
        handoffTask?.cancel()
        handoffTask = nil
    }

    /// External playback changes (other UI, system media keys) win only when
    /// the user is not actively animating the control locally.
    private func syncToExternalState(_ newValue: Bool) {
        guard !isUserAnimating else { return }
        let targetShowingPlay = !newValue
        guard targetShowingPlay != showingPlaySymbol else { return }
        cancelHandoff()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showingPlaySymbol = targetShowingPlay
            symbolScale = 1
            symbolOpacity = 1
        }
    }

    // MARK: MotionKit token parameters

    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
    }

    private var pressAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.microInteraction])
    }

    private var cancelAnimation: Animation? {
        motionPolicy.animation(
            for: motionTokens.phaseSpec(
                for: .gestureSettle,
                duration: motionTokens[.gestureSettle].duration,
                bounce: 0.16
            )
        )
    }

    private var exitAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.microInteraction])
    }

    private var enterAnimation: Animation? {
        motionPolicy.animation(
            for: motionTokens.phaseSpec(
                for: .emphasis,
                duration: motionTokens[.emphasis].duration,
                bounce: 0.40
            )
        )
    }
}

// MARK: - Previous / Next

/// Animated previous/next button with a three-arrow relay. The relay and the
/// press springs are Core Animation animations, which the render server plays
/// on its own: the track switch a click starts can hold the main thread without
/// stopping the arrows. The springs are sampled from the same MotionKit specs.
struct AnimatedSkipButton: View {
    enum Direction {
        case previous
        case next
    }

    let direction: Direction
    let enabled: Bool
    let metrics: AnimatedMediaControlMetrics
    let color: Color
    let disabledColor: Color
    let blendMode: BlendMode
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy

    @State private var relay = SkipRelayController()

    init(
        direction: Direction,
        enabled: Bool,
        metrics: AnimatedMediaControlMetrics,
        color: Color,
        disabledColor: Color,
        blendMode: BlendMode = .normal,
        action: @escaping () -> Void
    ) {
        self.direction = direction
        self.enabled = enabled
        self.metrics = metrics
        self.color = color
        self.disabledColor = disabledColor
        self.blendMode = blendMode
        self.action = action
    }

    var body: some View {
        AnimatedControlHitArea(
            hitSize: metrics.hitSize,
            enabled: enabled,
            label: Text(direction == .previous ? "Previous Track" : "Next Track"),
            content: SkipRelayStage(
                controller: relay,
                direction: direction,
                color: enabled ? color : disabledColor,
                blendMode: enabled ? blendMode : .normal
            )
            .frame(width: metrics.navSymbolSize, height: metrics.navSymbolSize),
            onPress: press,
            onCancel: cancelPress,
            onRelease: release
        )
    }

    // MARK: Gesture phases

    private func press() {
        let full = motionPolicy == .full
        relay.settle(scale: full ? 0.62 : 0.85, opacity: full ? 0.88 : 0.9,
                     spec: motionTokens[.microInteraction], policy: motionPolicy)
    }

    private func cancelPress() {
        relay.settle(scale: 1, opacity: 1, spec: cancelSpec, policy: motionPolicy)
    }

    private func release() {
        relay.settle(scale: 1, opacity: 1, spec: releaseSpec, policy: motionPolicy)
        if motionPolicy == .full { relay.run(relaySpec) }

        // The animations above are committed at the end of this turn of the run
        // loop; the track switch starts after them.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    // MARK: Animation parameters

    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
    }

    private var cancelSpec: MotionSpec {
        motionTokens.phaseSpec(for: .gestureSettle, duration: motionTokens[.gestureSettle].duration, bounce: 0.16)
    }

    private var releaseSpec: MotionSpec {
        motionTokens.phaseSpec(for: .emphasis, duration: motionTokens[.emphasis].duration, bounce: 0.40)
    }

    /// Keeps the relay's deliberate 0.58s visual window while deriving its
    /// spring behavior from the emphasis token.
    private var relaySpec: MotionSpec {
        motionTokens.phaseSpec(for: .emphasis, duration: 0.58, bounce: 0.40)
    }
}

// MARK: - Relay layers

/// Drives one skip button's layers directly, so a click never waits for a
/// SwiftUI update to start its animations.
@MainActor
private final class SkipRelayController {
    weak var view: SkipRelayNSView?

    /// Springs the whole symbol to a press scale and opacity from wherever it is.
    func settle(scale: CGFloat, opacity: CGFloat, spec: MotionSpec, policy: MotionPolicy) {
        guard let layer = view?.container else { return }
        let shown = layer.presentation() ?? layer
        let fromScale = (shown.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue ?? 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        MotionLayerAnimator.animate(layer: layer, keyPath: "transform.scale", fromValue: fromScale, toValue: Double(scale),
                                    spec: spec, policy: policy, animationKey: "press.scale")
        MotionLayerAnimator.animate(layer: layer, keyPath: "opacity", fromValue: shown.opacity, toValue: Float(opacity),
                                    spec: spec, policy: policy, animationKey: "press.opacity")
        CATransaction.commit()
    }

    func run(_ spec: MotionSpec) { view?.relay(spec) }
}

/// The relay as SwiftUI places it; all motion happens in `SkipRelayNSView`.
private struct SkipRelayStage: NSViewRepresentable {
    let controller: SkipRelayController
    let direction: AnimatedSkipButton.Direction
    let color: Color
    let blendMode: BlendMode

    func makeNSView(context: Context) -> SkipRelayNSView {
        let view = SkipRelayNSView(direction: direction)
        controller.view = view
        return view
    }

    func updateNSView(_ view: SkipRelayNSView, context: Context) {
        controller.view = view
        view.direction = direction
        view.style(color: NSColor(color), blendMode: blendMode,
                   animated: context.transaction.animation != nil && !context.transaction.disablesAnimations)
    }
}

/// Three arrows for the relay.
///
/// Geometric alignment, at relay progress `p` (0 when a click starts, 1 at rest):
/// - Lane separation between arrows is `size * (40 / 134)`, the arrow's own width.
/// - The gliding arrow moves from `homeLane` to `awayLane`.
/// - The standby arrow sits at `homeLane` and scales by `p` from its flat back
///   edge, so its tip always touches the gliding arrow's back edge.
/// - The exiting arrow shrinks towards its tip and fades in the first 35% of
///   the motion (~0.2s).
/// - At `p == 0` and `p == 1` two arrows show in the same two lanes, so each
///   relay starts where the last one ended.
private final class SkipRelayNSView: NSView {
    let container = CALayer()
    /// Standby, gliding, exiting.
    private let arrows = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private var color = NSColor.labelColor
    private var blendMode = BlendMode.normal
    var direction: AnimatedSkipButton.Direction {
        didSet { if direction != oldValue { place() } }
    }

    init(direction: AnimatedSkipButton.Direction) {
        self.direction = direction
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(container)
        arrows.forEach(container.addSublayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The SwiftUI hit area above owns the pointer.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        matchBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchBackingScale()
    }

    /// Sublayers added by hand keep a scale of 1 unless told the screen's.
    private func matchBackingScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.contentsScale = scale
        arrows.forEach { $0.contentsScale = scale }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor(animated: false)
    }

    func style(color: NSColor, blendMode: BlendMode, animated: Bool) {
        if color != self.color {
            self.color = color
            applyColor(animated: animated)
        }
        if blendMode != self.blendMode {
            self.blendMode = blendMode
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.compositingFilter = Self.filter(blendMode)
            CATransaction.commit()
        }
    }

    private func applyColor(animated: Bool) {
        var resolved: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.35)
        arrows.forEach { $0.fillColor = resolved }
        CATransaction.commit()
    }

    /// Plays one relay: the MotionKit spring sampled at 120 Hz into keyframes,
    /// which Core Animation plays without the main thread.
    func relay(_ spec: MotionSpec) {
        guard container.bounds.width > 0 else { return }
        let evaluator = MotionSpringEvaluator(spec: spec)
        let duration = max(0.05, spec.visualCompletionDelay())
        let steps = max(2, Int((duration * 120).rounded(.up)))
        var poses = (0...steps).map { pose(CGFloat(evaluator.normalizedValue(at: duration * Double($0) / Double(steps)))) }
        poses[steps] = pose(1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(pose(1))
        for (index, arrow) in arrows.enumerated() {
            func add(_ keyPath: String, _ values: [Any]) {
                let animation = CAKeyframeAnimation(keyPath: keyPath)
                animation.values = values
                animation.duration = duration
                animation.calculationMode = .linear
                arrow.add(animation, forKey: "relay." + keyPath)
            }
            // The outline itself moves and scales, so every frame is drawn from
            // the vector at full resolution rather than a moved bitmap.
            add("path", poses.map { outline($0[index], arrow: index) })
            add("opacity", poses.map { Float($0[index].opacity) })
        }
        CATransaction.commit()
    }

    /// The arrow at rest, centred in the stage.
    private var basePath = CGMutablePath() as CGPath
    /// Each arrow's scaling origin as a fraction of the stage's width: the
    /// standby's flat back edge, the gliding arrow's centre, the exiting arrow's tip.
    private var anchors: [CGFloat] = [0.35236, 0.5, 0.64764]

    private func place() {
        let size = min(bounds.width, bounds.height)
        guard size > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        basePath = MediaControlSkipArrowSymbol(mirrored: direction == .previous).path(in: container.bounds).cgPath
        let isNext = direction == .next
        anchors = [isNext ? 0.35236 : 0.64764, 0.5, isNext ? 0.64764 : 0.35236]
        for arrow in arrows { arrow.frame = container.bounds }
        apply(pose(1))
        CATransaction.commit()
    }

    /// The arrow's outline scaled about its anchor and moved to its pose.
    private func outline(_ pose: ArrowPose, arrow index: Int) -> CGPath {
        let origin = anchors[index] * container.bounds.width
        let midY = container.bounds.midY
        var transform = CGAffineTransform(translationX: pose.x, y: midY)
            .scaledBy(x: pose.scale, y: pose.scale)
            .translatedBy(x: -origin, y: -midY)
        return basePath.copy(using: &transform) ?? basePath
    }

    private typealias ArrowPose = (x: CGFloat, scale: CGFloat, opacity: CGFloat)

    private func pose(_ p: CGFloat) -> [ArrowPose] {
        let size = container.bounds.width
        let lane = size * (40 / 134)
        let isNext = direction == .next
        let home: CGFloat = isNext ? -lane / 2 : lane / 2
        let away = -home
        let back: CGFloat = isNext ? 0.35236 : 0.64764
        let tip: CGFloat = isNext ? 0.64764 : 0.35236
        let exit = min(1, max(0, p / 0.35))
        return [
            (back * size + home, max(0.001, p), min(1, max(0, p * 3))),
            (size / 2 + home + p * (away - home), 1, 1),
            (tip * size + away, max(0.001, 1 - exit), 1 - exit)
        ]
    }

    private func apply(_ poses: [ArrowPose]) {
        for (index, arrow) in arrows.enumerated() {
            arrow.path = outline(poses[index], arrow: index)
            arrow.opacity = Float(poses[index].opacity)
        }
    }

    /// SwiftUI's blend modes as Core Animation compositing filters.
    private static func filter(_ mode: BlendMode) -> Any? {
        switch mode {
        case .normal: nil
        case .plusLighter: "plusL"
        case .plusDarker: "plusD"
        case .destinationOut: "destOut"
        case .multiply: CIFilter(name: "CIMultiplyBlendMode")
        case .screen: CIFilter(name: "CIScreenBlendMode")
        case .overlay: CIFilter(name: "CIOverlayBlendMode")
        case .darken: CIFilter(name: "CIDarkenBlendMode")
        case .lighten: CIFilter(name: "CILightenBlendMode")
        case .colorDodge: CIFilter(name: "CIColorDodgeBlendMode")
        case .colorBurn: CIFilter(name: "CIColorBurnBlendMode")
        case .softLight: CIFilter(name: "CISoftLightBlendMode")
        case .hardLight: CIFilter(name: "CIHardLightBlendMode")
        case .difference: CIFilter(name: "CIDifferenceBlendMode")
        case .exclusion: CIFilter(name: "CIExclusionBlendMode")
        case .hue: CIFilter(name: "CIHueBlendMode")
        case .saturation: CIFilter(name: "CISaturationBlendMode")
        case .color: CIFilter(name: "CIColorBlendMode")
        case .luminosity: CIFilter(name: "CILuminosityBlendMode")
        default: nil
        }
    }
}
