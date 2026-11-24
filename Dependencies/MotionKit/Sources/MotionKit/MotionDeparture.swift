import Foundation
import QuartzCore

/// A spring departure that leaves through an edge while it is still moving.
///
/// A spring aimed exactly at the edge spends its last frames creeping toward
/// rest, which reads as a stall right before the surface disappears. A
/// departure aims the same spring past the edge by `overshoot` of the travel
/// distance and ends the motion at the moment it crosses the edge, so the
/// tail keeps real speed until the surface is gone.
public struct MotionDeparture: Hashable, Sendable {
    public let spec: MotionSpec
    public let from: Double
    public let edge: Double
    public let overshoot: Double
    public let initialVelocity: Double

    public init(
        spec: MotionSpec,
        from: Double,
        edge: Double,
        overshoot: Double = 0.5,
        initialVelocity: Double = 0
    ) {
        self.spec = spec
        self.from = from
        self.edge = edge
        self.overshoot = max(0, overshoot)
        self.initialVelocity = initialVelocity
    }

    /// The value the spring aims at, beyond the edge.
    public var target: Double {
        from + (edge - from) * (1 + overshoot)
    }

    /// Time until the motion crosses the edge.
    public var duration: TimeInterval {
        time(atProgress: 1)
    }

    /// Time at which the motion has covered `progress` (0...1) of the
    /// distance from `from` to `edge`. Use it to start companion motion at a
    /// point along the departure instead of after it.
    public func time(atProgress progress: Double) -> TimeInterval {
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0, abs(edge - from) > .ulpOfOne else { return 0 }

        let goal = clamped / (1 + overshoot)
        let evaluator = MotionSpringEvaluator(spec: spec)
        let horizon = max(spec.visualCompletionDelay(initialVelocity: initialVelocity), 1.0 / 60.0)
        let step = 1.0 / 240.0

        func reached(_ time: TimeInterval) -> Bool {
            evaluator.normalizedValue(at: time, initialVelocity: initialVelocity) >= goal
        }

        var lower: TimeInterval = 0
        while lower < horizon {
            let upper = min(lower + step, horizon)
            if reached(upper) {
                var low = lower
                var high = upper
                for _ in 0..<20 {
                    let mid = (low + high) / 2
                    if reached(mid) { high = mid } else { low = mid }
                }
                return high
            }
            lower = upper
        }
        return horizon
    }

    /// A Core Animation spring from `from` toward `target`, cut at the edge
    /// crossing. Pair it with a model value past the edge so the layer stays
    /// out of view once the animation is removed.
    public func coreAnimation(keyPath: String) -> CASpringAnimation {
        let animation = spec.coreAnimation(keyPath: keyPath, initialVelocity: initialVelocity)
        animation.fromValue = from
        animation.toValue = target
        animation.duration = duration
        return animation
    }
}
