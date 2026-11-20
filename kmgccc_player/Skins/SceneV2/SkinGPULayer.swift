import AppKit
import Metal
import MotionKit
import Observation
import QuartzCore
import SwiftUI

/// `render: "gpu"` on a layer draws its children (rectangles, gradients, fog and particles) into
/// one Metal surface on its own display clock, instead of one SwiftUI view per child that SwiftUI
/// rebuilds, compares and lays out every frame. The surface draws at the layer's `resolution`
/// (times the render quality), and the layer's `grain` filter is added as it is scaled up, so the
/// whole backdrop costs two GPU passes. The children keep their usual properties and expressions.
enum SkinGPULayer {
    static let childTypes: Set<String> = ["shape", "gradient", "fog", "particles"]
    private static let childKeys: Set<String> = [
        "frame", "visible", "opacity", "blendMode", "depth", "hitTesting", "color", "colors", "stops", "mode", "radius", "start", "end",
        "shape", "size", "speed", "warp", "gain", "scrollX", "scrollY", "count", "seed", "soft", "lifetime", "angle", "spread", "trail",
        "turbulence", "wander", "curve", "filter",
    ]
    private static let cameraKeys: Set<String> = ["x", "y", "zoom", "perspective"]

    static func validate(_ children: [SkinCompiledSceneNode], camera: [String: SkinParameterValue]?, error: (String, String) -> SkinSceneError) throws {
        for (index, child) in children.enumerated() {
            let path = ".children[\(index)]"
            guard childTypes.contains(child.type) else { throw error(path, "render: gpu 的子节点限于 shape、gradient、fog、particles") }
            guard child.children.isEmpty, child.mask == nil, child.actions.isEmpty, child.watches.isEmpty, child.camera == nil else {
                throw error(path, "render: gpu 的子节点须是单个图形，不带子节点、遮罩、事件或镜头")
            }
            let keys = Set(child.properties.keys).union(child.variants.flatMap(\.properties.keys))
            if let key = keys.subtracting(childKeys).sorted().first { throw error(path + "." + key, "render: gpu 不支持 \(key)") }
            if child.type == "shape", let shape = child.properties["shape"] {
                guard case .expression(let value) = shape, value.constantValue?.textValue == "rectangle" else {
                    throw error(path + ".shape", "render: gpu 的 shape 限于 rectangle")
                }
            }
        }
        if let key = camera.map({ Set($0.keys).subtracting(cameraKeys) })?.sorted().first {
            throw error(".camera." + key, "render: gpu 的镜头限于 x、y、zoom、perspective")
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
    var pad = SIMD2<Float>.zero
    var color: SIMD4<Float>
}

struct SkinGPUScene {
    enum Item {
        /// `stops` holds eight colours and then the eight locations, as the shader reads them.
        case quad(SkinGPUQuad, stops: [SIMD4<Float>], additive: Bool)
        case dots(Range<Int>, additive: Bool)
        case ribbons(Range<Int>, additive: Bool)
    }

    var items: [Item] = []
    var dots: [SkinGPUDot] = []
    var vertices: [SkinGPUVertex] = []
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
    var camera: (@MainActor (Double) -> SkinSceneCamera)?
    /// Whether the layer's camera rests, given whether playback runs and scene time moves.
    var cameraStill: @MainActor (Bool, Bool) -> Bool
    var metricsID: String
}

@MainActor
final class SkinGPULayerModel {
    var inputs: SkinGPULayerInputs?
    private var followers: [ObjectIdentifier: SkinFollowers] = [:]
    private var caches: [ObjectIdentifier: SkinNodeValueCache] = [:]
    private var grainTime = 0.0

    private func followers(for node: SkinCompiledSceneNode) -> SkinFollowers {
        if let existing = followers[ObjectIdentifier(node)] { return existing }
        let created = SkinFollowers()
        followers[ObjectIdentifier(node)] = created
        return created
    }

    private func cache(for node: SkinCompiledSceneNode) -> SkinNodeValueCache {
        if let existing = caches[ObjectIdentifier(node)] { return existing }
        let created = SkinNodeValueCache()
        caches[ObjectIdentifier(node)] = created
        return created
    }

    /// True when nothing on the surface moves until an input changes.
    func isStill() -> Bool {
        guard let inputs, inputs.active else { return true }
        let timeMoves = inputs.data.timeMoves(playing: inputs.playing)
        for child in inputs.node.children where child.tier == .frame || ["particles", "fog"].contains(child.type) {
            let followers = followers(for: child)
            if !child.frameInputs.isStill(playing: inputs.playing, timeMoves: timeMoves, following: followers.isMoving) { return false }
        }
        if !inputs.cameraStill(inputs.playing, timeMoves) { return false }
        return !(inputs.grain > 0 && inputs.moves && timeMoves)
    }

    func frame(at now: Double, pointScale: Double) -> SkinGPUFrame? {
        guard let inputs else { return nil }
        if inputs.moves, inputs.data.timeMoves(playing: inputs.playing) { grainTime = now.truncatingRemainder(dividingBy: 3600) }
        return SkinGPUFrame(size: SIMD2(Float(inputs.size.width), Float(inputs.size.height)), time: Float(grainTime),
                            grain: Float(inputs.grain), pointScale: Float(pointScale))
    }

    func scene(at now: Double) -> SkinGPUScene {
        var scene = SkinGPUScene()
        guard let inputs else { return scene }
        let camera = inputs.camera?(now)
        for child in inputs.node.children {
            var context = SkinEvaluationContext(data: inputs.data, locals: inputs.locals, now: now, live: inputs.live)
            context.locals["self"] = .record([:])
            context.locals["parent"] = .record(["width": .number(inputs.size.width), "height": .number(inputs.size.height)])
            context.motionTokens = inputs.motionTokens
            context.moves = inputs.moves
            context.followers = followers(for: child)
            context.memo = SkinLetMemo()
            if child.hidesWithoutTransition, child.properties["visible"]?.evaluate(context).isTruthy == false { continue }
            let values = child.values(context, cache: cache(for: child))
            guard values["visible"]?.isTruthy != false else { continue }
            let opacity = values["opacity"]?.number(1) ?? 1
            guard opacity > 0.001 else { continue }
            let additive = values["blendMode"]?.textValue == "plusLighter"
            let place = placement(values, camera: camera, inputs: inputs)
            switch child.type {
            case "shape":
                let color = values["color"]?.colorValue ?? inputs.data.theme["theme.appForeground.primary"]?.colorValue
                var quad = place.quad(kind: 0, opacity: opacity)
                quad.color = premultiplied(color)
                scene.items.append(.quad(quad, stops: Self.noStops, additive: additive))
            case "gradient":
                scene.items.append(.quad(gradient(values, place: place, opacity: opacity), stops: stops(values), additive: additive))
            case "fog":
                scene.items.append(.quad(fog(values, place: place, opacity: opacity, now: now, inputs: inputs), stops: Self.noStops, additive: additive))
            case "particles":
                particles(values, place: place, opacity: opacity, additive: additive, now: now, data: inputs.data, into: &scene)
            default: break
            }
        }
        return scene
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

    /// The child's frame in the layer, after the camera: the same centre and scale a positioned
    /// child gets from `SkinCameraFollow`.
    private func placement(_ values: [String: SkinValue], camera: SkinSceneCamera?, inputs: SkinGPULayerInputs) -> Placement {
        let frame = values["frame"] ?? .null
        let viewport = inputs.live?.size ?? inputs.data.viewportSize
        func dimension(_ value: SkinValue, horizontal: Bool, signed: Bool = false) -> Double? {
            skinDimension(value, horizontal: horizontal, signed: signed, viewport: viewport, parent: inputs.size).map(Double.init)
        }
        let width = dimension(frame[member: "width"], horizontal: true) ?? dimension(frame[member: "size"], horizontal: true)
        let height = dimension(frame[member: "height"], horizontal: false) ?? dimension(frame[member: "size"], horizontal: false)
        let size = CGSize(width: width ?? inputs.size.width, height: height ?? inputs.size.height)
        let anchorName = frame[member: "anchor"].textValue
        let anchor = unitPoint(anchorName.isEmpty ? "center" : anchorName)
        let x = dimension(frame[member: "x"], horizontal: true, signed: true) ?? inputs.size.width / 2
        let y = dimension(frame[member: "y"], horizontal: false, signed: true) ?? inputs.size.height / 2
        let centre = CGPoint(x: x + (0.5 - anchor.x) * (width ?? 0), y: y + (0.5 - anchor.y) * (height ?? 0))
        var point = centre, scale = 1.0
        if let camera { (point, scale) = camera.place(centre, depth: values["depth"]?.number() ?? 0, in: inputs.size) }
        return Placement(origin: CGPoint(x: point.x - size.width / 2 * scale, y: point.y - size.height / 2 * scale), scale: scale, size: size)
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

    private func premultiplied(_ color: OKLCHColor?, alpha: Double = 1) -> SIMD4<Float> {
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
    private let queue: MTLCommandQueue
    private let quad: [MTLRenderPipelineState]
    private let dots: [MTLRenderPipelineState]
    private let ribbons: [MTLRenderPipelineState]
    private let present: MTLRenderPipelineState
    private let sampler: MTLSamplerState
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
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear; descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge; descriptor.tAddressMode = .clampToEdge
        guard quad.count == 2, dots.count == 2, ribbons.count == 2, let present = pipeline("skinGPUPresentVertex", "skinGPUPresentFragment", additive: nil),
              let sampler = device.makeSamplerState(descriptor: descriptor) else { return nil }
        self.device = device; self.queue = queue
        self.quad = quad; self.dots = dots; self.ribbons = ribbons; self.present = present; self.sampler = sampler
    }

    func draw(_ scene: SkinGPUScene, frame: SkinGPUFrame, surface: MTLTexture, into drawable: CAMetalDrawable) {
        guard let buffer = queue.makeCommandBuffer() else { return }
        var frame = frame
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = surface
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setVertexBytes(&frame, length: MemoryLayout<SkinGPUFrame>.stride, index: 0)
            let dotBuffer = scene.dots.isEmpty ? nil : device.makeBuffer(bytes: scene.dots, length: MemoryLayout<SkinGPUDot>.stride * scene.dots.count)
            let vertexBuffer = scene.vertices.isEmpty ? nil : device.makeBuffer(bytes: scene.vertices, length: MemoryLayout<SkinGPUVertex>.stride * scene.vertices.count)
            for item in scene.items {
                switch item {
                case .quad(var quad, let stops, let additive):
                    encoder.setRenderPipelineState(self.quad[additive ? 1 : 0])
                    encoder.setVertexBytes(&quad, length: MemoryLayout<SkinGPUQuad>.stride, index: 1)
                    encoder.setFragmentBytes(&quad, length: MemoryLayout<SkinGPUQuad>.stride, index: 1)
                    stops.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                case .dots(let range, let additive):
                    guard let dotBuffer else { continue }
                    encoder.setRenderPipelineState(dots[additive ? 1 : 0])
                    encoder.setVertexBuffer(dotBuffer, offset: range.lowerBound * MemoryLayout<SkinGPUDot>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: range.count)
                case .ribbons(let range, let additive):
                    guard let vertexBuffer else { continue }
                    encoder.setRenderPipelineState(ribbons[additive ? 1 : 0])
                    encoder.setVertexBuffer(vertexBuffer, offset: range.lowerBound * MemoryLayout<SkinGPUVertex>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: range.count)
                }
            }
            encoder.endEncoding()
        }
        let final = MTLRenderPassDescriptor()
        final.colorAttachments[0].texture = drawable.texture
        final.colorAttachments[0].loadAction = .dontCare
        final.colorAttachments[0].storeAction = .store
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: final) {
            encoder.setRenderPipelineState(present)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<SkinGPUFrame>.stride, index: 0)
            encoder.setFragmentTexture(surface, index: 0)
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
        if surface?.width != width || surface?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SkinGPURenderer.format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            surface = renderer.device.makeTexture(descriptor: descriptor)
        }
        guard let surface, let frame = model.frame(at: now, pointScale: scale) else { return }
        let scene = model.scene(at: now)
        guard let drawable = metal.nextDrawable() else { return }
        renderer.draw(scene, frame: frame, surface: surface, into: drawable)
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
