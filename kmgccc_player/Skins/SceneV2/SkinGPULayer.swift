import AppKit
import Metal
import MotionKit
import Observation
import QuartzCore
import simd
import SwiftUI

/// `render: "gpu"` on a layer draws its children (shapes, gradients, fog, particles, comets and text) into
/// one Metal surface on its own display clock, instead of one SwiftUI view per child that SwiftUI
/// rebuilds, compares and lays out every frame. The surface draws at the layer's `resolution`
/// (times the render quality), and the layer's `grain` filter is added as it is scaled up, so the
/// whole backdrop costs two GPU passes. The children keep their usual properties and expressions.
enum SkinGPULayer {
    static let shapeTypes: Set<String> = ["shape", "gradient", "fog", "particles", "comet"]
    private static let shapeKeys: Set<String> = [
        "frame", "visible", "opacity", "blendMode", "depth", "hitTesting", "color", "colors", "stops", "mode", "radius", "start", "end",
        "shape", "size", "speed", "warp", "gain", "scrollX", "scrollY", "count", "seed", "soft", "lifetime", "angle", "spread", "trail",
        "turbulence", "wander", "curve", "filter", "points", "stroke", "trimStart", "trimEnd", "rotation", "blur", "orbit", "progress",
        "sweep", "width", "brush", "zones",
    ]
    private static let shapeKinds: Set<String> = ["rectangle", "circle", "ellipse", "path"]
    private static let layerKeys: Set<String> = ["frame", "visible", "opacity", "depth", "hitTesting", "offsetX", "offsetY"]
    private static let repeatKeys: Set<String> = ["frame", "visible", "items", "limit", "layout", "hitTesting"]
    private static let textKeys: Set<String> = [
        "frame", "visible", "opacity", "depth", "hitTesting", "text", "font", "weight", "fontSize", "lineLimit", "alignment", "tracking",
        "lineSpacing", "color", "rotation", "scale", "offsetX", "offsetY", "blur", "subpixel", "glow", "glyphMotion", "key",
    ]
    private static let cameraKeys: Set<String> = ["x", "y", "zoom", "perspective", "rotation", "rotationX", "rotationY", "rasterize"]

    static func validate(_ children: [SkinCompiledSceneNode], camera: [String: SkinParameterValue]?, error: (String, String) -> SkinSceneError) throws {
        try validate(children, path: "", error: error)
        if let key = camera.map({ Set($0.keys).subtracting(cameraKeys) })?.sorted().first {
            throw error(".camera." + key, "render: gpu 的镜头限于 x、y、zoom、perspective、rotation、rotationX、rotationY")
        }
    }

    private static func validate(_ children: [SkinCompiledSceneNode], path: String, error: (String, String) -> SkinSceneError) throws {
        for (index, child) in children.enumerated() {
            let path = path + ".children[\(index)]"
            let allowed: Set<String>
            switch child.type {
            case "layer": allowed = layerKeys
            case "repeat": allowed = repeatKeys
            case "text": allowed = textKeys
            case let type where shapeTypes.contains(type): allowed = shapeKeys
            default: throw error(path, "render: gpu 的子节点限于 layer、repeat、text、shape、gradient、fog、particles、comet")
            }
            guard child.actions.isEmpty, child.watches.isEmpty, child.camera == nil else {
                throw error(path, "render: gpu 的子节点不带事件或镜头")
            }
            if let mask = child.mask {
                guard child.type == "shape", mask.type == "gradient", case .expression(let mode)? = mask.properties["mode"],
                      mode.constantValue?.textValue == "angular" else {
                    throw error(path + ".mask", "render: gpu 的遮罩限于 shape 上的 angular gradient")
                }
            }
            let keys = Set(child.properties.keys).union(child.variants.flatMap(\.properties.keys))
            if let key = keys.subtracting(allowed).sorted().first { throw error(path + "." + key, "render: gpu 不支持 \(key)") }
            if child.type == "shape", let shape = child.properties["shape"] {
                guard case .expression(let value) = shape, let kind = value.constantValue?.textValue, shapeKinds.contains(kind) else {
                    throw error(path + ".shape", "render: gpu 的 shape 限于 rectangle、circle、ellipse、path")
                }
            }
            if child.type == "repeat" {
                guard case .expression(let layout)? = child.properties["layout"], layout.constantValue?.textValue == "free" else {
                    throw error(path + ".layout", "render: gpu 的 repeat 须用 layout: free")
                }
            }
            if ["layer", "repeat"].contains(child.type) {
                try validate(child.children, path: path, error: error)
            } else if !child.children.isEmpty {
                throw error(path, "render: gpu 的 \(child.type) 不带子节点")
            }
        }
    }
}

// MARK: - Per-frame scene

nonisolated struct SkinGPUFrame {
    var size: SIMD2<Float>
    var time: Float
    var grain: Float
    var pointScale: Float
    var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
    var turn0 = SIMD4<Float>(1, 0, 0, 0)
    var turn1 = SIMD4<Float>(0, 1, 0, 0)
    var turn2 = SIMD4<Float>(0, 0, 1, 0)
}

nonisolated struct SkinGPUQuad {
    var origin: SIMD2<Float>
    var localSize: SIMD2<Float>
    var scale: Float
    var kind: Int32
    var stopCount: Int32 = 0
    var opacity: Float
    var color = SIMD4<Float>.zero
    var color2 = SIMD4<Float>.zero
    var params = SIMD4<Float>.zero
    var params2 = SIMD4<Float>.zero
    /// Layer points this shape travelled since the previous frame, for its motion blur.
    var velocity = SIMD4<Float>.zero
    /// An ellipse outline's `brush`: amount, dry, wobble, seed; amount 0 keeps it smooth.
    /// A fog's zones: share, scroll x, scroll y.
    var brush = SIMD4<Float>.zero
}

nonisolated struct SkinGPUDot {
    var centre: SIMD2<Float>
    var streak: SIMD2<Float>
    var radius: Float
    var soft: Float
    var pad = SIMD2<Float>.zero
    var color: SIMD4<Float>
}

nonisolated struct SkinGPUVertex {
    var position: SIMD2<Float>
    /// Signed distance from a stroke's centre line and its half width; zero for solid ribbons.
    /// A painted stroke puts its place across the stroke (±1 at the edges) in `x`.
    var edge = SIMD2<Float>.zero
    var color: SIMD4<Float>
    /// The stroke's blur (standard deviation). A painted stroke holds its seed, its place along
    /// the stroke in stroke widths, its dry-brush threshold and its brush amount instead.
    var blur = SIMD4<Float>.zero
}

struct SkinGPUScene {
    enum Item {
        /// `stops` holds eight colours and then the eight locations, as the shader reads them.
        case quad(SkinGPUQuad, stops: [SIMD4<Float>], additive: Bool)
        case dots(Range<Int>, additive: Bool)
        case ribbons(Range<Int>, additive: Bool)
        case glyph(SkinGPUGlyph, texture: MTLTexture, additive: Bool)
    }

    var items: [Item] = []
    var dots: [SkinGPUDot] = []
    var vertices: [SkinGPUVertex] = []
    /// Lit glyphs as grey luminance, one group per glow colour, each run through the bloom in
    /// turn so every light takes on its own colour.
    var blooms: [Bloom] = []
    /// How far the widest light reaches, in layer points, and how strong its outer veil is.
    var bloomReach = 0.0
    var bloomHaze = 0.0
    /// False once any node drawn has a per-frame input that still moves.
    var still = true

    struct Bloom {
        var color: OKLCHColor?
        var saturation: Double
        var emitters: [Item] = []
    }

    /// The most bloom passes a frame runs; further colours join the nearest group.
    static let bloomGroups = 3

    /// Adds a lit glyph to the group of its colour.
    mutating func emit(_ item: Item, color: OKLCHColor?, saturation: Double) {
        if let index = blooms.firstIndex(where: { $0.color == color && $0.saturation == saturation }) {
            blooms[index].emitters.append(item)
        } else if blooms.count < Self.bloomGroups {
            blooms.append(Bloom(color: color, saturation: saturation, emitters: [item]))
        } else {
            func lab(_ c: OKLCHColor?) -> SIMD3<Double> {
                guard let c else { return .zero }
                let angle = (c.hue ?? 0) * 2 * .pi
                return SIMD3(c.lightness, c.chroma * cos(angle), c.chroma * sin(angle))
            }
            let target = lab(color)
            let nearest = blooms.indices.min { a, b in
                let da = lab(blooms[a].color) - target, db = lab(blooms[b].color) - target
                return (da * da).sum() < (db * db).sum()
            } ?? 0
            blooms[nearest].emitters.append(item)
        }
    }
}

nonisolated struct SkinGPUBloomPass {
    var texel: SIMD2<Float>
    var pad = SIMD2<Float>.zero
    var tint: SIMD4<Float>
}

/// Everything the surface needs from the layer's view, refreshed whenever SwiftUI updates it.
struct SkinGPULayerInputs {
    var node: SkinCompiledSceneNode
    var data: SkinSceneData
    var size: CGSize
    var locals: [String: SkinValue]
    var live: SkinLiveViewport?
    var motionTokens: MotionTokens
    var moves: Bool
    var playing: Bool
    var active: Bool
    var renderScale: Double
    var resolution: Double
    var grain: Double
    /// `grain`'s tick rate; the pattern holds between ticks.
    var grainRate: Double
    var lens: SkinGPULens?
    /// The `bokeh` filter: a focus hunt at a lyric time.
    var bokeh: SkinGPUBokeh?
    /// The `lut` lookup runs in the last pass after the lens and before grain.
    var lut: SkinColorLUTFilter?
    var camera: (@MainActor (Double) -> SkinSceneCamera)?
    /// Whether the layer's camera rests, given whether playback runs and scene time moves.
    var cameraStill: @MainActor (Bool, Bool) -> Bool
    var metricsID: String
}

@MainActor
final class SkinGPULayerModel {
    var inputs: SkinGPULayerInputs?
    /// A focus hunt that has started: the filter follows the line, so the next line takes it away
    /// mid-curve, and the layer finishes it from here instead of snapping back to sharp.
    private var runningBokeh: SkinGPUBokeh?
    private var grainTime = 0.0
    private var lastStill = true
    /// The camera last frame, the camera now, and the layer's `motionBlur` share: together they
    /// turn a shape's own move into the streak it leaves on the surface.
    private var previousCamera: SkinSceneCamera?
    private var previousTime: Double?
    private var frameCamera: SkinSceneCamera?
    private var frameSize = CGSize.zero
    private var nodeDepth = 0.0
    private var motion = 0.0

    /// State a view keeps per node instance: a repeat's template has one per cell.
    private struct InstanceKey: Hashable {
        let node: ObjectIdentifier
        let cell: Int
    }

    private final class Instance {
        let followers = SkinFollowers()
        let cache = SkinNodeValueCache()
        let clock = SkinGlyphClock()
        var seen = 0
        /// Each glyph's centre in layer points last frame, for its own motion.
        var anchors: [CGPoint] = []
        /// The pass and text these anchors were taken at: a text drawn again after a gap, or a
        /// cell now showing other words, starts its motion afresh instead of streaking from
        /// where something else stood.
        var drawn = -1
        var text = ""
    }

    private var instances: [InstanceKey: Instance] = [:]
    private var pass = 0

    private func instance(_ node: SkinCompiledSceneNode, cell: Int) -> Instance {
        let key = InstanceKey(node: ObjectIdentifier(node), cell: cell)
        let found = instances[key] ?? { let created = Instance(); instances[key] = created; return created }()
        found.seen = pass
        return found
    }

    /// True when nothing on the surface moves until an input changes.
    func isStill() -> Bool {
        guard let inputs, inputs.active else { return true }
        let timeMoves = inputs.data.timeMoves(playing: inputs.playing)
        if !lastStill || !inputs.cameraStill(inputs.playing, timeMoves) { return false }
        // A focus hunt that has yet to finish keeps the surface drawing while the lyrics run.
        if inputs.moves, inputs.playing,
           bokeh(lyricsTime: inputs.data.clock.lyricsTime(at: Date.timeIntervalSinceReferenceDate)) != nil { return false }
        return !(inputs.grain > 0 && inputs.moves && timeMoves)
    }

    /// The focus hunt to draw at a lyric time: one under way, whether or not its line is still
    /// current, else the coming one, so its textures are ready before it starts.
    func bokeh(lyricsTime: Double) -> SkinGPUBokeh? {
        func started(_ bokeh: SkinGPUBokeh) -> Bool {
            bokeh.pending(lyricsTime: lyricsTime) && (bokeh.hold > 0 || bokeh.age(lyricsTime: lyricsTime) > 0)
        }
        if let current = inputs?.bokeh, started(current) {
            runningBokeh = current
            return current
        }
        if let runningBokeh, started(runningBokeh) { return runningBokeh }
        runningBokeh = nil
        guard let current = inputs?.bokeh, current.pending(lyricsTime: lyricsTime) else { return nil }
        return current
    }

    func frame(at now: Double, pointScale: Double, camera: SkinSceneCamera?) -> SkinGPUFrame? {
        guard let inputs else { return nil }
        if inputs.moves, inputs.data.timeMoves(playing: inputs.playing) {
            grainTime = SkinGrain.clock(now.truncatingRemainder(dividingBy: 3600), rate: inputs.grainRate)
        }
        var frame = SkinGPUFrame(size: SIMD2(Float(inputs.size.width), Float(inputs.size.height)), time: Float(grainTime),
                                 grain: Float(inputs.grain), pointScale: Float(pointScale))
        if let camera { (frame.turn0, frame.turn1, frame.turn2) = Self.turn(camera, size: inputs.size) }
        return frame
    }

    /// `rotationX` and `rotationY` with their perspective, then `rotation`, about the layer's
    /// centre, as SwiftUI's 3D rotation and rotation effects turn the view layer: a homography
    /// of the plane, by columns.
    static func turn(_ camera: SkinSceneCamera, size: CGSize) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        guard camera.rotation != 0 || camera.rotationX != 0 || camera.rotationY != 0 else {
            return (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0))
        }
        let k = Float(camera.perspective / max(1, max(size.width, size.height)))
        func tilt(_ degrees: Double, aroundX: Bool) -> simd_float3x3 {
            let angle = Float(degrees * .pi / 180), c = cos(angle), s = sin(angle)
            // The point (x, y, 0) turned in 3D; its depth z sets w, so nearer parts grow.
            if aroundX { return simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, c, 0), SIMD3(0, -s * k, 1)]) }
            return simd_float3x3(rows: [SIMD3(c, 0, 0), SIMD3(0, 1, 0), SIMD3(s * k, 0, 1)])
        }
        let angle = Float(camera.rotation * .pi / 180)
        let spin = simd_float3x3(rows: [SIMD3(cos(angle), -sin(angle), 0), SIMD3(sin(angle), cos(angle), 0), SIMD3(0, 0, 1)])
        let cx = Float(size.width / 2), cy = Float(size.height / 2)
        let toCentre = simd_float3x3(rows: [SIMD3(1, 0, -cx), SIMD3(0, 1, -cy), SIMD3(0, 0, 1)])
        let back = simd_float3x3(rows: [SIMD3(1, 0, cx), SIMD3(0, 1, cy), SIMD3(0, 0, 1)])
        let h = back * spin * tilt(camera.rotationY, aroundX: false) * tilt(camera.rotationX, aroundX: true) * toCentre
        return (SIMD4(h.columns.0, 0), SIMD4(h.columns.1, 0), SIMD4(h.columns.2, 0))
    }

    func scene(at now: Double, camera: SkinSceneCamera?, pixelsPerPoint: Double) -> SkinGPUScene {
        var scene = SkinGPUScene()
        guard let inputs else { return scene }
        pass += 1
        // The layer's own `visible` and `opacity`, which its view leaves to the surface.
        let root = instance(inputs.node, cell: -2)
        var context = SkinEvaluationContext(data: inputs.data, locals: inputs.locals, now: now, live: inputs.live)
        context.locals["self"] = .record([:])
        context.locals["parent"] = .record(["width": .number(inputs.size.width), "height": .number(inputs.size.height)])
        context.motionTokens = inputs.motionTokens
        context.moves = inputs.moves
        context.followers = root.followers
        context.memo = SkinLetMemo()
        let timeMoves = inputs.data.timeMoves(playing: inputs.playing)
        if !inputs.node.frameInputs.isStill(playing: inputs.playing, timeMoves: timeMoves, following: root.followers.isMoving) { scene.still = false }
        let visible = inputs.node.properties["visible"]?.evaluate(context).isTruthy != false
        let opacity = inputs.node.properties["opacity"]?.evaluate(context).number(1) ?? 1
        motion = Self.motionShare(inputs.node.properties["motionBlur"]?.evaluate(context))
        // The exposure is a fixed share of a second, not of the display's refresh: on a fast
        // display a frame is shorter, so its travel covers less of the shutter and the trail is
        // stretched back to the same length.
        let interval = previousTime.map { now - $0 } ?? (1.0 / 60)
        if interval > 0, interval < 0.1 { motion *= min(4, max(0.5, (1.0 / 60) / interval)) }
        // A gap between frames (a pause, a seek, a hidden surface) is no exposure: the camera
        // did not travel across the shutter, it jumped.
        if let previousTime, now - previousTime > 0.1 || now < previousTime { previousCamera = nil }
        frameCamera = camera
        frameSize = inputs.size
        if visible, opacity > 0.001 {
            walk(inputs.node.children, locals: inputs.locals, cell: -1, local: .identity, depth: 0, size: inputs.size, opacity: opacity,
                 camera: camera, now: now, pixelsPerPoint: pixelsPerPoint, into: &scene)
        }
        previousCamera = camera
        previousTime = now
        lastStill = scene.still
        if pass % 240 == 0 { instances = instances.filter { pass - $0.value.seen < 600 } }
        return scene
    }

    /// Draws `nodes` placed in a parent of `size`. `local` maps the parent's points to the
    /// layer's before the camera; each node takes the camera at its own `depth`, or its parent's.
    private func walk(_ nodes: [SkinCompiledSceneNode], locals: [String: SkinValue], cell: Int, local: CGAffineTransform, depth inheritedDepth: Double,
                      size: CGSize, opacity inherited: Double, camera: SkinSceneCamera?, now: Double, pixelsPerPoint: Double,
                      into scene: inout SkinGPUScene) {
        guard let inputs else { return }
        let timeMoves = inputs.data.timeMoves(playing: inputs.playing)
        for child in nodes {
            let instance = instance(child, cell: cell)
            var context = SkinEvaluationContext(data: inputs.data, locals: locals, now: now, live: inputs.live)
            context.locals["self"] = .record([:])
            context.locals["parent"] = .record(["width": .number(size.width), "height": .number(size.height)])
            context.motionTokens = inputs.motionTokens
            context.moves = inputs.moves
            context.followers = instance.followers
            context.memo = SkinLetMemo()
            // Checked before visibility: a hidden node whose `visible` follows the clock must
            // keep the surface awake until it appears.
            if scene.still, !child.frameInputs.isStill(playing: inputs.playing, timeMoves: timeMoves, following: instance.followers.isMoving) {
                scene.still = false
            }
            if child.hidesWithoutTransition, child.properties["visible"]?.evaluate(context).isTruthy == false { continue }
            let values = child.values(context, cache: instance.cache)
            guard values["visible"]?.isTruthy != false else { continue }
            let opacity = (values["opacity"]?.number(1) ?? 1) * inherited
            guard opacity > 0.001 else { continue }
            let depth = values["depth"]?.number() ?? inheritedDepth
            nodeDepth = depth
            let world = local.concatenating(cameraTransform(camera, depth: depth, size: inputs.size))
            let frame = self.frame(values, parent: size)
            switch child.type {
            case "layer":
                let origin = CGPoint(x: frame.centre.x - frame.size.width / 2 + (values["offsetX"]?.number() ?? 0),
                                     y: frame.centre.y - frame.size.height / 2 + (values["offsetY"]?.number() ?? 0))
                walk(child.children, locals: locals, cell: cell, local: CGAffineTransform(translationX: origin.x, y: origin.y).concatenating(local),
                     depth: depth, size: frame.size, opacity: opacity, camera: camera, now: now, pixelsPerPoint: pixelsPerPoint, into: &scene)
            case "repeat":
                guard let template = child.children.first else { continue }
                let origin = CGPoint(x: frame.centre.x - frame.size.width / 2, y: frame.centre.y - frame.size.height / 2)
                let inner = CGAffineTransform(translationX: origin.x, y: origin.y).concatenating(local)
                let items = Array((values["items"]?.listValue ?? []).prefix(child.repeatLimit))
                for index in items.indices {
                    let scoped = locals.merging(["item": items[index], "index": .number(Double(index)), "count": .number(Double(items.count))]) { _, new in new }
                    walk([template], locals: scoped, cell: index, local: inner, depth: depth, size: frame.size, opacity: opacity,
                         camera: camera, now: now, pixelsPerPoint: pixelsPerPoint, into: &scene)
                }
            case "text":
                let shown = values["text"]?.textValue ?? ""
                if instance.drawn != pass - 1 || instance.text != shown { instance.anchors.removeAll() }
                instance.drawn = pass
                instance.text = shown
                text(child, values: values, context: context, world: world, parent: size, opacity: opacity, clock: instance.clock,
                     anchors: &instance.anchors, now: now, pixelsPerPoint: pixelsPerPoint, into: &scene)
            default:
                let additive = values["blendMode"]?.textValue == "plusLighter"
                let topLeft = CGPoint(x: frame.centre.x - frame.size.width / 2, y: frame.centre.y - frame.size.height / 2).applying(world)
                let place = Placement(origin: topLeft, scale: sqrt(abs(world.a * world.d - world.b * world.c)), size: frame.size,
                                      velocity: cameraTravel(at: topLeft))
                switch child.type {
                case "shape":
                    let color = values["color"]?.colorValue ?? inputs.data.theme["theme.appForeground.primary"]?.colorValue
                    let kind = values["shape"]?.textValue ?? "rectangle"
                    if kind == "path" {
                        let mask = child.mask.map { mask in mask.values(context, cache: self.instance(mask, cell: cell).cache) }
                        stroke(values, mask: mask, frame: frame, world: world, opacity: opacity, additive: additive,
                               pixelsPerPoint: pixelsPerPoint, into: &scene)
                    } else if kind == "circle" || kind == "ellipse" {
                        scene.items.append(.quad(ellipse(values, color: color, place: place, opacity: opacity), stops: Self.noStops, additive: additive))
                    } else {
                        var quad = place.quad(kind: 0, opacity: opacity)
                        quad.color = premultiplied(color)
                        scene.items.append(.quad(quad, stops: Self.noStops, additive: additive))
                    }
                case "comet":
                    comet(values, place: place, opacity: opacity, additive: additive, into: &scene)
                case "gradient":
                    scene.items.append(.quad(gradient(values, place: place, opacity: opacity), stops: stops(values), additive: additive))
                case "fog":
                    let zones = fogZones(values["zones"])
                    var quad = fog(values, place: place, opacity: opacity, now: now, inputs: inputs)
                    if let zones {
                        quad.stopCount = Int32(zones.count)
                        quad.params2.w = zones.size
                        // The spots slide with the fog, at its depth, unless they name their own scroll.
                        let zoneScroll = values["zones"].map { ($0[member: "scrollX"].numberValue, $0[member: "scrollY"].numberValue) }
                        let zoneX = zoneScroll?.0.map { Float($0) } ?? quad.params2.y
                        let zoneY = zoneScroll?.1.map { Float($0) } ?? quad.params2.z
                        quad.brush = SIMD4(zones.share, zoneX, zoneY, 0)
                    }
                    scene.items.append(.quad(quad, stops: zones?.stops ?? Self.noStops, additive: additive))
                case "particles":
                    particles(values, place: place, opacity: opacity, additive: additive, now: now, data: inputs.data, into: &scene)
                default: break
                }
            }
        }
    }

    // MARK: Placement

    struct Placement {
        var origin: CGPoint
        var scale: Double
        var size: CGSize
        /// Layer points the shape travelled this frame, for its motion blur.
        var velocity: CGPoint = .zero

        func point(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float(origin.x + p.x * scale), Float(origin.y + p.y * scale)) }

        func quad(kind: Int32, opacity: Double) -> SkinGPUQuad {
            var quad = SkinGPUQuad(origin: SIMD2(Float(origin.x), Float(origin.y)), localSize: SIMD2(Float(size.width), Float(size.height)),
                                   scale: Float(scale), kind: kind, opacity: Float(opacity))
            quad.velocity = SIMD4(Float(velocity.x), Float(velocity.y), 0, 0)
            return quad
        }
    }

    /// How far this point travelled since the previous frame, from the camera's own move: the
    /// closed form of `cameraTransform`, inverted where the point is now and applied to the
    /// camera then. Scaled by the layer's `motionBlur`, and capped so a cut cannot smear the
    /// surface across itself.
    func cameraTravel(at point: CGPoint) -> CGPoint {
        guard motion > 0, let camera = frameCamera, let before = previousCamera, frameSize.width > 1 else { return .zero }
        let dx = camera.x - before.x, dy = camera.y - before.y, dz = camera.zoom - before.zoom
        guard abs(dx) > 1e-9 || abs(dy) > 1e-9 || abs(dz) > 1e-9 else { return .zero }
        let factor = 1 / (1 + max(-0.9, nodeDepth))
        let scale = 1 + (camera.zoom - 1) * factor
        let earlier = 1 + (before.zoom - 1) * factor
        guard abs(scale) > 1e-6 else { return .zero }
        let cx = frameSize.width / 2, cy = frameSize.height / 2
        var travel = CGPoint(x: (earlier / scale - 1) * (point.x - cx) + earlier * factor * dx,
                             y: (earlier / scale - 1) * (point.y - cy) + earlier * factor * dy)
        travel.x *= motion
        travel.y *= motion
        let length = hypot(travel.x, travel.y), cap = 96.0
        guard length <= cap else { return CGPoint(x: travel.x * cap / length, y: travel.y * cap / length) }
        return travel
    }

    /// A move scaled to the shutter, for the callers that measure their own travel.
    func shutterTravel(_ travel: CGPoint) -> CGPoint {
        guard motion > 0, travel.x != 0 || travel.y != 0 else { return .zero }
        return CGPoint(x: travel.x * motion, y: travel.y * motion)
    }

    /// A dot's streak, widened by the travel the camera gave it this frame.
    private func travelStreak(_ streak: SIMD2<Float>, at centre: SIMD2<Float>) -> SIMD2<Float> {
        let travel = cameraTravel(at: CGPoint(x: Double(centre.x), y: Double(centre.y)))
        guard travel.x != 0 || travel.y != 0 else { return streak }
        return streak + SIMD2(Float(travel.x), Float(travel.y))
    }

    /// The layer's `motionBlur`: a share of one frame's travel, 0 when it rests.
    private static func motionShare(_ value: SkinValue?) -> Double {
        guard let value else { return 0 }
        let share = value.numberValue ?? value[member: "strength"].number(1)
        return min(2, max(0, share))
    }

    /// `SkinSceneCamera.place` for every point of a child at `depth`.
    private func cameraTransform(_ camera: SkinSceneCamera?, depth: Double, size: CGSize) -> CGAffineTransform {
        guard let camera else { return .identity }
        let factor = 1 / (1 + max(-0.9, depth))
        let scale = 1 + (camera.zoom - 1) * factor
        let cx = size.width / 2, cy = size.height / 2
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: cx - (cx + camera.x * factor) * scale, ty: cy - (cy + camera.y * factor) * scale)
    }

    /// The node's frame centre and size in its parent, as the view renderer resolves them.
    private func frame(_ values: [String: SkinValue], parent: CGSize) -> (centre: CGPoint, size: CGSize) {
        let frame = values["frame"] ?? .null
        let viewport = inputs?.live?.size ?? inputs?.data.viewportSize ?? parent
        func dimension(_ value: SkinValue, horizontal: Bool, signed: Bool = false) -> Double? {
            skinDimension(value, horizontal: horizontal, signed: signed, viewport: viewport, parent: parent).map(Double.init)
        }
        let width = dimension(frame[member: "width"], horizontal: true) ?? dimension(frame[member: "size"], horizontal: true)
        let height = dimension(frame[member: "height"], horizontal: false) ?? dimension(frame[member: "size"], horizontal: false)
        let anchorName = frame[member: "anchor"].textValue
        let anchor = unitPoint(anchorName.isEmpty ? "center" : anchorName)
        let x = dimension(frame[member: "x"], horizontal: true, signed: true) ?? parent.width / 2
        let y = dimension(frame[member: "y"], horizontal: false, signed: true) ?? parent.height / 2
        return (CGPoint(x: x + (0.5 - anchor.x) * (width ?? 0), y: y + (0.5 - anchor.y) * (height ?? 0)),
                CGSize(width: width ?? parent.width, height: height ?? parent.height))
    }

    // MARK: Gradients and fog

    private static let noStops = [SIMD4<Float>](repeating: .zero, count: 10)

    private func stops(_ values: [String: SkinValue]) -> [SIMD4<Float>] {
        var entries: [(color: SIMD4<Float>, at: Float)] = (values["stops"]?.listValue ?? []).compactMap { stop in
            guard let color = stop[member: "color"].colorValue else { return nil }
            return (premultiplied(color), Float(stop[member: "at"].number().clamped01))
        }.sorted { $0.at < $1.at }
        if entries.isEmpty {
            let colors = (values["colors"]?.listValue ?? []).compactMap(\.colorValue)
            entries = colors.enumerated().map { (premultiplied($0.element), colors.count > 1 ? Float($0.offset) / Float(colors.count - 1) : 0) }
        }
        entries = Array(entries.prefix(8))
        var result = Self.noStops
        for (index, entry) in entries.enumerated() {
            result[index] = entry.color
            result[8 + index / 4][index % 4] = entry.at
        }
        return result
    }

    private func gradient(_ values: [String: SkinValue], place: Placement, opacity: Double) -> SkinGPUQuad {
        var quad = place.quad(kind: 1, opacity: opacity)
        quad.stopCount = Int32(min(8, max((values["stops"]?.listValue ?? []).filter { $0[member: "color"].colorValue != nil }.count,
                                          (values["colors"]?.listValue ?? []).compactMap(\.colorValue).count)))
        let modes: [String: Float] = ["radial": 1, "elliptical": 2, "light": 3]
        let mode = modes[values["mode"]?.textValue ?? ""] ?? 0
        let centre = unitPoint(values["start"]?.textValue ?? "center")
        // A light's `radius` is its core, a share of the frame's half size.
        let radius = values["radius"]?.number(mode == 3 ? SkinLightGradient.core : 0.5) ?? (mode == 3 ? SkinLightGradient.core : 0.5)
        quad.params = SIMD4(Float(radius), Float(centre.x), Float(centre.y), mode)
        let start = unitPoint(values["start"]?.textValue ?? "topLeading"), end = unitPoint(values["end"]?.textValue ?? "bottomTrailing")
        quad.params2 = SIMD4(Float(start.x * place.size.width), Float(start.y * place.size.height),
                             Float(end.x * place.size.width), Float(end.y * place.size.height))
        return quad
    }

    private func fog(_ values: [String: SkinValue], place: Placement, opacity: Double, now: Double, inputs: SkinGPULayerInputs) -> SkinGPUQuad {
        let colors = (values["colors"]?.listValue ?? []).compactMap(\.colorValue)
        let foreground = inputs.data.theme["theme.appForeground.primary"]?.colorValue
        var quad = place.quad(kind: 2, opacity: opacity)
        quad.color = colors.count > 1 ? premultiplied(colors[0]) : .zero
        quad.color2 = premultiplied(colors.last ?? foreground)
        let time = inputs.moves ? inputs.data.time(at: now).truncatingRemainder(dividingBy: 3600) : 0
        quad.params = SIMD4(Float(time), Float(max(1, values["size"]?.number(260) ?? 260)), Float(values["speed"]?.number(0.3) ?? 0.3),
                            Float(values["warp"]?.number(1.5) ?? 1.5))
        quad.params2 = SIMD4(Float(values["gain"]?.number(1.2) ?? 1.2), Float(values["scrollX"]?.number() ?? 0), Float(values["scrollY"]?.number() ?? 0), 0)
        return quad
    }

    /// A fog's `zones`: its smoke takes the first colour, and the rest tint it in small spots.
    /// `colors` are reduced to their distinct tones (a plain cover's tones of one hue make a
    /// single colour); `lightness` sets them to one level, keeping a little of their spread;
    /// `chroma` scales their colourfulness, the tints quieter than the lead and none louder
    /// than the dark allows. Returned in OKLab, the lead first and the tints ordered round the
    /// hue circle for the shader's ring. `size` is a spot's scale in points, `share` how often
    /// the spots appear (0 to 1). Nil when no colour has a hue, so the fog keeps its `colors`.
    private func fogZones(_ value: SkinValue?) -> (stops: [SIMD4<Float>], count: Int, size: Float, share: Float)? {
        guard let value else { return nil }
        let list = value.listValue.isEmpty ? value[member: "colors"].listValue : value.listValue
        let tones = list.compactMap(\.colorValue).filter { $0.chroma > 0.02 && $0.hue != nil }
        guard !tones.isEmpty else { return nil }
        let level = value[member: "lightness"].numberValue
        let chromaScale = max(0, value[member: "chroma"].number(1))
        let meanL = tones.map(\.lightness).reduce(0, +) / Double(tones.count)
        var lab: [SIMD3<Float>] = []
        for tone in tones.prefix(6) {
            // Oranges and yellows turn brown when dark, so a set level lifts them a little.
            let degrees = (tone.hue ?? 0) * 360
            let warm = max(0, 1 - abs(degrees - 75) / 45)
            let l = level.map { ($0 + 0.3 * (tone.lightness - meanL) + 0.06 * warm).clamped01 } ?? tone.lightness
            let chroma = min(0.36 * l, tone.chroma * chromaScale * (lab.isEmpty ? 1 : 0.6))
            let requested = OKLCHColor(lightness: l, chroma: chroma, hue: tone.hue, alpha: 1)
            let c = ColorRenderingAdapter.resolve(requested, target: .displayP3).resolvedChroma
            let h = degrees * .pi / 180
            let point = SIMD3(Float(l), Float(c * cos(h)), Float(c * sin(h)))
            // Tones of one colour, lighter or darker, count once.
            if lab.contains(where: { hypot($0.y - point.y, $0.z - point.z) < 0.04 && abs($0.x - point.x) < 0.1 }) { continue }
            lab.append(point)
        }
        // The tints are read as a ring, each passing only into its neighbours, so they go round
        // the hue circle starting from the lead's hue.
        if lab.count > 2 {
            let leadHue = atan2(lab[0].z, lab[0].y)
            func turn(_ point: SIMD3<Float>) -> Float {
                let d = atan2(point.z, point.y) - leadHue
                return d < 0 ? d + 2 * .pi : d
            }
            lab = [lab[0]] + lab.dropFirst().sorted { turn($0) < turn($1) }
        }
        var stops = Self.noStops
        for (index, point) in lab.enumerated() { stops[index] = SIMD4(point, 0) }
        let size = max(1, value[member: "size"].number(900))
        let share = value[member: "share"].number(0.5).clamped01
        return (stops, lab.count, Float(size), Float(share))
    }

    // MARK: Shapes and comets

    private func strokeStyle(_ values: [String: SkinValue]) -> (width: Double, color: OKLCHColor?)? {
        guard let stroke = values["stroke"] else { return nil }
        let color = stroke[member: "color"].colorValue ?? inputs?.data.theme["theme.appForeground.primary"]?.colorValue
        return (max(0, stroke.numberValue ?? stroke[member: "width"].number(1)), color)
    }

    /// A circle or ellipse filling the frame: its outline centred on the edge, as SwiftUI strokes
    /// a shape, and its fill when it names a `color` or has no `stroke`.
    private func ellipse(_ values: [String: SkinValue], color: OKLCHColor?, place: Placement, opacity: Double) -> SkinGPUQuad {
        let stroke = strokeStyle(values)
        let half = (stroke?.width ?? 0) / 2
        let sigma = max(0, values["blur"]?.number() ?? 0) * 0.5
        // Room for the half of this frame's travel the ring is drawn across.
        let travel = hypot(place.velocity.x, place.velocity.y) / 2 / max(place.scale, 1e-4)
        let size = place.size
        let brush = stroke == nil ? nil : brushStyle(values)
        // A painted ring's outer strokes reach a little past its edge.
        let drift: Double = brush.map { (b: Brush) -> Double in half * (0.25 + 0.3 * b.wobble) } ?? 0
        let pad = half + 3 * sigma + 2 + travel + drift
        var quad = Placement(origin: CGPoint(x: place.origin.x - pad * place.scale - place.velocity.x / 2,
                                             y: place.origin.y - pad * place.scale - place.velocity.y / 2),
                             scale: place.scale,
                             size: CGSize(width: size.width + 2 * pad, height: size.height + 2 * pad), velocity: place.velocity).quad(kind: 3, opacity: opacity)
        quad.color = stroke.map { premultiplied($0.color) } ?? .zero
        quad.color2 = stroke == nil || values["color"] != nil ? premultiplied(color) : .zero
        quad.params = SIMD4(Float(half), Float(sigma), Float(size.width / 2), Float(size.height / 2))
        quad.params2 = SIMD4(Float(pad + size.width / 2), Float(pad + size.height / 2), 0, 0)
        if let brush { quad.brush = SIMD4(Float(brush.amount), Float(brush.dry), Float(brush.wobble), Float(brush.seed)) }
        return quad
    }

    // MARK: Brush

    /// A node's `brush`: painted-stroke texture, borrowed from the brush art plan's flat brush.
    /// `amount` (0…1) sets torn edges, bristle streaks and tone; `dry` (0…1) how far the paint
    /// runs dry towards the stroke's end; `wobble` (0…1) how far a hand-drawn ring drifts off
    /// the true outline. A number is the amount alone; 0 keeps the smooth geometric line.
    struct Brush {
        var amount: Double
        var dry: Double
        var wobble: Double
        var seed: Double
        /// How far a `path` drawn by hand strays from its exact shape (0 keeps it exact).
        var warp: Double = 0
    }

    private func brushStyle(_ values: [String: SkinValue]) -> Brush? {
        guard let value = values["brush"] else { return nil }
        let amount = (value.numberValue ?? value[member: "amount"].number(1)).clamped01
        guard amount > 0.001 else { return nil }
        let wobble = value[member: "wobble"].number(0.5).clamped01
        return Brush(amount: amount, dry: value[member: "dry"].number(0.6).clamped01, wobble: wobble,
                     seed: value[member: "seed"].numberValue ?? values["seed"]?.number() ?? 0,
                     warp: max(0, value[member: "warp"].numberValue ?? wobble))
    }

    /// A shape's outline as a hand draws it, in the shape's own points so it holds still under
    /// the camera: the whole shape bends a little out of true, the line trembles finely, and a
    /// closed outline runs on past its start and misses it, instead of meeting it exactly.
    /// `points` are already smoothed; returns the new points and whether they still close.
    private func handDrawn(_ points: [CGPoint], closed: Bool, size: CGSize, width: Double, brush: Brush) -> (points: [CGPoint], closed: Bool) {
        guard brush.warp > 0.001, points.count > 2 else { return (points, closed) }
        let extent = max(1, Double(max(size.width, size.height)))
        let salt = brush.seed * 1.37 + 5.1
        var run = points
        if closed {
            // Carry on past the start for a short overlap; the miss below keeps the ends apart.
            var total = 0.0
            for i in 1..<run.count { total += Double(hypot(run[i].x - run[i - 1].x, run[i].y - run[i - 1].y)) }
            let over = total * (0.04 + 0.08 * hash(salt, 3))
            var gone = 0.0
            for i in 1..<points.count where gone < over {
                gone += Double(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
                run.append(points[i])
            }
        }
        let bend = extent * 0.6, bendSize = extent * 0.055 * brush.warp
        let tremble = max(14, 2.5 * width), trembleSize = min(0.35 * width, 0.015 * extent) * brush.warp
        let turn = hash(salt, 7) * 2 * .pi, miss = extent * 0.035 * brush.warp
        let last = Double(max(1, run.count - 1))
        func field(_ x: Double, _ y: Double, _ salt: Double) -> Double {
            let ix = floor(x), iy = floor(y), fx = x - ix, fy = y - iy
            let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
            func corner(_ i: Double, _ j: Double) -> Double { hash(i + j * 57.31, salt) }
            let top = corner(ix, iy) * (1 - ux) + corner(ix + 1, iy) * ux
            let bottom = corner(ix, iy + 1) * (1 - ux) + corner(ix + 1, iy + 1) * ux
            return 2 * (top * (1 - uy) + bottom * uy) - 1
        }
        let warped = run.enumerated().map { (i, p) -> CGPoint in
            let x = Double(p.x), y = Double(p.y)
            let drift = closed ? Double(i) / last : 0
            let dx = bendSize * field(x / bend, y / bend, salt + 11) + trembleSize * field(x / tremble, y / tremble, salt + 23)
                + miss * drift * cos(turn)
            let dy = bendSize * field(x / bend + 4.3, y / bend, salt + 13) + trembleSize * field(x / tremble, y / tremble + 7.7, salt + 29)
                + miss * drift * sin(turn)
            return CGPoint(x: x + dx, y: y + dy)
        }
        return (warped, false)
    }

    /// A painted stroke along `points` (tail to head): it widens from the dry tail to `width`
    /// at the head, ends in a round wet tip just ahead of it, and hands the shader its brush
    /// coordinates. `along` is each point's distance from where the flight began, so the bristle
    /// streaks stay where they were laid while the comet moves on.
    private func brushRibbon(_ points: [CGPoint], along: [Double], width: Double, color: OKLCHColor?, alpha: Double, brush: Brush,
                             place: Placement, into scene: inout SkinGPUScene) {
        guard points.count > 2, along.count == points.count, width > 0.1 else { return }
        var lengths = [0.0]
        for index in points.indices.dropFirst() {
            lengths.append(lengths[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
        }
        let total = lengths.last ?? 0
        guard total > 1 else { return }
        struct Sample { var point: CGPoint; var normal: CGPoint; var half: Double; var along: Double; var shade: Float; var need: Double }
        let unit = 1 / (2 * width)
        var spine: [Sample] = []
        spine.reserveCapacity(points.count + 6)
        for index in points.indices {
            let a = points[max(0, index - 1)], b = points[min(points.count - 1, index + 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(0.0001, hypot(dx, dy))
            let u = lengths[index] / total
            // The hand presses and eases as it goes and wanders a little off the line; the paint
            // thins and dries towards the tail.
            let press = 0.66 + 0.68 * noise(along[index] * unit * 0.35, brush.seed)
            let normal = CGPoint(x: -dy / length, y: dx / length)
            let shift = width * brush.amount * 0.45 * (noise(along[index] * unit * 0.22, brush.seed + 17) - 0.5)
            let point = CGPoint(x: points[index].x + normal.x * shift, y: points[index].y + normal.y * shift)
            spine.append(Sample(point: point, normal: normal, half: width * pow(u, 0.5) * press,
                                along: along[index] * unit, shade: Float(alpha * pow(u, 1.5)), need: brush.dry * pow(1 - u, 0.8)))
        }
        // The wet tip: a round end as wide as the stroke at the head.
        if let last = spine.last {
            let ahead = CGPoint(x: last.normal.y, y: -last.normal.x)
            for step in 1...6 {
                let x = Double(step) / 6, reach = last.half * x
                spine.append(Sample(point: CGPoint(x: last.point.x + ahead.x * reach, y: last.point.y + ahead.y * reach), normal: last.normal,
                                    half: last.half * sqrt(max(0, 1 - x * x)), along: last.along + reach * unit, shade: last.shade, need: 0))
            }
        }
        let ink = premultiplied(color)
        // A point and a half beyond each edge, so the shader can smooth it.
        let margin = 1.5
        func vertex(_ s: Sample, _ side: Double) -> SkinGPUVertex {
            let half = max(0.05, s.half), reach = half + margin
            return SkinGPUVertex(position: place.point(CGPoint(x: s.point.x + s.normal.x * reach * side, y: s.point.y + s.normal.y * reach * side)),
                                 edge: SIMD2(Float(reach / half * side), 0), color: ink * s.shade,
                                 blur: SIMD4(Float(brush.seed), Float(s.along), Float(s.need), Float(brush.amount)))
        }
        for index in 0..<(spine.count - 1) where spine[index].shade > 0.001 || spine[index + 1].shade > 0.001 {
            let a = spine[index], b = spine[index + 1]
            scene.vertices.append(contentsOf: [vertex(a, 1), vertex(a, -1), vertex(b, 1), vertex(a, -1), vertex(b, -1), vertex(b, 1)])
        }
    }

    /// A Catmull-Rom curve through `points`, sampled about every `spacing` (in the points' own
    /// units). A closed run repeats its first point at the end, and its neighbours wrap.
    /// The part of `run` between `from` and `to` points along it, ends interpolated.
    nonisolated static func cut(_ run: [CGPoint], from: Double, to: Double) -> [CGPoint] {
        guard run.count > 1, to > 0 else { return [] }
        var kept: [CGPoint] = [], walked = 0.0
        for i in 1..<run.count {
            let a = run[i - 1], b = run[i]
            let step = Double(hypot(b.x - a.x, b.y - a.y))
            let next = walked + step
            defer { walked = next }
            guard next > from, step > 1e-9 else { continue }
            if walked >= to { break }
            func at(_ d: Double) -> CGPoint {
                let t = CGFloat(min(1, max(0, (d - walked) / step)))
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            if kept.isEmpty { kept.append(walked >= from ? a : at(from)) }
            if next <= to { kept.append(b) } else { kept.append(at(to)); break }
        }
        return kept
    }

    nonisolated static func smoothed(_ points: [CGPoint], closed: Bool, spacing: Double) -> [CGPoint] {
        let count = points.count
        guard count > 1, spacing > 0 else { return points }
        let wraps = closed && count > 3
        func at(_ i: Int) -> CGPoint {
            if wraps {
                let n = count - 1
                return points[((i % n) + n) % n]
            }
            return points[min(count - 1, max(0, i))]
        }
        func curve(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ t: Double) -> Double {
            let t2 = t * t, t3 = t2 * t
            let k1: Double = c - a
            let k2: Double = 2 * a - 5 * b + 4 * c - d
            let k3: Double = 3 * b - a - 3 * c + d
            return 0.5 * (2 * b + k1 * t + k2 * t2 + k3 * t3)
        }
        var result: [CGPoint] = [points[0]]
        result.reserveCapacity(count * 4)
        for i in 0..<(count - 1) {
            let p0 = at(i - 1), p1 = points[i], p2 = points[i + 1], p3 = at(i + 2)
            let length = Double(hypot(p2.x - p1.x, p2.y - p1.y))
            let steps = max(1, min(32, Int((length / spacing).rounded(.up))))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let x = curve(Double(p0.x), Double(p1.x), Double(p2.x), Double(p3.x), t)
                let y = curve(Double(p0.y), Double(p1.y), Double(p2.y), Double(p3.y), t)
                result.append(CGPoint(x: x, y: y))
            }
        }
        return result
    }

    /// Smooth value noise along one axis, 0…1.
    private func noise(_ x: Double, _ salt: Double) -> Double {
        let i = floor(x), f = x - i
        let u = f * f * (3 - 2 * f)
        return hash(i, salt) * (1 - u) + hash(i + 1, salt) * u
    }

    /// A `path` shape's stroke as a ribbon that fades across its width, trimmed, turned about the
    /// frame's centre, blurred, and faded by its angular gradient mask, which stays unturned.
    private func stroke(_ values: [String: SkinValue], mask: [String: SkinValue]?, frame: (centre: CGPoint, size: CGSize), world: CGAffineTransform,
                        opacity: Double, additive: Bool, pixelsPerPoint: Double, into scene: inout SkinGPUScene) {
        guard let style = strokeStyle(values), style.width > 0 else { return }
        let size = frame.size
        var path = SkinSceneShape(kind: "path", points: values["points"]?.textValue ?? "").path(in: CGRect(origin: .zero, size: size))
        let from = (values["trimStart"]?.number() ?? 0).clamped01, to = (values["trimEnd"]?.number(1) ?? 1).clamped01
        guard to > from else { return }
        let brush = brushStyle(values)
        // A painted path is drawn by hand first and trimmed along the drawn line afterwards, so it
        // keeps one shape while the pen is still moving.
        if brush == nil, from > 0 || to < 1 { path = path.trimmedPath(from: from, to: to) }
        // Frame points to the parent's, turned about the frame's centre.
        let toParent = CGAffineTransform(translationX: frame.centre.x, y: frame.centre.y)
            .rotated(by: (values["rotation"]?.number() ?? 0) * .pi / 180)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        let scale = sqrt(abs(world.a * world.d - world.b * world.c))
        let half = style.width / 2 * scale
        let sigma = max(0, values["blur"]?.number() ?? 0) * 0.5 * scale
        let reach = half + 3 * sigma + 1.5 / max(0.5, pixelsPerPoint)
        let ink = premultiplied(style.color, alpha: opacity)
        let maskStops: [(color: SIMD4<Float>, at: Double)]? = mask.map { mask in
            (mask["stops"]?.listValue ?? []).compactMap { stop in
                stop[member: "color"].colorValue.map { (premultiplied($0, alpha: mask["opacity"]?.number(1) ?? 1), stop[member: "at"].number().clamped01) }
            }.sorted { $0.at < $1.at }
        }
        let maskTurn = mask?["rotation"]?.number() ?? 0
        func maskAlpha(_ point: CGPoint) -> Float {
            guard let stops = maskStops, let first = stops.first else { return 1 }
            var turn = (atan2(point.y - frame.centre.y, point.x - frame.centre.x) * 180 / .pi - maskTurn) / 360
            turn -= floor(turn)
            guard turn > first.at else { return first.color.w }
            for index in stops.indices.dropFirst() where turn <= stops[index].at {
                let a = stops[index - 1], b = stops[index]
                let t = Float((turn - a.at) / max(1e-4, b.at - a.at))
                return a.color.w + (b.color.w - a.color.w) * t
            }
            return stops[stops.count - 1].color.w
        }
        var runs: [[CGPoint]] = [], run: [CGPoint] = [], closed: [Bool] = []
        func finish(_ isClosed: Bool) {
            if run.count > 1 { runs.append(run); closed.append(isClosed) }
            run = []
        }
        path.forEach { element in
            switch element {
            case .move(let to): finish(false); run = [to]
            case .line(let to): run.append(to)
            case .quadCurve(let to, let control):
                let from = run.last ?? to
                for step in 1...12 {
                    let t = Double(step) / 12, u = 1 - t
                    run.append(CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x, y: u * u * from.y + 2 * u * t * control.y + t * t * to.y))
                }
            case .curve(let to, let c1, let c2):
                let from = run.last ?? to
                for step in 1...16 {
                    let t = Double(step) / 16, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    run.append(CGPoint(x: a * from.x + b * c1.x + c * c2.x + d * to.x, y: a * from.y + b * c1.y + c * c2.y + d * to.y))
                }
            case .closeSubpath:
                if let first = run.first { run.append(first) }
                finish(true)
            }
        }
        finish(false)
        if let brush {
            // A painted line follows a smooth curve through its points, sampled every few points
            // on screen so it shows no polyline corners, then strays from it the way a hand does.
            let spacing = max(1.5, min(4, Double(half))) / max(Double(scale), 1e-3)
            for index in runs.indices {
                let drawn = handDrawn(Self.smoothed(runs[index], closed: closed[index], spacing: spacing), closed: closed[index],
                                      size: size, width: Double(style.width), brush: brush)
                runs[index] = drawn.points
                closed[index] = drawn.closed
            }
            if from > 0 || to < 1 {
                let spans = runs.map { run in zip(run, run.dropFirst()).reduce(0.0) { $0 + Double(hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)) } }
                let total = spans.reduce(0, +)
                var start = 0.0, kept: [[CGPoint]] = [], keptClosed: [Bool] = []
                for index in runs.indices {
                    let piece = Self.cut(runs[index], from: from * total - start, to: to * total - start)
                    if piece.count > 1 { kept.append(piece); keptClosed.append(closed[index] && from <= 0 && to >= 1) }
                    start += spans[index]
                }
                runs = kept
                closed = keptClosed
            }
        }
        let first = scene.vertices.count
        for (index, run) in runs.enumerated() {
            let points = run
            let parent = points.map { $0.applying(toParent) }
            let layer = parent.map { $0.applying(world) }
            let loops = closed[index] && layer.count > 2
            let count = layer.count
            var normals: [CGPoint] = []
            normals.reserveCapacity(count)
            func normal(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                let dx = b.x - a.x, dy = b.y - a.y, length = max(1e-6, hypot(dx, dy))
                return CGPoint(x: -dy / length, y: dx / length)
            }
            for i in 0..<count {
                let before = i > 0 ? normal(layer[i - 1], layer[i]) : loops ? normal(layer[count - 2], layer[0]) : nil
                let after = i < count - 1 ? normal(layer[i], layer[i + 1]) : loops ? normal(layer[0], layer[1]) : nil
                guard let n1 = before ?? after, let n2 = after ?? before else { normals.append(.zero); continue }
                let sum = CGPoint(x: n1.x + n2.x, y: n1.y + n2.y), length = hypot(sum.x, sum.y)
                guard length > 1e-6 else { normals.append(n1); continue }
                let n = CGPoint(x: sum.x / length, y: sum.y / length)
                // A miter keeps the width through the bend, up to twice the reach.
                let miter = 1 / max(0.5, n.x * n1.x + n.y * n1.y)
                normals.append(CGPoint(x: n.x * miter, y: n.y * miter))
            }
            let shades = parent.map { ink * maskAlpha($0) }
            // Distances along the run in the shape's own points, so the pressure and the paint
            // stay fixed to the shape while the camera pans, zooms and turns.
            var lengths = [0.0]
            if brush != nil {
                for i in 1..<count { lengths.append(lengths[i - 1] + Double(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))) }
            }
            let runLength = max(1e-3, lengths.last ?? 0)
            // Signed curvature (1 / radius, positive toward +normal) at each point: on the inside
            // of a tight bend the strip may reach no further than the bend's centre, or it folds
            // over and throws out spikes.
            var bends = [Double](repeating: 0, count: brush == nil ? 0 : count)
            if brush != nil {
                for i in 0..<count {
                    let a = i > 0 ? i - 1 : loops ? count - 2 : -1
                    let c = i < count - 1 ? i + 1 : loops ? 1 : -1
                    guard a >= 0, c >= 0 else { continue }
                    let d1x = Double(layer[i].x - layer[a].x), d1y = Double(layer[i].y - layer[a].y)
                    let d2x = Double(layer[c].x - layer[i].x), d2y = Double(layer[c].y - layer[i].y)
                    let l1 = hypot(d1x, d1y), l2 = hypot(d2x, d2y)
                    guard l1 > 1e-6, l2 > 1e-6 else { continue }
                    bends[i] = (d1x * d2y - d1y * d2x) / (l1 * l2) / (0.5 * (l1 + l2))
                }
            }
            func vertex(_ i: Int, _ side: Double) -> SkinGPUVertex {
                let p = layer[i], n = normals[i]
                if let brush {
                    // A painted stroke along the shape's own line: the hand sways a little and
                    // slowly, presses and eases, lands a little blunt and lifts off into a tip
                    // whose hairs split dry. Everything is measured in the shape's own points.
                    let halfWidth = Double(half), blur = Double(sigma)
                    let localWidth: Double = max(1e-3, Double(style.width))
                    let t: Double = lengths[i] / runLength
                    let along: Double = lengths[i] / localWidth
                    let salt: Double = brush.seed + Double(index) * 3.7
                    let land: Double = 0.55 + 0.45 * SkinCometPath.smooth(lengths[i] / (0.7 * localWidth))
                    let tail: Double = min(1, max(0, (runLength - lengths[i]) / ((1.4 + 0.8 * hash(salt, 41)) * localWidth)))
                    let lift: Double = land * pow(tail, 0.65) * (1 - 0.25 * SkinCometPath.smooth((t - 0.6) / 0.4))
                    let pace: Double = lengths[i] / max(40, 3 * localWidth)
                    let press: Double = (1 + (0.15 + 0.3 * brush.wobble) * (2 * noise(pace, salt) - 1)) * lift
                    let width: Double = max(0.05, halfWidth * press)
                    let sway: Double = Double(scale) * min(0.45 * localWidth, 5) * brush.wobble
                    let shift: Double = sway * (2 * noise(lengths[i] / 70, salt + 17) - 1)
                    let out: Double = width + 3 * blur + 1.5 / max(0.5, Double(pixelsPerPoint))
                    var offset: Double = shift + out * side
                    let stretch: Double = max(1, Double(hypot(n.x, n.y)))
                    if bends[i] > 1e-6 { offset = min(offset, 0.9 / bends[i] / stretch) }
                    if bends[i] < -1e-6 { offset = max(offset, 0.9 / bends[i] / stretch) }
                    let x = Double(p.x) + Double(n.x) * offset, y = Double(p.y) + Double(n.y) * offset
                    let need: Double = brush.dry * (0.1 + 0.8 * t) + 0.55 * (1 - tail)
                    return SkinGPUVertex(position: SIMD2(Float(x), Float(y)), edge: SIMD2(Float((offset - shift) / width), Float(2.5 * blur / width)),
                                         color: shades[i], blur: SIMD4(Float(salt), Float(along), Float(need), Float(brush.amount)))
                }
                return SkinGPUVertex(position: SIMD2(Float(p.x + n.x * reach * side), Float(p.y + n.y * reach * side)),
                                     edge: SIMD2(Float(reach * side), Float(half)), color: shades[i], blur: SIMD4(Float(sigma), 0, 0, 0))
            }
            for i in 0..<(count - 1) where shades[i].w > 0.001 || shades[i + 1].w > 0.001 {
                scene.vertices.append(contentsOf: [vertex(i, 1), vertex(i, -1), vertex(i + 1, 1), vertex(i, -1), vertex(i + 1, -1), vertex(i + 1, 1)])
            }
        }
        if scene.vertices.count > first { scene.items.append(.ribbons(first..<scene.vertices.count, additive: additive)) }
    }

    /// `SkinSceneComet`: the head flies in, circles the frame's centre and leaves, its tail the
    /// path it has just travelled; `rotation` turns the flight about the centre.
    private func comet(_ values: [String: SkinValue], place: Placement, opacity: Double, additive: Bool, into scene: inout SkinGPUScene) {
        let orbit = values["orbit"]?.listValue.map { $0.number() } ?? []
        let rx = max(1, orbit.first ?? 120), ry = max(1, orbit.count > 1 ? orbit[1] : rx * 0.62)
        let progress = values["progress"]?.number() ?? 0
        guard progress > 0, progress < 1 else { return }
        let start = (values["angle"]?.number() ?? 180) * .pi / 180
        let sweep = (values["sweep"]?.number() ?? 300) * .pi / 180
        let trail = min(0.6, max(0.01, values["trail"]?.number() ?? 0.12))
        let head = max(0.5, values["size"]?.number() ?? 3)
        let width = max(head, values["width"]?.number() ?? head)
        let seed = values["seed"]?.number() ?? 0
        let color = values["color"]?.colorValue
        // The comet's fade and arc follow the drawn path, as the Canvas renderer draws them.
        let alpha = SkinCometPath.smooth(progress / 0.1) * (1 - SkinCometPath.smooth((progress - 0.82) / 0.18)) * opacity
        guard alpha > 0.001 else { return }
        let centre = CGPoint(x: place.size.width / 2, y: place.size.height / 2)
        let turn = (values["rotation"]?.number() ?? 0) * .pi / 180
        let (c, s) = (cos(turn), sin(turn))
        func point(_ s0: Double) -> CGPoint {
            let t = min(1, max(0, s0))
            // The comet's fade and arc follow the drawn path, as the Canvas renderer draws them.
            let arrive = 1 - SkinCometPath.smooth(t / 0.34)
            let leave = SkinCometPath.smooth((t - 0.7) / 0.3)
            let wobble = 0.07 * sin(2 * .pi * (t * 1.4) + seed * 5.1)
            let rho = 1 + 1.7 * arrive * arrive + 1.3 * leave * leave + wobble
            let theta = start + sweep * t
            let x = rx * rho * cos(theta), y = ry * rho * sin(theta)
            return CGPoint(x: centre.x + x * c - y * s, y: centre.y + x * s + y * c)
        }
        let tail = max(0, progress - trail)
        var times = (0...60).map { tail + (progress - tail) * Double($0) / 60 }
        var points = times.map { point($0) }
        // The tail stays about as long as the orbit is wide, as the view draws it.
        let maxLength = 1.2 * max(rx, ry)
        var lengths = [0.0]
        for index in points.indices.dropFirst() {
            lengths.append(lengths[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
        }
        if let full = lengths.last, full > maxLength, let index = lengths.firstIndex(where: { $0 >= full - maxLength }), index > 0 {
            let a = points[index - 1], b = points[index]
            let t = (full - maxLength - lengths[index - 1]) / max(0.0001, lengths[index] - lengths[index - 1])
            points = [CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)] + points[index...]
            times = [times[index - 1] + (times[index] - times[index - 1]) * t] + times[index...]
        }
        let first = scene.vertices.count
        if let brush = brushStyle(values) {
            // A painted comet: no solid head; the stroke itself ends in a wet round tip. The
            // flight's length turns each sample's time into a place along the stroke.
            var span = 0.0, last = point(0)
            for step in 1...48 {
                let next = point(Double(step) / 48)
                span += hypot(next.x - last.x, next.y - last.y)
                last = next
            }
            brushRibbon(points, along: times.map { $0 * span }, width: width, color: color, alpha: alpha, brush: brush, place: place, into: &scene)
            if scene.vertices.count > first { scene.items.append(.ribbons(first..<scene.vertices.count, additive: additive)) }
            return
        }
        ribbon(points, width: min(width, head), color: color, alpha: alpha, place: place, into: &scene)
        if scene.vertices.count > first { scene.items.append(.ribbons(first..<scene.vertices.count, additive: additive)) }
        guard let front = points.last else { return }
        let dot = scene.dots.count
        let headPoint = place.point(front)
        scene.dots.append(SkinGPUDot(centre: headPoint, streak: travelStreak(.zero, at: headPoint), radius: Float(head * place.scale), soft: 0,
                                     color: premultiplied(color, alpha: alpha)))
        scene.items.append(.dots(dot..<scene.dots.count, additive: additive))
    }

    // MARK: Particles (the same motion as `SkinSceneParticles`)

    private func particles(_ values: [String: SkinValue], place: Placement, opacity: Double, additive: Bool, now: Double, data: SkinSceneData,
                           into scene: inout SkinGPUScene) {
        let size = place.size
        let scroll = ((values["scrollX"]?.number() ?? 0) / max(1, size.width), (values["scrollY"]?.number() ?? 0) / max(1, size.height))
        let blur = (values["filter"].map { $0.type == .list ? $0.listValue : [$0] } ?? []).first { $0[member: "type"].textValue == "motionBlur" }
        let streak = SIMD2(Float(blur?[member: "x"].number() ?? 0), Float(blur?[member: "y"].number() ?? 0)) * Float(place.scale)
        let firstDot = scene.dots.count, firstVertex = scene.vertices.count
        if let lifetime = values["lifetime"]?.numberValue, lifetime > 0 {
            emit(values, lifetime: lifetime, place: place, opacity: opacity, scroll: scroll, streak: streak, now: now, data: data, into: &scene)
        } else {
            let count = max(1, min(1024, values["count"]?.integer(80) ?? 80))
            let time = data.time(at: now) * (values["speed"]?.number(0.1) ?? 0.1)
            let color = values["color"]?.colorValue
            let radius = values["size"]?.number(2) ?? 2
            let seed = values["seed"]?.number() ?? 0
            let soft = max(0, values["soft"]?.number() ?? 0)
            scene.dots.reserveCapacity(scene.dots.count + count)
            for index in 0..<count {
                let n = Double(index) + seed
                let drift = fract(sin(n * 311.7 + 7) * 96321.912 + time * (0.2 + fract(sin(n * 127.1 + 4) * 43758.5453)))
                let x = fract(sin(n * 127.1 + 4) * 43758.5453 - scroll.0)
                let y = fract(drift + scroll.1)
                let centre = place.point(CGPoint(x: x * size.width + radius, y: (1 - y) * size.height + radius))
                scene.dots.append(SkinGPUDot(centre: centre, streak: travelStreak(streak, at: centre), radius: Float(radius * place.scale),
                                             soft: Float(soft * place.scale), color: premultiplied(color, alpha: (0.2 + x * 0.7) * opacity)))
            }
        }
        if scene.vertices.count > firstVertex { scene.items.append(.ribbons(firstVertex..<scene.vertices.count, additive: additive)) }
        if scene.dots.count > firstDot { scene.items.append(.dots(firstDot..<scene.dots.count, additive: additive)) }
    }

    private func emit(_ values: [String: SkinValue], lifetime: Double, place: Placement, opacity: Double, scroll: (Double, Double), streak: SIMD2<Float>,
                      now: Double, data: SkinSceneData, into scene: inout SkinGPUScene) {
        let size = place.size
        let count = max(1, min(512, values["count"]?.integer(12) ?? 12))
        let time = data.time(at: now)
        let colors = (values["colors"]?.listValue ?? []).compactMap(\.colorValue)
        let palette: [OKLCHColor?] = colors.isEmpty ? [values["color"]?.colorValue] : colors
        let radius = values["size"]?.number(2) ?? 2
        let seed = values["seed"]?.number() ?? 0
        let angle = (values["angle"]?.number(-90) ?? -90) * .pi / 180
        let spread = (values["spread"]?.number(20) ?? 20) * .pi / 180
        let speed = values["speed"]?.number(120) ?? 120
        let trail = max(0, values["trail"]?.number() ?? 0)
        let turbulence = max(0, values["turbulence"]?.number() ?? 0)
        let wander = max(0.01, values["wander"]?.number() ?? 0.65)
        let curve = values["curve"]?.number() ?? 0
        let brush = trail > 0 ? brushStyle(values) : nil
        // A painted tail's half width at the size `size` names; each particle scales it with its head.
        let brushWidth = values["width"]?.numberValue ?? radius * 3
        for index in 0..<count {
            let n = Double(index) + seed * 101
            let local = time / lifetime + hash(n, 1)
            let cycle = floor(local), t = local - cycle
            let key = n + cycle * 7.13
            let x0 = fract(hash(key, 2) - scroll.0) * size.width, y0 = fract(hash(key, 3) - scroll.1) * size.height
            let direction = angle + (hash(key, 4) - 0.5) * spread
            let velocity = speed * (0.45 + 1.1 * hash(key, 5))
            let sway = turbulence * (0.4 + 1.2 * hash(key, 8))
            let pace = wander * (0.6 + 0.8 * hash(key, 10))
            let phase = hash(key, 9) * 2 * .pi
            let bend = curve * (hash(key, 11) * 2 - 1)
            let forward = CGPoint(x: cos(direction), y: sin(direction)), side = CGPoint(x: -forward.y, y: forward.x)
            func point(_ t: Double) -> CGPoint {
                let travel = t * lifetime
                let along = velocity * travel
                let across = sway * (sin(travel * pace + phase) - sin(phase)) + 0.5 * bend * velocity * travel * travel
                return CGPoint(x: x0 + forward.x * along + side.x * across, y: y0 + forward.y * along + side.y * across)
            }
            let head = point(t)
            let alpha = sin(.pi * t) * opacity
            let color = palette[Int(hash(n, 6) * Double(palette.count)) % palette.count]
            let dot = radius * (0.6 + 0.8 * hash(n, 7))
            let headRadius = max(dot, 1.2)
            if trail > 0, t > 0, alpha > 0.001 {
                let tailTime = max(0, t - trail * (0.7 + 0.6 * hash(key, 12)) / lifetime)
                let times = (0...28).map { tailTime + (t - tailTime) * Double($0) / 28 }
                let points = times.map { point($0) }
                if var brush {
                    // Painted: the stroke ends in its own wet tip, so no solid head is drawn.
                    brush.seed += key
                    brushRibbon(points, along: times.map { velocity * $0 * lifetime }, width: brushWidth * dot / max(radius, 1e-4),
                                color: color, alpha: alpha, brush: brush, place: place, into: &scene)
                    continue
                }
                ribbon(points, width: headRadius, color: color, alpha: alpha, place: place, into: &scene)
            }
            guard alpha > 0.001 else { continue }
            let headPoint = place.point(head)
            scene.dots.append(SkinGPUDot(centre: headPoint, streak: travelStreak(streak, at: headPoint), radius: Float(headRadius * place.scale), soft: 0,
                                         color: premultiplied(color, alpha: alpha)))
        }
    }

    /// The tapered tail of `SkinCometPath`: it widens from nothing to `width` and fades in by
    /// the share of its length, as the Canvas path's gradient does.
    private func ribbon(_ points: [CGPoint], width: Double, color: OKLCHColor?, alpha: Double, place: Placement, into scene: inout SkinGPUScene) {
        var lengths = [0.0]
        for index in points.indices.dropFirst() {
            lengths.append(lengths[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
        }
        let total = lengths.last ?? 0
        guard total > 1, points.count > 2 else { return }
        let ink = premultiplied(color)
        var left: [SkinGPUVertex] = [], right: [SkinGPUVertex] = []
        for index in points.indices {
            let a = points[max(0, index - 1)], b = points[min(points.count - 1, index + 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(0.0001, hypot(dx, dy))
            let u = lengths[index] / total
            let half = width * pow(u, 1.6)
            let shade = ink * Float(alpha * pow(u, 2.2))
            left.append(SkinGPUVertex(position: place.point(CGPoint(x: points[index].x - dy / length * half, y: points[index].y + dx / length * half)), color: shade))
            right.append(SkinGPUVertex(position: place.point(CGPoint(x: points[index].x + dy / length * half, y: points[index].y - dx / length * half)), color: shade))
        }
        for index in 0..<(points.count - 1) {
            scene.vertices.append(contentsOf: [left[index], right[index], left[index + 1], right[index], right[index + 1], left[index + 1]])
        }
    }

    private func hash(_ n: Double, _ salt: Double) -> Double { fract(sin(n * 127.1 + salt * 311.7) * 43758.5453) }
    private func fract(_ value: Double) -> Double { value - floor(value) }

    func premultiplied(_ color: OKLCHColor?, alpha: Double = 1) -> SIMD4<Float> {
        guard let color = color?.nsColor.usingColorSpace(.displayP3) else { return .zero }
        let a = Float(color.alphaComponent * alpha)
        return SIMD4(Float(color.redComponent) * a, Float(color.greenComponent) * a, Float(color.blueComponent) * a, a)
    }
}

/// Sizes stay non-negative; `signed` positions may lie left of or above the parent.
func skinDimension(_ value: SkinValue, horizontal: Bool, signed: Bool, viewport: CGSize, parent: CGSize) -> CGFloat? {
    let floor = signed ? -Double.infinity : 0
    if let number = value.numberValue { return CGFloat(max(floor, number)) }
    let text = value.textValue
    let units: [(String, Double)] = [("vmin", min(viewport.width, viewport.height)), ("vmax", max(viewport.width, viewport.height)),
                                     ("vw", viewport.width), ("vh", viewport.height), ("%", horizontal ? parent.width : parent.height)]
    for (suffix, base) in units where text.hasSuffix(suffix) {
        if let number = Double(text.dropLast(suffix.count)) { return CGFloat(max(floor, base * number / 100)) }
    }
    return nil
}

// MARK: - Metal

@MainActor
final class SkinGPURenderer {
    static let shared = SkinGPURenderer()

    let device: MTLDevice
    let atlas: SkinGPUGlyphAtlas
    private let queue: MTLCommandQueue
    private struct SurfacePipelines {
        let quad: [MTLRenderPipelineState]
        let dots: [MTLRenderPipelineState]
        let ribbons: [MTLRenderPipelineState]
        let glyphs: [MTLRenderPipelineState]
        let fogComposite: [MTLRenderPipelineState]
        let bloomComposite: MTLRenderPipelineState
        let bokehComposite: MTLRenderPipelineState
        let lens: MTLRenderPipelineState
        let edgeBlur: MTLRenderPipelineState
    }

    private let standardSurface: SurfacePipelines
    private let gradedSurface: SurfacePipelines
    private let present: MTLRenderPipelineState
    /// The last pass with a `lut` filter's colour lookup before the grain.
    private let presentGraded: MTLRenderPipelineState
    private let emit: MTLRenderPipelineState
    private let bloomDown: MTLRenderPipelineState
    private let bloomUp: MTLRenderPipelineState
    private let bokehSource: MTLRenderPipelineState
    private let bokehGather: MTLRenderPipelineState
    /// A fog into its own half-resolution surface, and that surface back onto the layer's with
    /// the fog's own blend (normal, additive).
    private let fogPass: MTLRenderPipelineState
    /// The `bokeh` source and gather from the app's optional runtime library, used in place of
    /// the default ones when the app carries them.
    private let runtimeBokeh: (source: MTLRenderPipelineState, gather: MTLRenderPipelineState)?
    /// Trilinear and clamped to the edge, for the defocus's mip taps.
    private let levelSampler: MTLSamplerState
    private let sampler: MTLSamplerState
    private let glyphSampler: MTLSamplerState
    private let bloomSampler: MTLSamplerState
    static let drawableFormat = MTLPixelFormat.bgra8Unorm
    // Preserve the dark ramps before the LUT stretches them, with the same SDR clamping.
    static let gradedSurfaceFormat = MTLPixelFormat.rgba16Unorm
    /// The bloom's surfaces hold light brighter than white.
    static let bloomFormat = MTLPixelFormat.rgba16Float

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let library = device.makeDefaultLibrary() else {
            Log.error("render: gpu is unavailable: no Metal device or library", category: .background)
            return nil
        }
        /// `keep` blends as source plus destination times the blend colour, for the bloom's
        /// climb up its pyramid.
        func pipeline(_ vertex: String, _ fragment: String, additive: Bool?, format: MTLPixelFormat = Self.drawableFormat,
                      keep: Bool = false) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            if keep {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .blendColor
                attachment.destinationAlphaBlendFactor = .blendAlpha
            } else if let additive {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
            }
            do { return try device.makeRenderPipelineState(descriptor: descriptor) }
            catch { Log.error("render: gpu pipeline \(fragment) failed: \(error.localizedDescription)", category: .background); return nil }
        }
        func surfacePipelines(_ format: MTLPixelFormat) -> SurfacePipelines? {
            let modes = [false, true]
            let quad = modes.compactMap { pipeline("skinGPUQuadVertex", "skinGPUQuadFragment", additive: $0, format: format) }
            let dots = modes.compactMap { pipeline("skinGPUDotVertex", "skinGPUDotFragment", additive: $0, format: format) }
            let ribbons = modes.compactMap { pipeline("skinGPURibbonVertex", "skinGPURibbonFragment", additive: $0, format: format) }
            let glyphs = modes.compactMap { pipeline("skinGPUGlyphVertex", "skinGPUGlyphFragment", additive: $0, format: format) }
            let fog = modes.compactMap { pipeline("skinGPUPresentVertex", "skinGPUPresentFragment", additive: $0, format: format) }
            guard quad.count == 2, dots.count == 2, ribbons.count == 2, glyphs.count == 2, fog.count == 2,
                  let bloom = pipeline("skinGPUPresentVertex", "skinGPUBloomCompositeFragment", additive: true, format: format),
                  let bokeh = pipeline("skinGPUPresentVertex", "skinGPUBokehCompositeFragment", additive: nil, format: format),
                  let lens = pipeline("skinGPUPresentVertex", "skinGPULensFragment", additive: nil, format: format),
                  let edgeBlur = pipeline("skinGPUPresentVertex", "skinGPUEdgeBlurFragment", additive: nil, format: format)
            else { return nil }
            return SurfacePipelines(quad: quad, dots: dots, ribbons: ribbons, glyphs: glyphs, fogComposite: fog,
                                    bloomComposite: bloom, bokehComposite: bokeh, lens: lens, edgeBlur: edgeBlur)
        }
        guard let standardSurface = surfacePipelines(Self.drawableFormat),
              let gradedSurface = surfacePipelines(Self.gradedSurfaceFormat),
              let fogPass = pipeline("skinGPUQuadVertex", "skinGPUQuadFragment", additive: nil, format: Self.bloomFormat) else { return nil }
        self.standardSurface = standardSurface
        self.gradedSurface = gradedSurface
        self.fogPass = fogPass
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear; descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge; descriptor.tAddressMode = .clampToEdge
        let masks = MTLSamplerDescriptor()
        masks.minFilter = .linear; masks.magFilter = .linear; masks.mipFilter = .linear
        masks.sAddressMode = .clampToZero; masks.tAddressMode = .clampToZero
        // Light past the surface's edge is none, so a glyph at the edge never smears its rim outwards.
        let light = MTLSamplerDescriptor()
        light.minFilter = .linear; light.magFilter = .linear
        light.sAddressMode = .clampToZero; light.tAddressMode = .clampToZero
        let levels = MTLSamplerDescriptor()
        levels.minFilter = .linear; levels.magFilter = .linear; levels.mipFilter = .linear
        levels.sAddressMode = .clampToEdge; levels.tAddressMode = .clampToEdge
        guard let bokehSource = pipeline("skinGPUPresentVertex", "skinGPUBokehSourceFragment", additive: nil, format: Self.bloomFormat),
              let bokehGather = pipeline("skinGPUPresentVertex", "skinGPUBokehGatherFragment", additive: nil, format: Self.bloomFormat),
              let levelSampler = device.makeSamplerState(descriptor: levels) else { return nil }
        self.bokehSource = bokehSource; self.bokehGather = bokehGather
        self.levelSampler = levelSampler
        runtimeBokeh = Self.runtimeBokeh(device: device, vertex: library.makeFunction(name: "skinGPUPresentVertex"))
        guard let present = pipeline("skinGPUPresentVertex", "skinGPUPresentFragment", additive: nil),
              let presentGraded = pipeline("skinGPUPresentVertex", "skinGPUPresentGradedFragment", additive: nil),
              let emit = pipeline("skinGPUGlyphVertex", "skinGPUGlyphFragment", additive: true, format: Self.bloomFormat),
              let bloomDown = pipeline("skinGPUPresentVertex", "skinGPUBloomDownFragment", additive: nil, format: Self.bloomFormat),
              let bloomUp = pipeline("skinGPUPresentVertex", "skinGPUBloomUpFragment", additive: nil, format: Self.bloomFormat, keep: true),
              let sampler = device.makeSamplerState(descriptor: descriptor), let glyphSampler = device.makeSamplerState(descriptor: masks),
              let bloomSampler = device.makeSamplerState(descriptor: light) else { return nil }
        self.device = device; self.queue = queue; self.atlas = SkinGPUGlyphAtlas(device: device)
        self.present = present; self.presentGraded = presentGraded
        self.emit = emit; self.bloomDown = bloomDown; self.bloomUp = bloomUp
        self.sampler = sampler; self.glyphSampler = glyphSampler; self.bloomSampler = bloomSampler
    }

    /// The runtime library's `bokeh` passes: the source writes the weighted light and the plain
    /// coverage side by side, and the gather reads both.
    private static func runtimeBokeh(device: MTLDevice, vertex: MTLFunction?)
        -> (source: MTLRenderPipelineState, gather: MTLRenderPipelineState)? {
        guard let vertex, let library = BokehTransitionMetalContext.runtimeLibrary(device: device),
              let sourceFunction = library.makeFunction(name: "skinLensSourceFragment"),
              let gatherFunction = library.makeFunction(name: "skinLensGatherFragment") else { return nil }
        let source = MTLRenderPipelineDescriptor()
        source.vertexFunction = vertex
        source.fragmentFunction = sourceFunction
        source.colorAttachments[0].pixelFormat = bloomFormat
        source.colorAttachments[1].pixelFormat = .r16Float
        let gather = MTLRenderPipelineDescriptor()
        gather.vertexFunction = vertex
        gather.fragmentFunction = gatherFunction
        gather.colorAttachments[0].pixelFormat = bloomFormat
        do {
            return (try device.makeRenderPipelineState(descriptor: source), try device.makeRenderPipelineState(descriptor: gather))
        } catch {
            Log.warning("skin bokeh runtime passes unavailable: \(error.localizedDescription)", category: .background)
            return nil
        }
    }

    /// The bloom's levels for a light reaching `reach` surface pixels: each level is a Gaussian
    /// about twice as wide as the last, starting at the half-resolution emission.
    static func bloomLevels(reach: Double) -> Int {
        min(8, max(2, Int(log2(max(8, reach)).rounded()) - 2))
    }

    /// The pyramid's surfaces: the emission at half the surface's size, then each level half the
    /// one before, down to a few pixels.
    func bloomTextures(width: Int, height: Int, levels: Int, reusing old: [MTLTexture]) -> [MTLTexture] {
        var result: [MTLTexture] = []
        var w = max(1, width / 2), h = max(1, height / 2)
        for index in 0...levels {
            if index > 0 && (w < 2 || h < 2) { break }
            if index < old.count, old[index].width == w, old[index].height == h {
                result.append(old[index])
            } else {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.bloomFormat, width: w, height: h, mipmapped: false)
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                guard let texture = device.makeTexture(descriptor: descriptor) else { break }
                result.append(texture)
            }
            w = max(1, w / 2); h = max(1, h / 2)
        }
        return result
    }

    /// The surface lifted into linear scene light with its levels, spread over the lens's
    /// aperture on the level the disc is read from, then mixed over the sharp surface into `target`.
    private func defocus(_ bokeh: SkinGPUBokehFrame, targets bokehTargets: SkinGPUBokehTargets, from source: MTLTexture,
                         into target: MTLTexture, composite: MTLRenderPipelineState, buffer: MTLCommandBuffer) {
        let sourceTexture = bokehTargets.source, blurred = bokehTargets.blurred
        let surfaceWidth = Double(source.width)
        let toSource = Double(sourceTexture.width) / max(1, surfaceWidth)
        let radius = bokeh.radius * toSource
        // Below about one source texel the blur cannot show the radius, so the sharp surface
        // carries the frame there. The weight depends on the radius alone: the same radius looks
        // the same on the way out and on the way back.
        let texel = 1 / max(toSource, 1e-3)
        let t = min(1, max(0, (bokeh.radius - 0.35 * texel) / (1.25 * texel)))
        let weight = t * t * (3 - 2 * t)
        let levels = sourceTexture.mipmapLevelCount
        let plan = SkinBokehAperture.plan(radius: radius, levels: levels)
        var post = SkinGPUBokehPost(sourceSize: SIMD2(Float(sourceTexture.width), Float(sourceTexture.height)),
                                    surfaceSize: SIMD2(Float(source.width), Float(source.height)),
                                    radius: Float(radius), weight: Float(weight), breathing: Float(bokeh.breathing),
                                    lift: Float(0.85 * bokeh.glow), lod: Float(plan.lod), taps: Float(plan.taps),
                                    blurLevel: Float(plan.blurLevel))
        if runtimeBokeh != nil {
            // The runtime gather keeps highlights by weight, so the composite folds nothing back.
            let rings = SkinBokehAperture.rings(radius: radius, levels: levels)
            post.lift = 0
            post.lod = Float(rings.lod)
            post.blurLevel = Float(rings.blurLevel)
            post.rings = Float(rings.rings)
            post.importance = Float(exp2(6 * bokeh.glow))
            post.threshold = Float(bokeh.threshold)
            post.swirl = Float(0.9 * bokeh.swirl)
            post.squash = Float(0.55 * bokeh.swirl)
        }
        func pass(_ texture: MTLTexture, _ state: MTLRenderPipelineState, _ inputs: [MTLTexture?], samplers: [MTLSamplerState],
                  level: Int = 0, also: MTLTexture? = nil) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = texture
            descriptor.colorAttachments[0].level = level
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            if let also {
                descriptor.colorAttachments[1].texture = also
                descriptor.colorAttachments[1].loadAction = .dontCare
                descriptor.colorAttachments[1].storeAction = .store
            }
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(state)
            encoder.setFragmentBytes(&post, length: MemoryLayout<SkinGPUBokehPost>.stride, index: 0)
            for (index, input) in inputs.enumerated() { encoder.setFragmentTexture(input, index: index) }
            for (index, sampler) in samplers.enumerated() { encoder.setFragmentSamplerState(sampler, index: index) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        if weight > 0, let runtimeBokeh {
            let coverage = bokehTargets.coverage
            pass(sourceTexture, runtimeBokeh.source, [source], samplers: [sampler], also: coverage)
            if let blit = buffer.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: sourceTexture)
                blit.generateMipmaps(for: coverage)
                blit.endEncoding()
            }
            pass(blurred, runtimeBokeh.gather, [sourceTexture, coverage], samplers: [levelSampler], level: Int(post.blurLevel))
        } else if weight > 0 {
            pass(sourceTexture, bokehSource, [source], samplers: [sampler])
            if let blit = buffer.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: sourceTexture)
                blit.endEncoding()
            }
            pass(blurred, bokehGather, [sourceTexture], samplers: [levelSampler], level: plan.blurLevel)
        }
        pass(target, composite, [source, blurred], samplers: [sampler, levelSampler])
    }

    /// Offscreen textures the passes run through, each the size of the surface.
    struct Targets {
        var surface: MTLTexture
        var scratch: [MTLTexture]
        /// The bloom's pyramid, empty when nothing glows.
        var bloom: [MTLTexture] = []
        /// One half-resolution surface per fog, in scene order; a fog without one draws in place.
        var fog: [MTLTexture] = []
    }

    /// Fogs are drawn at half the surface's width and height. Their finest grain spans tens of
    /// points, so the quarter of the work looks the same once filtered back up, and their three
    /// layers of noise per pixel are most of a backdrop's cost.
    static func fogCount(_ scene: SkinGPUScene) -> Int {
        scene.items.reduce(0) { count, item in
            if case .quad(let quad, _, _) = item, quad.kind == 2 { return count + 1 }
            return count
        }
    }

    func fogTextures(width: Int, height: Int, count: Int, reusing old: [MTLTexture]) -> [MTLTexture] {
        let w = max(1, (width + 1) / 2), h = max(1, (height + 1) / 2)
        return (0..<count).compactMap { index in
            if index < old.count, old[index].width == w, old[index].height == h { return old[index] }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.bloomFormat, width: w, height: h, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
    }

    /// Lit glyphs into the pyramid's base, down the pyramid and back up with equal weight per
    /// octave (the widest two lifted by `haze`), then the light onto the surface. Each colour
    /// group runs in turn through the same textures.
    private func bloom(_ scene: SkinGPUScene, _ group: SkinGPUScene.Bloom, frame: SkinGPUFrame, levels pyramid: [MTLTexture],
                       surface: MTLTexture, composite: MTLRenderPipelineState, buffer: MTLCommandBuffer) {
        guard pyramid.count >= 2 else { return }
        var frame = frame
        func pass(_ target: MTLTexture, load: Bool) -> MTLRenderCommandEncoder? {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = load ? .load : .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            descriptor.colorAttachments[0].storeAction = .store
            return buffer.makeRenderCommandEncoder(descriptor: descriptor)
        }
        func filter(_ encoder: MTLRenderCommandEncoder, _ state: MTLRenderPipelineState, source: MTLTexture, tint: SIMD3<Float>) {
            var uniforms = SkinGPUBloomPass(texel: SIMD2(1 / Float(source.width), 1 / Float(source.height)), tint: SIMD4(tint, 1))
            encoder.setRenderPipelineState(state)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SkinGPUBloomPass>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentSamplerState(bloomSampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        guard let encoder = pass(pyramid[0], load: false) else { return }
        encoder.setRenderPipelineState(emit)
        encoder.setVertexBytes(&frame, length: MemoryLayout<SkinGPUFrame>.stride, index: 0)
        encoder.setFragmentSamplerState(glyphSampler, index: 0)
        for item in group.emitters {
            guard case .glyph(var glyph, let texture, _) = item else { continue }
            encoder.setVertexBytes(&glyph, length: MemoryLayout<SkinGPUGlyph>.stride, index: 1)
            encoder.setFragmentBytes(&glyph, length: MemoryLayout<SkinGPUGlyph>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        let top = pyramid.count - 1
        for level in 1...top {
            guard let encoder = pass(pyramid[level], load: false) else { return }
            filter(encoder, bloomDown, source: pyramid[level - 1], tint: SIMD3(repeating: 1))
        }
        let tints = Self.bloomTints(levels: top, haze: scene.bloomHaze, color: group.color, saturation: group.saturation)
        for level in stride(from: top - 1, through: 0, by: -1) {
            guard let encoder = pass(pyramid[level], load: true) else { return }
            let keep = tints.weights[level]
            encoder.setBlendColor(red: keep.x, green: keep.y, blue: keep.z, alpha: 1)
            filter(encoder, bloomUp, source: pyramid[level + 1], tint: level + 1 == top ? tints.weights[top] : SIMD3(repeating: 1))
        }
        guard let encoder = pass(surface, load: true) else { return }
        filter(encoder, composite, source: pyramid[0], tint: SIMD3(repeating: 1 / tints.total))
    }

    /// Each octave's weight and colour. Equal weight per octave is the inverse-square law; the
    /// three finest are lighter, so the glyph's own edge stays crisp, and the two widest are
    /// lifted by `haze` into a broad veil. The colour runs from the glow's own at the glyph to
    /// its falloff tone at the widest octave, each scaled to unit luminance so only the weights
    /// set brightness. `total` divides the sum: every octave carries the emission's whole energy,
    /// so a wider light spreads it instead of brightening.
    static func bloomTints(levels top: Int, haze: Double, color: OKLCHColor?, saturation: Double) -> (weights: [SIMD3<Float>], total: Float) {
        let near: [Double] = [0.15, 0.55, 0.85]
        let base = color.map { OKColor.OKLCH(l: CGFloat($0.lightness), c: CGFloat($0.chroma), h: CGFloat($0.hue ?? 0)) }
        var weights: [SIMD3<Float>] = []
        var total = 0.0
        for level in 0...top {
            let weight = level < near.count && level < top - 1 ? near[level] : (level >= top - 1 ? 1 + max(0, haze) : 1)
            total += weight
            var rgb = SIMD3<Float>(repeating: 1)
            if let base, color?.hue != nil {
                let tone = PerceptualToneLadder.glowFalloffTone(base, t: CGFloat(level) / CGFloat(max(1, top)), saturation: CGFloat(saturation))
                let resolved = ColorRenderingAdapter.resolve(OKLCHColor(tone), target: .linearDisplayP3)
                let luminance = 0.2290 * resolved.red + 0.6917 * resolved.green + 0.0793 * resolved.blue
                if luminance > 1e-4 {
                    rgb = SIMD3(Float(resolved.red / luminance), Float(resolved.green / luminance), Float(resolved.blue / luminance))
                }
            }
            weights.append(rgb * Float(weight))
        }
        return (weights, Float(max(1e-3, total)))
    }

    /// A presenter for one layer, on this renderer's command queue so its passes run after the
    /// frame they finish.
    func makePresenter() -> SkinGPUPresenter {
        SkinGPUPresenter(queue: queue, pipeline: present, graded: presentGraded, sampler: sampler)
    }

    /// The scene into `targets.surface`; the defocus, the lens and its edge blur at that
    /// resolution. Returns the finished surface, which a `SkinGPUPresenter` scales up to the
    /// drawable with grain. `completed` receives the frame's GPU time.
    func draw(_ scene: SkinGPUScene, frame: SkinGPUFrame, lens: SkinGPULens?, targets: Targets,
              bokeh: (frame: SkinGPUBokehFrame, targets: SkinGPUBokehTargets)? = nil,
              completed: (@Sendable (Double) -> Void)? = nil) -> MTLTexture? {
        guard let buffer = queue.makeCommandBuffer() else { return nil }
        let fresh = atlas.takePending()
        if !fresh.isEmpty, let blit = buffer.makeBlitCommandEncoder() {
            for texture in fresh { blit.generateMipmaps(for: texture) }
            blit.endEncoding()
        }
        let pipelines = targets.surface.pixelFormat == Self.gradedSurfaceFormat ? gradedSurface : standardSurface
        var frame = frame
        // Each fog into its half-resolution surface first; the clip space is the same at any size.
        var fogIndex = 0
        for item in scene.items {
            guard case .quad(var quad, let stops, _) = item, quad.kind == 2 else { continue }
            defer { fogIndex += 1 }
            guard fogIndex < targets.fog.count else { break }
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = targets.fog[fogIndex]
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { continue }
            encoder.setRenderPipelineState(fogPass)
            encoder.setVertexBytes(&frame, length: MemoryLayout<SkinGPUFrame>.stride, index: 0)
            encoder.setVertexBytes(&quad, length: MemoryLayout<SkinGPUQuad>.stride, index: 1)
            encoder.setFragmentBytes(&quad, length: MemoryLayout<SkinGPUQuad>.stride, index: 1)
            stops.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        fogIndex = 0
        var fogPost = SkinGPUPost(size: SIMD2(Float(targets.surface.width), Float(targets.surface.height)))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.surface
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setVertexBytes(&frame, length: MemoryLayout<SkinGPUFrame>.stride, index: 0)
            encoder.setFragmentSamplerState(glyphSampler, index: 0)
            let dotBuffer = scene.dots.isEmpty ? nil : device.makeBuffer(bytes: scene.dots, length: MemoryLayout<SkinGPUDot>.stride * scene.dots.count)
            let vertexBuffer = scene.vertices.isEmpty ? nil : device.makeBuffer(bytes: scene.vertices, length: MemoryLayout<SkinGPUVertex>.stride * scene.vertices.count)
            var current: MTLRenderPipelineState?
            func use(_ state: MTLRenderPipelineState) {
                if current !== state { encoder.setRenderPipelineState(state); current = state }
            }
            for item in scene.items {
                switch item {
                case .quad(let quad, _, let additive) where quad.kind == 2 && fogIndex < targets.fog.count:
                    use(pipelines.fogComposite[additive ? 1 : 0])
                    encoder.setFragmentBytes(&fogPost, length: MemoryLayout<SkinGPUPost>.stride, index: 0)
                    encoder.setFragmentTexture(targets.fog[fogIndex], index: 0)
                    encoder.setFragmentSamplerState(sampler, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    encoder.setFragmentSamplerState(glyphSampler, index: 0)
                    fogIndex += 1
                case .quad(var quad, let stops, let additive):
                    use(pipelines.quad[additive ? 1 : 0])
                    encoder.setVertexBytes(&quad, length: MemoryLayout<SkinGPUQuad>.stride, index: 1)
                    encoder.setFragmentBytes(&quad, length: MemoryLayout<SkinGPUQuad>.stride, index: 1)
                    stops.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                case .dots(let range, let additive):
                    guard let dotBuffer else { continue }
                    use(pipelines.dots[additive ? 1 : 0])
                    encoder.setVertexBuffer(dotBuffer, offset: range.lowerBound * MemoryLayout<SkinGPUDot>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: range.count)
                case .ribbons(let range, let additive):
                    guard let vertexBuffer else { continue }
                    use(pipelines.ribbons[additive ? 1 : 0])
                    encoder.setVertexBuffer(vertexBuffer, offset: range.lowerBound * MemoryLayout<SkinGPUVertex>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: range.count)
                case .glyph(var glyph, let texture, let additive):
                    use(pipelines.glyphs[additive ? 1 : 0])
                    encoder.setVertexBytes(&glyph, length: MemoryLayout<SkinGPUGlyph>.stride, index: 1)
                    encoder.setFragmentBytes(&glyph, length: MemoryLayout<SkinGPUGlyph>.stride, index: 1)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
            encoder.endEncoding()
        }
        for group in scene.blooms {
            bloom(scene, group, frame: frame, levels: targets.bloom, surface: targets.surface,
                  composite: pipelines.bloomComposite, buffer: buffer)
        }
        atlas.endFrame()
        var source = targets.surface
        let surfaceSize = SIMD2(Float(targets.surface.width), Float(targets.surface.height))
        // The lens measures surface pixels, whatever size the drawable is.
        let share = frame.pointScale
        func post(_ state: MTLRenderPipelineState, axis: SIMD2<Float> = SIMD2(1, 0)) {
            // Ping-pong between the surface and the scratch surface: each pass writes the one it
            // does not read.
            guard let target = ([targets.surface] + targets.scratch).first(where: { $0 !== source }), let lens else { return }
            var uniforms = SkinGPUPost(size: surfaceSize, distortion: Float(lens.distortion), chromatic: Float(lens.chromatic) * share,
                                       blur: Float(lens.blur) * share, start: Float(lens.start), axis: axis)
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(state)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SkinGPUPost>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            source = target
        }
        if let bokeh, let target = ([targets.surface] + targets.scratch).first(where: { $0 !== source }) {
            defocus(bokeh.frame, targets: bokeh.targets, from: source, into: target,
                    composite: pipelines.bokehComposite, buffer: buffer)
            source = target
        }
        if let lens, !targets.scratch.isEmpty {
            if lens.bends { post(pipelines.lens) }
            if lens.blurs { post(pipelines.edgeBlur, axis: SIMD2(1, 0)); post(pipelines.edgeBlur, axis: SIMD2(0, 1)) }
        }
        if let completed {
            buffer.addCompletedHandler { buffer in completed(buffer.gpuEndTime - buffer.gpuStartTime) }
        }
        buffer.commit()
        return source
    }
}

/// A layer's last pass: waits for the layer's next drawable and scales the finished surface into
/// it with grain, on its own serial queue. A drawable the window server still holds then delays
/// only this layer's frame, never the main thread and the other layers and controls on it. Its
/// command buffers share the renderer's queue, so each runs after the frame it presents; while one
/// has not been committed yet, the layer skips its next frame instead of drawing over the surface
/// it is about to read.
nonisolated final class SkinGPUPresenter: @unchecked Sendable {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let graded: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let work = DispatchQueue(label: "kmgccc.skin.gpu.present", qos: .userInteractive)
    private let lock = NSLock()
    private var pending = false
    private var waits: [Double] = []

    init(queue: MTLCommandQueue, pipeline: MTLRenderPipelineState, graded: MTLRenderPipelineState, sampler: MTLSamplerState) {
        self.queue = queue; self.pipeline = pipeline; self.graded = graded; self.sampler = sampler
    }

    /// Whether the previous frame is still waiting for its drawable.
    var isBusy: Bool { lock.withLock { pending } }

    /// Seconds each present since the last call waited for its drawable.
    func takeWaits() -> [Double] {
        lock.withLock { defer { waits.removeAll(keepingCapacity: true) }; return waits }
    }

    /// Scale the scene into the drawable, then apply its grade and grain.
    func present(_ surface: MTLTexture, to layer: CAMetalLayer, grain: Float, time: Float, pointScale: Float,
                 lut: MTLTexture? = nil, lutAmount: Float = 0) {
        lock.withLock { pending = true }
        nonisolated(unsafe) let layer = layer
        nonisolated(unsafe) let surface = surface
        nonisolated(unsafe) let lut = lutAmount > 0 ? lut : nil
        work.async { [self] in
            defer { lock.withLock { pending = false } }
            let start = CACurrentMediaTime()
            let drawable = layer.nextDrawable()
            let waited = CACurrentMediaTime() - start
            lock.withLock { waits.append(waited) }
            guard let drawable, let buffer = queue.makeCommandBuffer() else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
                var uniforms = SkinGPUPost(size: SIMD2(Float(drawable.texture.width), Float(drawable.texture.height)),
                                           grain: grain, time: time, pointScale: pointScale, lut: min(1, lutAmount))
                encoder.setRenderPipelineState(lut == nil ? pipeline : graded)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SkinGPUPost>.stride, index: 0)
                encoder.setFragmentTexture(surface, index: 0)
                if let lut { encoder.setFragmentTexture(lut, index: 1) }
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

/// The surface: a Metal layer drawn on the display's own clock, at its full refresh rate, that
/// rests while nothing on it moves and wakes when an input it read changes.
final class SkinGPULayerNSView: NSView {
    let model = SkinGPULayerModel()
    private var link: CADisplayLink?
    private var surface: MTLTexture?
    private var scratch: [MTLTexture] = []
    private var bloomTextures: [MTLTexture] = []
    private var fogTextures: [MTLTexture] = []
    private var clearedEmpty = false
    /// The defocus's textures, held only from a focus hunt's first open frame to its end.
    private var bokehTargets: SkinGPUBokehTargets?
    private var bokehKeepUntil = 0.0
    private let bokehTiming = SkinGPUBokehTiming()
    private let presenter = SkinGPURenderer.shared?.makePresenter()
    /// The display time of the last frame drawn, nil while the surface rests.
    private var lastDrawn: CFTimeInterval?
    /// Whether the `lut` filter's lookup is still loading, so the surface draws until it is ready.
    private var lutPending = false
    /// Whether a tracking registration is still waiting for the inputs it read to change.
    private var observing = false
    private var metal: CAMetalLayer? { layer as? CAMetalLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = SkinGPURenderer.shared?.device
        layer.pixelFormat = SkinGPURenderer.drawableFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        layer.framebufferOnly = true
        layer.isOpaque = false
        // A third drawable lets the window server hold one a frame longer without this layer
        // missing a frame.
        layer.maximumDrawableCount = 3
        return layer
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate(); link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        let fastest = Float(max(60, window?.screen?.maximumFramesPerSecond ?? 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        self.link = link
        resize()
    }

    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resize(); wake() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); resize(); wake() }

    private func resize() {
        let scale = window?.backingScaleFactor ?? 2
        metal?.contentsScale = scale
        // The first draw sizes the drawable from the layer's own resolution; until SwiftUI hands
        // over inputs, keep it small instead of holding full-size surfaces for a frame that may
        // never draw.
        guard let inputs = model.inputs else {
            metal?.drawableSize = CGSize(width: 1, height: 1)
            return
        }
        let share = Self.drawableShare(inputs)
        metal?.drawableSize = CGSize(
            width: max(1, (bounds.width * scale * share).rounded()),
            height: max(1, (bounds.height * scale * share).rounded())
        )
    }

    /// The drawable's share of the backing resolution: the surface's own, so a scene drawn at a
    /// lower `resolution` does not also keep a full-size drawable, except that grain needs the
    /// render quality's full resolution to stay one fine grain per pixel. The scene itself stays
    /// at its resolution; only the last pass, which scales it up and adds the grain, is larger.
    static func drawableShare(_ inputs: SkinGPULayerInputs) -> Double {
        let quality = SkinRenderScale.factor(inputs.renderScale)
        let surface = SkinRenderScale.factor(inputs.resolution * quality)
        return inputs.grain > 0 ? max(surface, quality) : surface
    }

    /// Draws again from the next display frame; called when SwiftUI hands over new inputs.
    func wake() { link?.isPaused = false }

    @objc private func tick(_ link: CADisplayLink) {
        let now = Date.timeIntervalSinceReferenceDate + (link.targetTimestamp - CACurrentMediaTime())
        var still = false
        var drawn = true
        // Whatever the frame read wakes the surface when it changes, so it may rest in between.
        // A registration never fires while its inputs stay put, so only one is kept pending: a
        // fresh one per frame would pile up a registrar entry per frame on the scene it reads.
        if observing {
            drawn = draw(at: now)
            still = model.isStill()
        } else {
            withObservationTracking {
                drawn = draw(at: now)
                still = model.isStill()
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.observing = false
                    self?.wake()
                }
            }
            observing = true
        }
        pace(link, drawn: drawn)
        // A skipped frame is drawn on the next tick, even when nothing moves any more.
        if still && drawn && !lutPending { link.isPaused = true; lastDrawn = nil }
    }

    /// Frame pacing for `skin.runtime`: frames that came later than one and a half display
    /// frames after the previous one, frames skipped while the last one waited for its
    /// drawable, and how long presents waited.
    private func pace(_ link: CADisplayLink, drawn: Bool) {
        guard let inputs = model.inputs else { return }
        let key = inputs.metricsID + "/" + inputs.node.id
        let interval = max(1.0 / 240, link.targetTimestamp - link.timestamp)
        let waits = presenter?.takeWaits() ?? []
        var gap: Double?
        if drawn {
            if let lastDrawn { gap = link.timestamp - lastDrawn }
            lastDrawn = link.timestamp
        }
        SkinSceneRuntimeMetrics.shared.pace(key) { pacing in
            if drawn { pacing.frames &+= 1 } else { pacing.skipped &+= 1 }
            if let gap {
                pacing.worstGap = max(pacing.worstGap, gap)
                if gap > 1.5 * interval { pacing.late &+= 1 }
            }
            for wait in waits {
                pacing.waitTotal += wait
                pacing.worstWait = max(pacing.worstWait, wait)
                if wait > 0.004 { pacing.longWaits &+= 1 }
            }
        }
    }

    /// False when the frame was skipped because the previous one still waits for its drawable.
    private func draw(at now: Double) -> Bool {
        guard let renderer = SkinGPURenderer.shared, let metal, let inputs = model.inputs, bounds.width >= 1, bounds.height >= 1 else { return true }
        if presenter?.isBusy == true { return false }
        let scale = metal.contentsScale
        let share = SkinRenderScale.factor(inputs.resolution * SkinRenderScale.factor(inputs.renderScale))
        let width = max(1, Int((bounds.width * scale * share).rounded())), height = max(1, Int((bounds.height * scale * share).rounded()))
        let surfaceFormat = inputs.lut == nil ? SkinGPURenderer.drawableFormat : SkinGPURenderer.gradedSurfaceFormat
        func target() -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: surfaceFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return renderer.device.makeTexture(descriptor: descriptor)
        }
        if surface?.width != width || surface?.height != height || surface?.pixelFormat != surfaceFormat {
            surface = target()
            scratch = []
        }
        // The drawable holds the surface's pixels (more only while there is grain) and Core
        // Animation scales it into the view; see `drawableShare`.
        let drawableShare = Self.drawableShare(inputs)
        let drawableWidth = max(1, Int((bounds.width * scale * drawableShare).rounded()))
        let drawableHeight = max(1, Int((bounds.height * scale * drawableShare).rounded()))
        if metal.drawableSize.width != CGFloat(drawableWidth) || metal.drawableSize.height != CGFloat(drawableHeight) {
            metal.drawableSize = CGSize(width: drawableWidth, height: drawableHeight)
            DebugUIHooks.record("gpu-layer surface=\(width)x\(height) drawable=\(drawableWidth)x\(drawableHeight) bounds=\(Int(bounds.width))x\(Int(bounds.height)) scale=\(scale) share=\(share)")
        }
        let bokeh = defocus(inputs, now: now, renderer: renderer, width: width, height: height)
        // The defocus and lens passes ping-pong between the surface and one more surface.
        if inputs.lens?.bends == true || inputs.lens?.blurs == true || bokehTargets != nil, scratch.isEmpty {
            scratch = [target()].compactMap { $0 }
        }
        let camera = inputs.camera?(now)
        guard let surface, var frame = model.frame(at: now, pointScale: scale, camera: camera) else { return true }
        frame.pointScale = Float(CGFloat(width) / max(1, bounds.width))
        let scene = model.scene(at: now, camera: camera, pixelsPerPoint: scale * share)
        // An empty surface draws one clear frame and then hides, so the window server has
        // nothing of it to composite until something appears again.
        if scene.items.isEmpty {
            if metal.isHidden { return true }
            if clearedEmpty { metal.isHidden = true; return true }
            clearedEmpty = true
        } else {
            clearedEmpty = false
            if metal.isHidden { metal.isHidden = false }
        }
        // The bloom's pyramid, sized to how far this frame's widest light reaches. Levels a
        // smaller light leaves unused stay allocated, so a light that grows again reuses them.
        var bloom: [MTLTexture] = []
        if !scene.blooms.isEmpty {
            let levels = SkinGPURenderer.bloomLevels(reach: scene.bloomReach * Double(frame.pointScale))
            bloomTextures = renderer.bloomTextures(width: width, height: height, levels: max(levels, bloomTextures.count - 1),
                                                   reusing: bloomTextures)
            bloom = Array(bloomTextures.prefix(levels + 1))
        }
        let fogs = SkinGPURenderer.fogCount(scene)
        if fogs != fogTextures.count || fogTextures.first.map({ $0.width != max(1, (width + 1) / 2) || $0.height != max(1, (height + 1) / 2) }) == true {
            fogTextures = renderer.fogTextures(width: width, height: height, count: fogs, reusing: fogTextures)
        }
        var completed: (@Sendable (Double) -> Void)?
        if bokeh != nil {
            let timing = bokehTiming
            completed = { seconds in Task { @MainActor in timing.record(seconds) } }
        }
        guard let finished = renderer.draw(scene, frame: frame, lens: inputs.lens,
                                           targets: .init(surface: surface, scratch: scratch, bloom: bloom, fog: fogTextures),
                                           bokeh: bokeh, completed: completed) else { return true }
        // A lookup still loading draws the frame ungraded and keeps the surface awake until it lands.
        let lutResource = inputs.lut?.resource
        let lut = lutResource.flatMap { SkinColorLUTLibrary.shared.lut(for: $0) }
        lutPending = lut == nil && (lutResource.map { SkinColorLUTLibrary.shared.isLoading($0) } ?? false)
        presenter?.present(finished, to: metal, grain: frame.grain, time: frame.time, pointScale: frame.pointScale,
                           lut: lut?.texture, lutAmount: Float(inputs.lut?.amount ?? 0))
        SkinSceneRuntimeMetrics.shared.frame(inputs.metricsID, audioReaders: inputs.data.audioReaders.count)
        return true
    }

    /// This frame's defocus, when the layer's focus hunt is open. The textures are made two
    /// seconds before a hunt starts, so its first frame allocates nothing, and kept eight seconds
    /// after it ends, so hunts close together reuse them. Each hunt's GPU time is logged at its end.
    private func defocus(_ inputs: SkinGPULayerInputs, now: Double, renderer: SkinGPURenderer, width: Int,
                         height: Int) -> (frame: SkinGPUBokehFrame, targets: SkinGPUBokehTargets)? {
        let lyricsTime = inputs.data.clock.lyricsTime(at: now)
        guard inputs.moves, inputs.active, let bokeh = model.bokeh(lyricsTime: lyricsTime),
              bokeh.approaching(lyricsTime: lyricsTime, lead: 2) else {
            if bokehTiming.isOpen { bokehTiming.finish(refresh: Double(window?.screen?.maximumFramesPerSecond ?? 60)) }
            if bokehTargets != nil, now > bokehKeepUntil || !inputs.active {
                bokehTargets = nil
                if inputs.lens == nil { scratch = [] }
            }
            return nil
        }
        bokehKeepUntil = now + 8
        if bokehTargets?.fits(surfaceWidth: width, surfaceHeight: height, detail: bokeh.detail) != true {
            bokehTargets = SkinGPUBokehTargets(device: renderer.device, surfaceWidth: width, surfaceHeight: height, detail: bokeh.detail)
        }
        guard let bokehTargets else { return nil }
        let level = bokeh.level(lyricsTime: lyricsTime)
        guard level > 0.002 else { return nil }
        if !bokehTiming.isOpen {
            bokehTiming.begin("\(inputs.metricsID)/\(inputs.node.id) surface=\(width)x\(height) "
                              + "source=\(bokehTargets.source.width)x\(bokehTargets.source.height)")
        }
        let pixelsPerPoint = Double(width) / max(1, bounds.width)
        return (SkinGPUBokehFrame(radius: bokeh.radius * level * pixelsPerPoint, breathing: bokeh.breathing * level, glow: bokeh.glow,
                                  threshold: bokeh.threshold, swirl: bokeh.swirl),
                bokehTargets)
    }
}

struct SkinGPULayerSurface: NSViewRepresentable {
    let inputs: SkinGPULayerInputs

    func makeNSView(context: Context) -> SkinGPULayerNSView {
        let view = SkinGPULayerNSView(frame: .zero)
        view.model.inputs = inputs
        return view
    }

    func updateNSView(_ view: SkinGPULayerNSView, context: Context) {
        view.model.inputs = inputs
        view.wake()
    }
}
