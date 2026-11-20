import Foundation
import MotionKit
import Observation
import SwiftUI

/// What a paused scene does with its free-running motion. `settle` eases `time` to a stop and
/// back, `continue` keeps the wall clock, `stop` holds still at once.
enum SkinScenePauseMode: String, CaseIterable {
    case settle, `continue`, stop
}

/// The scene document's `motion`: the pause behaviour, the spring the playback flow rides, and
/// the skin's own named tokens, each a retuned MotionKit token that the user's motion speed scales.
struct SkinSceneMotion {
    var pause = SkinScenePauseMode.settle
    var flow: SkinValue = .text(MotionToken.gestureSettle.rawValue)
    var tokens: [String: SkinValue] = [:]
}

/// Eases from 1 while playing to 0 while paused on a MotionKit spring, and integrates scene time
/// under that curve. Lyric and playback clocks stay truthful; only free-running motion rides it.
struct SkinPlaybackFlow {
    private var spring: MotionRetargetState?
    private var integrated = 0.0
    private var integratedAt: Double?

    mutating func value(at now: Double) -> Double {
        guard var current = spring else { return 0 }
        var state = current.advance(to: now)
        if current.isAnimating, current.isSettled(at: now) {
            current.snap(to: current.target)
            state = (current.target, 0)
        }
        spring = current
        // A bouncy spring may dip below zero; time never runs backwards.
        return max(0, state.value)
    }

    /// Wall seconds weighted by the flow, integrated at the display rate while it moves.
    mutating func time(at now: Double) -> Double {
        guard let start = integratedAt else { integratedAt = now; return integrated }
        // Nodes evaluated a moment before the latest frame read slightly earlier time.
        guard now > start else { return max(0, integrated - (start - now) * value(at: start)) }
        let span = now - start
        let steps = spring?.isAnimating == true ? min(240, max(1, Int((span * 120).rounded(.up)))) : 1
        let step = span / Double(steps)
        for index in 0..<steps { integrated += step * value(at: start + step * (Double(index) + 0.5)) }
        integratedAt = now
        return integrated
    }

    /// Returns how long the flow takes to settle, or nil when nothing eases. Without a spec the
    /// flow jumps to its target, as on the first call.
    mutating func set(playing: Bool, spec: MotionSpec?, now: Double) -> TimeInterval? {
        let target = playing ? 1.0 : 0
        guard let existing = spring else {
            spring = MotionRetargetState(value: target, spec: spec ?? MotionTokens.standard.gestureSettle)
            integratedAt = now
            return nil
        }
        guard existing.target != target else { return nil }
        _ = time(at: now)
        guard let spec, var current = spring else {
            spring?.snap(to: target)
            return nil
        }
        let state = current.advance(to: now)
        current = MotionRetargetState(value: state.value, velocity: state.velocity, spec: spec)
        current.retarget(to: target, at: now)
        spring = current
        return current.visualCompletionDelay
    }
}

/// One `follow()` spring, stepped in closed form so a new target never touches its position or
/// velocity. `ease` puts a critically damped stage between the target and the spring: a jump
/// in the target then builds the pull up gradually, the way a hand-held camera leans into a
/// move, instead of applying the whole force on the first frame.
struct SkinFollowSpring {
    var value: Double
    var velocity = 0.0
    var lead: Double
    var leadVelocity = 0.0
    var target: Double
    var time: Double
    var moving = false

    init(value: Double, time: Double) {
        self.value = value
        lead = value
        target = value
        self.time = time
    }

    mutating func advance(to now: Double, spec: MotionSpec, ease: Double) {
        let elapsed = now - time
        guard moving, elapsed > 0 else { time = max(time, now); return }
        time = now
        guard elapsed < 2 else { snap(); return }
        let spring = spec.spring
        let omega = (spring.stiffness / max(0.0001, spring.mass)).squareRoot()
        let zeta = spring.damping / (2 * (spring.stiffness * max(0.0001, spring.mass)).squareRoot())
        let easeOmega = ease > 0.001 ? 2 * .pi / ease : 0
        let steps = max(1, Int((elapsed * 240).rounded(.up)))
        let dt = elapsed / Double(steps)
        for _ in 0..<steps {
            if easeOmega > 0 {
                (lead, leadVelocity) = Self.step(lead, leadVelocity, toward: target, omega: easeOmega, zeta: 1, dt: dt)
            } else {
                (lead, leadVelocity) = (target, 0)
            }
            (value, velocity) = Self.step(value, velocity, toward: lead, omega: omega, zeta: zeta, dt: dt)
        }
        let scale = max(1, abs(target) * 1e-6)
        if abs(value - target) < 0.001 * scale, abs(velocity) < 0.001 * scale, abs(lead - target) < 0.001 * scale, abs(leadVelocity) < 0.001 * scale {
            snap()
        }
    }

    mutating func snap() {
        value = target
        lead = target
        velocity = 0
        leadVelocity = 0
        moving = false
    }

    /// Exact damped-oscillator motion over `dt` toward a fixed goal.
    static func step(_ x: Double, _ v: Double, toward goal: Double, omega: Double, zeta: Double, dt: Double) -> (Double, Double) {
        guard omega > 0 else { return (goal, 0) }
        let y = x - goal
        if abs(zeta - 1) < 1e-4 {
            let b = v + omega * y
            let e = Foundation.exp(-omega * dt)
            return (goal + e * (y + b * dt), e * (v - omega * b * dt))
        }
        if zeta < 1 {
            let a = zeta * omega
            let w = omega * (1 - zeta * zeta).squareRoot()
            let e = Foundation.exp(-a * dt), c = Foundation.cos(w * dt), s = Foundation.sin(w * dt)
            let b = (v + a * y) / w
            return (goal + e * (y * c + b * s), e * (v * c - (a * v + omega * omega * y) / w * s))
        }
        let root = (zeta * zeta - 1).squareRoot()
        let r1 = -omega * (zeta - root), r2 = -omega * (zeta + root)
        let c2 = (v - r1 * y) / (r2 - r1), c1 = y - c2
        let e1 = Foundation.exp(r1 * dt), e2 = Foundation.exp(r2 * dt)
        return (goal + c1 * e1 + c2 * e2, r1 * c1 * e1 + r2 * c2 * e2)
    }
}

/// The `follow()` springs of one node instance. Each call site keeps a spring that retargets
/// with position and velocity intact whenever its target changes; the node's display timeline
/// runs only while one of them moves.
@Observable
@MainActor
final class SkinFollowers {
    private(set) var isMoving = false
    @ObservationIgnored private var springs: [Int: SkinFollowSpring] = [:]
    @ObservationIgnored private var wanted = false

    func state(site: Int, target: Double, spec: MotionSpec?, ease: Double = 0, now: Double) -> (value: Double, velocity: Double) {
        // Reduced motion lands on the target at once.
        guard let spec else {
            springs[site] = SkinFollowSpring(value: target, time: now)
            return (target, 0)
        }
        guard var spring = springs[site] else {
            springs[site] = SkinFollowSpring(value: target, time: now)
            return (target, 0)
        }
        if spring.target != target {
            // A paused timeline hands back its last frame date; a spring at rest starts from the
            // real now.
            if !spring.moving { spring.time = max(now, Date.timeIntervalSinceReferenceDate) }
            spring.target = target
            spring.moving = true
            request(true)
        }
        spring.advance(to: now, spec: spec, ease: ease)
        springs[site] = spring
        if wanted, !springs.values.contains(where: \.moving) { request(false) }
        return (spring.value, spring.velocity)
    }

    /// Values are read while a view draws, so the observed flag changes on the next turn.
    private func request(_ moving: Bool) {
        guard wanted != moving else { return }
        wanted = moving
        Task { @MainActor [weak self] in
            guard let self, self.wanted == moving, self.isMoving != moving else { return }
            self.isMoving = moving
        }
    }
}

/// Unique ids for `follow()` call sites, handed out as expressions compile.
enum SkinFollowSites {
    @MainActor private static var last = 0
    @MainActor static func next() -> Int { last += 1; return last }
}

/// What keeps a node's display timeline running. Clock, lyric and audio inputs stand still the
/// moment playback pauses; scene time once the playback flow settles; follow springs once they
/// land. Keyframes, pointer idle time, free time and glyph clocks never rest.
struct SkinFrameInputs: Equatable {
    var playback = false
    var time = false
    var follow = false
    var always = false

    init(frame: Set<SkinDataDomain>, always: Bool) {
        // A frame expression lists every domain it reads, so `host.lyricsVisible` next to the
        // lyric clock would otherwise keep the node drawing through a pause.
        self.always = always || frame.contains(.wallTime)
        time = frame.contains(.time)
        follow = frame.contains(.follow)
        // A node on the timeline for its type alone (spectrum, lyric line) follows playback.
        playback = !frame.isDisjoint(with: [.clock, .lyricsTimeline, .audio]) || !(self.always || time || follow)
    }

    /// Lazy, so a view observes the flow and follow flags only when its inputs depend on them.
    func isStill(playing: Bool, timeMoves: @autoclosure () -> Bool, following: @autoclosure () -> Bool) -> Bool {
        !always && !(playback && playing) && !(time && timeMoves()) && !(follow && following())
    }
}
