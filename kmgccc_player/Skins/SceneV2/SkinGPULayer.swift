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
        "sweep", "width",
    ]
    private static let shapeKinds: Set<String> = ["rectangle", "circle", "ellipse", "path"]
    private static let layerKeys: Set<String> = ["frame", "visible", "opacity", "depth", "hitTesting", "offsetX", "offsetY"]
    private static let repeatKeys: Set<String> = ["frame", "visible", "items", "limit", "layout", "hitTesting"]
    private static let textKeys: Set<String> = [
        "frame", "visible", "opacity", "depth", "hitTesting", "text", "font", "weight", "fontSize", "lineLimit", "alignment", "tracking",
        "color", "rotation", "scale", "offsetX", "offsetY", "blur", "subpixel", "glow", "glyphMotion", "key",
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
    var edge = SIMD2<Float>.zero
    var color: SIMD4<Float>
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
    /// False once any node drawn has a per-frame input that still moves.
    var still = true
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
    var lens: SkinGPULens?
    var camera: (@MainActor (Double) -> SkinSceneCamera)?
    /// Whether the layer's camera rests, given whether playback runs and scene time moves.
    var cameraStill: @MainActor (Bool, Bool) -> Bool
    var metricsID: String
}

@MainActor
final class SkinGPULayerModel {
    var inputs: SkinGPULayerInputs?
    private var grainTime = 0.0
    private var lastStill = true

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
        return !(inputs.grain > 0 && inputs.moves && timeMoves)
    }

    func frame(at now: Double, pointScale: Double, camera: SkinSceneCamera?) -> SkinGPUFrame? {
        guard let inputs else { return nil }
        if inputs.moves, inputs.data.timeMoves(playing: inputs.playing) { grainTime = now.truncatingRemainder(dividingBy: 3600) }
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
        if visible, opacity > 0.001 {
            walk(inputs.node.children, locals: inputs.locals, cell: -1, local: .identity, depth: 0, size: inputs.size, opacity: opacity,
                 camera: camera, now: now, pixelsPerPoint: pixelsPerPoint, into: &scene)
        }
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
                text(child, values: values, context: context, world: world, parent: size, opacity: opacity, clock: instance.clock,
                     now: now, pixelsPerPoint: pixelsPerPoint, into: &scene)
            default:
                let additive = values["blendMode"]?.textValue == "plusLighter"
                let topLeft = CGPoint(x: frame.centre.x - frame.size.width / 2, y: frame.centre.y - frame.size.height / 2).applying(world)
                let place = Placement(origin: topLeft, scale: sqrt(abs(world.a * world.d - world.b * world.c)), size: frame.size)
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
                    scene.items.append(.quad(fog(values, place: place, opacity: opacity, now: now, inputs: inputs), stops: Self.noStops, additive: additive))
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

        func point(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float(origin.x + p.x * scale), Float(origin.y + p.y * scale)) }

        func quad(kind: Int32, opacity: Double) -> SkinGPUQuad {
            SkinGPUQuad(origin: SIMD2(Float(origin.x), Float(origin.y)), localSize: SIMD2(Float(size.width), Float(size.height)),
                        scale: Float(scale), kind: kind, opacity: Float(opacity))
        }
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
        let modes: [String: Float] = ["radial": 1, "elliptical": 2]
        let mode = modes[values["mode"]?.textValue ?? ""] ?? 0
        let centre = unitPoint(values["start"]?.textValue ?? "center")
        quad.params = SIMD4(Float(values["radius"]?.number(0.5) ?? 0.5), Float(centre.x), Float(centre.y), mode)
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
        let pad = half + 3 * sigma + 2
        let size = place.size
        var quad = Placement(origin: CGPoint(x: place.origin.x - pad * place.scale, y: place.origin.y - pad * place.scale), scale: place.scale,
                             size: CGSize(width: size.width + 2 * pad, height: size.height + 2 * pad)).quad(kind: 3, opacity: opacity)
        quad.color = stroke.map { premultiplied($0.color) } ?? .zero
        quad.color2 = stroke == nil || values["color"] != nil ? premultiplied(color) : .zero
        quad.params = SIMD4(Float(half), Float(sigma), Float(size.width / 2), Float(size.height / 2))
        quad.params2 = SIMD4(Float(pad + size.width / 2), Float(pad + size.height / 2), 0, 0)
        return quad
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
        if from > 0 || to < 1 { path = path.trimmedPath(from: from, to: to) }
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
        let first = scene.vertices.count
        for (index, points) in runs.enumerated() {
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
            func vertex(_ i: Int, _ side: Double) -> SkinGPUVertex {
                let p = layer[i], n = normals[i]
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
        let alpha = SkinCometPath.smooth(progress / 0.1) * (1 - SkinCometPath.smooth((progress - 0.82) / 0.18)) * opacity
        guard alpha > 0.001 else { return }
        let centre = CGPoint(x: place.size.width / 2, y: place.size.height / 2)
        let turn = (values["rotation"]?.number() ?? 0) * .pi / 180
        let (c, s) = (cos(turn), sin(turn))
        func point(_ s0: Double) -> CGPoint {
            let t = min(1, max(0, s0))
            let arrive = 1 - SkinCometPath.smooth(t / 0.34)
            let leave = SkinCometPath.smooth((t - 0.7) / 0.3)
            let wobble = 0.07 * sin(2 * .pi * (t * 1.4) + seed * 5.1)
            let rho = 1 + 1.7 * arrive * arrive + 1.3 * leave * leave + wobble
            let theta = start + sweep * t
            let x = rx * rho * cos(theta), y = ry * rho * sin(theta)
            return CGPoint(x: centre.x + x * c - y * s, y: centre.y + x * s + y * c)
        }
        let tail = max(0, progress - trail)
        var points = (0...60).map { point(tail + (progress - tail) * Double($0) / 60) }
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
        }
        let first = scene.vertices.count
        ribbon(points, width: min(width, head), color: color, alpha: alpha, place: place, into: &scene)
        if scene.vertices.count > first { scene.items.append(.ribbons(first..<scene.vertices.count, additive: additive)) }
        guard let front = points.last else { return }
        let dot = scene.dots.count
        scene.dots.append(SkinGPUDot(centre: place.point(front), streak: .zero, radius: Float(head * place.scale), soft: 0,
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
                let centre = CGPoint(x: x * size.width + radius, y: (1 - y) * size.height + radius)
                scene.dots.append(SkinGPUDot(centre: place.point(centre), streak: streak, radius: Float(radius * place.scale),
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
                let points = (0...28).map { point(tailTime + (t - tailTime) * Double($0) / 28) }
                ribbon(points, width: headRadius, color: color, alpha: alpha, place: place, into: &scene)
            }
            guard alpha > 0.001 else { continue }
            scene.dots.append(SkinGPUDot(centre: place.point(head), streak: streak, radius: Float(headRadius * place.scale), soft: 0,
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
    private let quad: [MTLRenderPipelineState]
    private let dots: [MTLRenderPipelineState]
    private let ribbons: [MTLRenderPipelineState]
    private let glyphs: [MTLRenderPipelineState]
    private let present: MTLRenderPipelineState
    private let lens: MTLRenderPipelineState
    private let edgeBlur: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let glyphSampler: MTLSamplerState
    static let format = MTLPixelFormat.bgra8Unorm

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let library = device.makeDefaultLibrary() else {
            Log.error("render: gpu is unavailable: no Metal device or library", category: .background)
            return nil
        }
        func pipeline(_ vertex: String, _ fragment: String, additive: Bool?) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = Self.format
            if let additive {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
            }
            do { return try device.makeRenderPipelineState(descriptor: descriptor) }
            catch { Log.error("render: gpu pipeline \(fragment) failed: \(error.localizedDescription)", category: .background); return nil }
        }
        let modes = [false, true]
        let quad = modes.compactMap { pipeline("skinGPUQuadVertex", "skinGPUQuadFragment", additive: $0) }
        let dots = modes.compactMap { pipeline("skinGPUDotVertex", "skinGPUDotFragment", additive: $0) }
        let ribbons = modes.compactMap { pipeline("skinGPURibbonVertex", "skinGPURibbonFragment", additive: $0) }
        let glyphs = modes.compactMap { pipeline("skinGPUGlyphVertex", "skinGPUGlyphFragment", additive: $0) }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear; descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge; descriptor.tAddressMode = .clampToEdge
        let masks = MTLSamplerDescriptor()
        masks.minFilter = .linear; masks.magFilter = .linear; masks.mipFilter = .linear
        masks.sAddressMode = .clampToZero; masks.tAddressMode = .clampToZero
        guard quad.count == 2, dots.count == 2, ribbons.count == 2, glyphs.count == 2,
              let present = pipeline("skinGPUPresentVertex", "skinGPUPresentFragment", additive: nil),
              let lens = pipeline("skinGPUPresentVertex", "skinGPULensFragment", additive: nil),
              let edgeBlur = pipeline("skinGPUPresentVertex", "skinGPUEdgeBlurFragment", additive: nil),
              let sampler = device.makeSamplerState(descriptor: descriptor), let glyphSampler = device.makeSamplerState(descriptor: masks) else { return nil }
        self.device = device; self.queue = queue; self.atlas = SkinGPUGlyphAtlas(device: device)
        self.quad = quad; self.dots = dots; self.ribbons = ribbons; self.glyphs = glyphs
        self.present = present; self.lens = lens; self.edgeBlur = edgeBlur
        self.sampler = sampler; self.glyphSampler = glyphSampler
    }

    /// Offscreen textures the passes run through, each the size of the surface.
    struct Targets {
        var surface: MTLTexture
        var scratch: [MTLTexture]
    }

    /// The scene into `targets.surface`; the lens and its edge blur at that resolution; then the
    /// result scaled up to the drawable with grain.
    func draw(_ scene: SkinGPUScene, frame: SkinGPUFrame, lens: SkinGPULens?, targets: Targets, into drawable: CAMetalDrawable) {
        guard let buffer = queue.makeCommandBuffer() else { return }
        let fresh = atlas.takePending()
        if !fresh.isEmpty, let blit = buffer.makeBlitCommandEncoder() {
            for texture in fresh { blit.generateMipmaps(for: texture) }
            blit.endEncoding()
        }
        var frame = frame
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
                case .quad(var quad, let stops, let additive):
                    use(self.quad[additive ? 1 : 0])
                    encoder.setVertexBytes(&quad, length: MemoryLayout<SkinGPUQuad>.stride, index: 1)
                    encoder.setFragmentBytes(&quad, length: MemoryLayout<SkinGPUQuad>.stride, index: 1)
                    stops.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                case .dots(let range, let additive):
                    guard let dotBuffer else { continue }
                    use(dots[additive ? 1 : 0])
                    encoder.setVertexBuffer(dotBuffer, offset: range.lowerBound * MemoryLayout<SkinGPUDot>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: range.count)
                case .ribbons(let range, let additive):
                    guard let vertexBuffer else { continue }
                    use(ribbons[additive ? 1 : 0])
                    encoder.setVertexBuffer(vertexBuffer, offset: range.lowerBound * MemoryLayout<SkinGPUVertex>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: range.count)
                case .glyph(var glyph, let texture, let additive):
                    use(glyphs[additive ? 1 : 0])
                    encoder.setVertexBytes(&glyph, length: MemoryLayout<SkinGPUGlyph>.stride, index: 1)
                    encoder.setFragmentBytes(&glyph, length: MemoryLayout<SkinGPUGlyph>.stride, index: 1)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
            encoder.endEncoding()
        }
        atlas.endFrame()
        var source = targets.surface
        let surfaceSize = SIMD2(Float(targets.surface.width), Float(targets.surface.height))
        let share = Float(targets.surface.width) / max(1, Float(drawable.texture.width)) * frame.pointScale
        func post(_ state: MTLRenderPipelineState, axis: SIMD2<Float> = SIMD2(1, 0)) {
            guard let target = targets.scratch.first(where: { $0 !== source }), let lens else { return }
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
        if let lens, targets.scratch.count == 2 {
            if lens.bends { post(self.lens) }
            if lens.blurs { post(edgeBlur, axis: SIMD2(1, 0)); post(edgeBlur, axis: SIMD2(0, 1)) }
        }
        let final = MTLRenderPassDescriptor()
        final.colorAttachments[0].texture = drawable.texture
        final.colorAttachments[0].loadAction = .dontCare
        final.colorAttachments[0].storeAction = .store
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: final) {
            var uniforms = SkinGPUPost(size: SIMD2(Float(drawable.texture.width), Float(drawable.texture.height)),
                                       grain: frame.grain, time: frame.time, pointScale: frame.pointScale)
            encoder.setRenderPipelineState(present)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SkinGPUPost>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        buffer.present(drawable)
        buffer.commit()
    }
}

/// The surface: a Metal layer drawn on the display's own clock, at its full refresh rate, that
/// rests while nothing on it moves and wakes when an input it read changes.
final class SkinGPULayerNSView: NSView {
    let model = SkinGPULayerModel()
    private var link: CADisplayLink?
    private var surface: MTLTexture?
    private var scratch: [MTLTexture] = []
    private var clearedEmpty = false
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
        layer.pixelFormat = SkinGPURenderer.format
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        layer.framebufferOnly = true
        layer.isOpaque = false
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
        metal?.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    /// Draws again from the next display frame; called when SwiftUI hands over new inputs.
    func wake() { link?.isPaused = false }

    @objc private func tick(_ link: CADisplayLink) {
        let now = Date.timeIntervalSinceReferenceDate + (link.targetTimestamp - CACurrentMediaTime())
        var still = false
        // Whatever the frame read wakes the surface when it changes, so it may rest in between.
        withObservationTracking {
            draw(at: now)
            still = model.isStill()
        } onChange: { [weak self] in
            Task { @MainActor in self?.wake() }
        }
        if still { link.isPaused = true }
    }

    private func draw(at now: Double) {
        guard let renderer = SkinGPURenderer.shared, let metal, let inputs = model.inputs, bounds.width >= 1, bounds.height >= 1 else { return }
        let scale = metal.contentsScale
        let share = SkinRenderScale.factor(inputs.resolution * SkinRenderScale.factor(inputs.renderScale))
        let width = max(1, Int((bounds.width * scale * share).rounded())), height = max(1, Int((bounds.height * scale * share).rounded()))
        func target() -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SkinGPURenderer.format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return renderer.device.makeTexture(descriptor: descriptor)
        }
        if surface?.width != width || surface?.height != height {
            surface = target()
            scratch = []
        }
        // The lens passes ping-pong between two more surfaces.
        if inputs.lens != nil, scratch.isEmpty { scratch = [target(), target()].compactMap { $0 } }
        let camera = inputs.camera?(now)
        guard let surface, let frame = model.frame(at: now, pointScale: scale, camera: camera) else { return }
        let scene = model.scene(at: now, camera: camera, pixelsPerPoint: scale * share)
        // An empty surface draws one clear frame and then hides, so the window server has
        // nothing of it to composite until something appears again.
        if scene.items.isEmpty {
            if metal.isHidden { return }
            if clearedEmpty { metal.isHidden = true; return }
            clearedEmpty = true
        } else {
            clearedEmpty = false
            if metal.isHidden { metal.isHidden = false }
        }
        guard let drawable = metal.nextDrawable() else { return }
        renderer.draw(scene, frame: frame, lens: inputs.lens, targets: .init(surface: surface, scratch: scratch), into: drawable)
        SkinSceneRuntimeMetrics.shared.frame(inputs.metricsID, audioReaders: inputs.data.audioReaders.count)
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
