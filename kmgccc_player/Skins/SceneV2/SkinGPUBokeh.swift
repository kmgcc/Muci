import Metal
import QuartzCore

// `bokeh` on a `render: "gpu"` layer: at a lyric moment the lens drifts out of focus, twitches a
// few times around that blurred middle as if hunting, then settles sharp again. The skin says
// when (`at`, in lyric time); the host keeps the curve on the layer's own display clock, so the
// filter itself changes only when the line does and the layer is never rebuilt per frame.

/// The filter's settings, as the layer's view evaluated them.
nonisolated struct SkinGPUBokeh: Equatable {
    /// Lyric time the hunt begins, in seconds.
    var at: Double
    var seed: Double
    /// One of `SkinFocusHunt.Wave`; -1 lets the seed choose.
    var wave: Int
    /// Defocus radius at full strength, in points.
    var radius: Double
    /// The whole curve's scale, 0 to 1.
    var amount: Double
    /// Playback rate of the curve.
    var speed: Double
    /// How far the frame grows at full strength, as a lens breathes while it focuses.
    var breathing: Double
    /// Share of the default source size, which sets the detail the defocus keeps.
    var detail: Double
    /// How strongly highlights lead their discs, 0 to 1: bright, solid discs at the top.
    var glow: Double
    /// Brightness from which a point counts as a highlight, 0 to 1.
    var threshold: Double
    /// Swirl towards the corners, 0 to 1: discs squash along the radius and turn.
    var swirl: Double
    /// Above 0 the lens stays open at this strength whatever `at` says, for tuning the look.
    var hold: Double

    @MainActor init?(_ value: SkinValue) {
        hold = value[member: "hold"].number(0).clamped01
        let given = value[member: "at"].numberValue.flatMap { $0.isFinite ? $0 : nil }
        guard let at = given ?? (hold > 0 ? 0 : nil) else { return nil }
        self.at = at
        seed = value[member: "seed"].numberValue ?? at
        wave = SkinFocusHunt.waveIndex(value[member: "wave"].number(-1))
        radius = min(96, max(0, value[member: "radius"].number(24)))
        amount = value[member: "amount"].number(1).clamped01
        speed = min(4, max(0.2, value[member: "speed"].number(1)))
        breathing = min(0.05, max(0, value[member: "breathing"].number(0)))
        detail = min(2, max(0.25, value[member: "detail"].number(1)))
        glow = value[member: "glow"].number(0.6).clamped01
        threshold = value[member: "threshold"].number(0.3).clamped01
        swirl = value[member: "swirl"].number(0.3).clamped01
    }

    /// The curve's age at a lyric time.
    func age(lyricsTime: Double) -> Double { (lyricsTime - at) * speed }

    /// Strength from 0 to 1 at a lyric time.
    func level(lyricsTime: Double) -> Double {
        if hold > 0 { return hold * amount }
        return SkinFocusHunt.value(age: age(lyricsTime: lyricsTime), seed: seed, wave: wave) * amount
    }

    /// Whether the curve has yet to finish; one that starts more than ten seconds on counts as done.
    func pending(lyricsTime: Double) -> Bool {
        guard amount > 0, radius > 0 else { return false }
        if hold > 0 { return true }
        let age = age(lyricsTime: lyricsTime)
        return age > -10 && age < SkinFocusHunt.duration(seed: seed, wave: wave)
    }

    /// Whether the hunt starts within `lead` seconds (or has started and not finished).
    func approaching(lyricsTime: Double, lead: Double) -> Bool {
        pending(lyricsTime: lyricsTime) && (hold > 0 || age(lyricsTime: lyricsTime) > -lead * speed)
    }
}

/// The focus hunt, as a focus puller would play it: the lens throws out of focus, comes back
/// almost sharp and rests there a breath, then throws again, once or twice (now and then three
/// times), each throw smaller than the last, before it lands sharp. Four characters; every value
/// comes from the seed, so all layers of a scene, and every play of the same line, move alike.
nonisolated enum SkinFocusHunt {
    nonisolated enum Wave: Int, CaseIterable {
        /// An autofocus searching: a quick throw that slows into its widest point, a smooth pull
        /// back to nearly sharp, a rest, and a smaller throw.
        case hunt
        /// Short swells close together, like an unsteady eye trying to hold focus.
        case flutter
        /// Slow, wide swells that ease in and out, dazed.
        case drift
        /// A hard snap wide open, falling back almost at once, then a long rest.
        case snap
    }

    /// How a segment moves towards its key.
    nonisolated enum Ease {
        /// Fast at first, settling into the key: a throw.
        case out
        /// Very fast at first: a snap.
        case snap
        /// Slow at both ends: a hand-pulled rack.
        case inOut
    }

    nonisolated struct Key {
        var time: Double
        var value: Double
        var ease: Ease = .inOut
    }

    private static let weights: [Double] = [0.4, 0.2, 0.2, 0.2]

    /// A wave number as an index; anything outside the four, or not a number, lets the seed choose.
    static func waveIndex(_ value: Double) -> Int {
        guard value.isFinite, let wave = Wave(rawValue: Int(value.rounded())) else { return -1 }
        return wave.rawValue
    }

    static func value(age: Double, seed: Double, wave: Int) -> Double {
        guard age > 0, seed.isFinite else { return 0 }
        let keys = keys(seed: seed, wave: resolved(wave, seed: seed))
        guard let last = keys.last, age < last.time else { return 0 }
        var index = 1
        while index < keys.count - 1, keys[index].time <= age { index += 1 }
        let a = keys[index - 1], b = keys[index]
        let t = min(1, max(0, (age - a.time) / max(1e-4, b.time - a.time)))
        let eased: Double
        switch b.ease {
        case .out: eased = 1 - pow(1 - t, 3)
        case .snap: eased = 1 - pow(1 - t, 5)
        case .inOut: eased = t * t * t * (t * (t * 6 - 15) + 10)
        }
        return a.value + (b.value - a.value) * eased
    }

    static func duration(seed: Double, wave: Int) -> Double {
        guard seed.isFinite else { return 0 }
        return keys(seed: seed, wave: resolved(wave, seed: seed)).last?.time ?? 0
    }

    static func resolved(_ wave: Int, seed: Double) -> Wave {
        if let chosen = Wave(rawValue: wave) { return chosen }
        var t = hash(seed, 0.17) * weights.reduce(0, +)
        for (index, weight) in weights.enumerated() {
            t -= weight
            if t < 0 { return Wave(rawValue: index) ?? .hunt }
        }
        return .hunt
    }

    static func keys(seed: Double, wave: Wave) -> [Key] {
        var keys = [Key(time: 0, value: 0)]
        var salt = 1.0
        func r(_ low: Double, _ high: Double) -> Double {
            salt += 1
            return low + (high - low) * hash(seed, salt)
        }
        func to(_ value: Double, after seconds: Double, _ ease: Ease = .inOut) {
            keys.append(Key(time: (keys.last?.time ?? 0) + seconds, value: min(1, max(0, value)), ease: ease))
        }
        func hold(_ seconds: Double) { to(keys.last?.value ?? 0, after: seconds) }
        // Each throw lands back nearly sharp: a breath of focus between throws keeps the lens
        // alive instead of leaving it smeared. Most hunts throw once or twice, a few three times.
        func nearlySharp() -> Double { r(0.04, 0.12) }
        let roll = r(0, 1)
        let count = roll < 0.4 ? 1 : roll < 0.85 ? 2 : 3
        switch wave {
        case .hunt:
            for index in 0..<count {
                if index > 0 { hold(r(0.14, 0.32)) }
                to(r(0.82, 1.0) * pow(0.72, Double(index)), after: r(0.16, 0.24), .out)
                to(nearlySharp(), after: r(0.32, 0.46))
            }
            to(0, after: r(0.35, 0.5))
        case .flutter:
            let swells = count == 1 ? 2 : 3
            for index in 0..<swells {
                if index > 0 { hold(r(0.04, 0.1)) }
                to(index == 0 ? r(0.66, 0.8) : r(0.34, 0.52), after: r(0.1, 0.14), .out)
                to(nearlySharp(), after: r(0.15, 0.21))
            }
            to(0, after: r(0.3, 0.42))
        case .drift:
            for index in 0..<min(2, count) {
                if index > 0 { hold(r(0.1, 0.25)) }
                to(index == 0 ? r(0.75, 0.95) : r(0.45, 0.62), after: r(0.6, 0.85))
                to(r(0.08, 0.16), after: r(0.55, 0.75))
            }
            to(0, after: r(0.4, 0.55))
        case .snap:
            for index in 0..<count {
                if index > 0 { hold(r(0.22, 0.42)) }
                to(r(0.9, 1.0) * pow(0.75, Double(index)), after: r(0.045, 0.07), .snap)
                to(nearlySharp(), after: r(0.2, 0.3))
            }
            to(0, after: r(0.25, 0.35))
        }
        return keys
    }

    private static func hash(_ seed: Double, _ salt: Double) -> Double {
        let x = sin(seed * 12.9898 + salt * 78.233) * 43758.5453
        return x - x.rounded(.down)
    }
}

nonisolated struct SkinGPUBokehPost {
    var sourceSize: SIMD2<Float>
    var surfaceSize: SIMD2<Float>
    var radius: Float
    var weight: Float
    var breathing: Float
    var lift: Float
    var lod: Float
    var taps: Float
    var blurLevel: Float
    var rings: Float = 0
    var importance: Float = 1
    var threshold: Float = 0
    var swirl: Float = 0
    var squash: Float = 0
    var gain: Float = 0
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

/// One frame of the defocus: the radius in surface pixels, the frame's breathing and the
/// aperture's character.
nonisolated struct SkinGPUBokehFrame {
    var radius: Double
    var breathing: Double
    var glow: Double
    var threshold: Double
    var swirl: Double
}

/// How the disc is read at a radius in source pixels.
nonisolated enum SkinBokehAperture {
    static let texels = 7.0
    static let maxTaps = 64.0
    /// Ring spacing and ring cap for the runtime gather: about 2.4 source pixels apart, at most
    /// five rings (91 taps). Wider discs keep five rings and read a coarser level instead.
    static let ringSpacing = 2.4
    static let maxRings = 5.0

    /// The default gather: the level at which the disc spans at most `texels` texels, and enough
    /// taps to sit about one and a half texels apart there. The blur is written on the whole level
    /// below the one read, so a wide disc costs a quarter as many pixels for each doubling.
    static func plan(radius: Double, levels: Int) -> (lod: Double, taps: Double, blurLevel: Int) {
        let lod = min(Double(max(0, levels - 1)), max(0, log2(max(radius, 1e-3) / texels)))
        let span = radius / pow(2, lod)
        let taps = min(maxTaps, max(12, (1.3 * span * span).rounded()))
        return (lod, taps, Int(lod.rounded(.down)))
    }

    /// The runtime gather: rings, and the level whose texel spans the gap between them.
    static func rings(radius: Double, levels: Int) -> (rings: Double, lod: Double, blurLevel: Int) {
        let rings = min(maxRings, max(1, (radius / ringSpacing).rounded()))
        let lod = min(Double(max(0, levels - 1)), max(0, log2(max(1, radius / rings))))
        return (rings, lod, Int(lod.rounded(.down)))
    }
}

/// A layer's defocus textures: the source and the blur, the same size and both with levels.
final class SkinGPUBokehTargets {
    /// The default source holds about 1.5 million pixels whatever the layer's size: half the
    /// resolution of a full-screen layer on a Retina display, so the shallow end of the hunt
    /// keeps the scene's shapes. A 64-tap disc over it is the most a frame asks for.
    static let pixelBudget = 1_500_000.0

    let source: MTLTexture
    /// Plain coverage beside the weighted source, for the runtime gather.
    let coverage: MTLTexture
    let blurred: MTLTexture
    let surfaceWidth: Int, surfaceHeight: Int, detail: Double

    init?(device: MTLDevice, surfaceWidth: Int, surfaceHeight: Int, detail: Double) {
        let pixels = Double(surfaceWidth * surfaceHeight)
        let share = min(1, (Self.pixelBudget * detail / max(1, pixels)).squareRoot())
        let width = max(16, Int((Double(surfaceWidth) * share).rounded()))
        let height = max(16, Int((Double(surfaceHeight) * share).rounded()))
        func texture(_ format: MTLPixelFormat = .rgba16Float) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: true)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        guard let source = texture(), let coverage = texture(.r16Float), let blurred = texture() else { return nil }
        self.source = source
        self.coverage = coverage
        self.blurred = blurred
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
        self.detail = detail
    }

    func fits(surfaceWidth: Int, surfaceHeight: Int, detail: Double) -> Bool {
        self.surfaceWidth == surfaceWidth && self.surfaceHeight == surfaceHeight && self.detail == detail
    }
}

/// GPU time of the frames a layer drew while its lens moved, logged once per hunt so a run on
/// real hardware shows what the defocus costs next to the scene.
final class SkinGPUBokehTiming {
    private var samples: [Double] = []
    private var label = ""
    private(set) var isOpen = false

    func begin(_ label: String) {
        self.label = label
        isOpen = true
    }

    func record(_ seconds: Double) {
        guard seconds > 0, samples.count < 4000 else { return }
        samples.append(seconds)
    }

    func finish(refresh: Double) {
        defer { samples.removeAll(keepingCapacity: true); isOpen = false }
        guard !samples.isEmpty else { return }
        let sorted = samples.sorted()
        let average = sorted.reduce(0, +) / Double(sorted.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let budget = 1000 / max(1, refresh)
        Log.warning(String(format: "skin bokeh %@ frames=%d gpu avg=%.2fms p95=%.2fms max=%.2fms budget=%.2fms",
                           label, sorted.count, average * 1000, p95 * 1000, (sorted.last ?? 0) * 1000, budget), category: .background)
    }
}
