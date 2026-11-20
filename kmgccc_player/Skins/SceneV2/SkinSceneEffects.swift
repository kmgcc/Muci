import AppKit
import MotionKit
import SwiftUI

/// `filter`: shader effects over the node's rendered subtree, applied in order: the built-in
/// presets, or `custom` functions from a precompiled `.metallib` in the package.
/// The node is padded by each filter's reach first, so offsets and glows are not cut at its frame.
/// Moving presets keep their own display timeline around the effect only, so the subtree is not
/// rebuilt per frame. Reduced motion drops glitch and wave; a dormant node keeps its effects off.
/// A chain with a sampling pass runs on a surface of `skinRenderScale` times the subtree's
/// resolution, its point radii scaled to match; package `custom` shaders keep full resolution.
struct SkinSceneFilters: ViewModifier {
    let filters: [SkinValue]
    var dormant = false
    /// Scene time stands still: moving presets keep drawing at their last time without a timeline.
    var frozen = false
    @Environment(\.skinSceneIsActive) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.skinPackageResources) private var root
    @Environment(\.skinRenderScale) private var renderScale

    func body(content: Content) -> some View {
        let moves = motionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full
        let animated = moves && filters.contains { filter in
            switch filter[member: "type"].textValue {
            case "glitch", "grain", "wave": true
            case "scanlines": filter[member: "speed"].number() != 0
            case "custom": filter[member: "animated"].isTruthy
            default: false
            }
        }
        let scale = Self.reduces(filters) ? SkinRenderScale.factor(renderScale) : 1
        TimelineView(.animation(minimumInterval: nil, paused: !animated || !active || dormant || frozen)) { timeline in
            SkinRenderScale.reduced(AnyView(content), scale: scale) { surface in
                Self.apply(surface, filters: filters, time: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600),
                           moves: moves, enabled: !dormant, root: root, scale: scale)
            }
        }
    }

    /// Colour-only chains read one pixel each, so a smaller surface saves little and coarsens the
    /// grain. A package shader's arguments are in points the host cannot rescale.
    private static func reduces(_ filters: [SkinValue]) -> Bool {
        var samples = false
        for filter in filters {
            switch filter[member: "type"].textValue {
            case "custom": return false
            case "chromatic", "glitch", "motionBlur", "wave", "fov": samples = true
            default: break
            }
        }
        return samples
    }

    /// `scale` is the surface's share of the subtree's resolution; point values are multiplied by it.
    private static func apply(_ content: AnyView, filters: [SkinValue], time: Double, moves: Bool, enabled: Bool, root: URL?, scale: Double) -> AnyView {
        var view = content
        let library = ShaderLibrary.default
        for filter in filters {
            switch filter[member: "type"].textValue {
            case "chromatic":
                let amount = filter[member: "amount"].number(2) * scale
                let shader = library.skinFxChromatic(.float(amount), .float(filter[member: "angle"].number() * .pi / 180))
                view = padded(view, reach: abs(amount)) { $0.layerEffect(shader, maxSampleOffset: CGSize(width: abs(amount), height: abs(amount)), isEnabled: enabled) }
            case "glitch" where moves:
                let amount = filter[member: "amount"].number(12) * scale
                let shader = library.skinFxGlitch(.float(time), .float(amount), .float(filter[member: "slice"].number(6) * scale),
                                                  .float(filter[member: "rate"].number(8)), .float(filter[member: "intensity"].number(0.3).clamped01))
                view = padded(view, reach: abs(amount) * 1.2) { $0.layerEffect(shader, maxSampleOffset: CGSize(width: abs(amount) * 1.2, height: 0), isEnabled: enabled) }
            case "motionBlur":
                let x = filter[member: "x"].number() * scale, y = filter[member: "y"].number() * scale
                let reach = max(abs(x), abs(y)) / 2
                let shader = library.skinFxMotionBlur(.float2(x, y), .float(filter[member: "samples"].number(12)))
                view = padded(view, reach: reach) { $0.layerEffect(shader, maxSampleOffset: CGSize(width: abs(x) / 2, height: abs(y) / 2), isEnabled: enabled && reach > 0.25 * scale) }
            case "scanlines":
                let shader = library.skinFxScanlines(.float(time), .float(filter[member: "spacing"].number(3) * scale),
                                                     .float(filter[member: "intensity"].number(0.25).clamped01), .float(moves ? filter[member: "speed"].number() * scale : 0))
                view = AnyView(view.colorEffect(shader, isEnabled: enabled))
            case "grain":
                view = AnyView(view.colorEffect(library.skinFxGrain(.float(moves ? time : 0), .float(filter[member: "amount"].number(0.08))), isEnabled: enabled))
            case "wave" where moves:
                let amplitude = filter[member: "amplitude"].number(4) * scale
                let shader = library.skinFxWave(.float(time), .float(amplitude), .float(filter[member: "wavelength"].number(180) * scale), .float(filter[member: "speed"].number(1.5)))
                view = padded(view, reach: abs(amplitude)) { $0.distortionEffect(shader, maxSampleOffset: CGSize(width: abs(amplitude), height: abs(amplitude)), isEnabled: enabled) }
            case "fov":
                view = SkinSceneFOV.apply(view, filter: filter, enabled: enabled, scale: scale)
            case "custom":
                view = custom(view, filter: filter, time: moves ? time : 0, enabled: enabled, root: root)
            default: break
            }
        }
        return view
    }

    /// A package's own `[[stitchable]]` function. After SwiftUI's own arguments it receives
    /// `float2 size` (the padded canvas) and `float time`, then `args` in order: numbers as float,
    /// lists of 2 to 4 numbers as float2 to float4, colours as half4.
    private static func custom(_ view: AnyView, filter: SkinValue, time: Double, enabled: Bool, root: URL?) -> AnyView {
        guard let library = SkinShaderLibraries.library(filter[member: "library"].textValue, root: root) else { return view }
        let function = ShaderFunction(library: library, name: filter[member: "function"].textValue)
        let arguments = filter[member: "args"].listValue.prefix(16).map { SkinShaderLibraries.argument($0, root: root) }
        let reach = max(0, filter[member: "reach"].number())
        let offset = CGSize(width: reach, height: reach)
        switch filter[member: "kind"].textValue {
        case "color":
            return AnyView(view.visualEffect { effect, proxy in
                effect.colorEffect(Shader(function: function, arguments: [.float2(proxy.size), .float(time)] + arguments), isEnabled: enabled)
            })
        case "distortion":
            return padded(view, reach: reach) { padded in
                padded.visualEffect { effect, proxy in
                    effect.distortionEffect(Shader(function: function, arguments: [.float2(proxy.size), .float(time)] + arguments), maxSampleOffset: offset, isEnabled: enabled)
                }
            }
        default:
            return padded(view, reach: reach) { padded in
                padded.visualEffect { effect, proxy in
                    effect.layerEffect(Shader(function: function, arguments: [.float2(proxy.size), .float(time)] + arguments), maxSampleOffset: offset, isEnabled: enabled)
                }
            }
        }
    }

    /// Grows the effect's canvas by `reach` without changing the node's layout. The view's
    /// structure is the same at any reach, so a reach passing through zero keeps the subtree's
    /// identity and state (particles, timelines).
    static func padded(_ view: AnyView, reach: Double, effect: (AnyView) -> some View) -> AnyView {
        let reach = ceil(max(0, reach))
        return AnyView(effect(AnyView(view.padding(reach))).padding(-reach))
    }
}

/// The render quality setting for skin scenes: offscreen surfaces (filters, bloom, rasterized
/// camera layers) render at this share of the display's resolution and are scaled back up.
/// Hit testing and layout keep full size; the transforms cancel out.
enum SkinRenderScale {
    static func factor(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0.25, value)) : 1
    }

    /// Lays `content` out at full size, draws it `scale` times smaller into a surface that size,
    /// runs `effect` on that surface and scales the result back. Offscreen passes render in their
    /// own coordinate space at the display scale and keep that resolution under later
    /// transforms, so this is what makes a pass cost fewer pixels. The structure is the same at
    /// any scale, so changing the setting keeps the subtree's identity and state.
    static func reduced(_ content: AnyView, scale: Double, effect: (AnyView) -> some View) -> AnyView {
        let scale = CGFloat(factor(scale))
        let surface = AnyView(SkinRenderScaleFrame(factor: scale) { content.scaleEffect(scale, anchor: .topLeading) })
        return AnyView(SkinRenderScaleFrame(factor: 1 / scale) { effect(surface).scaleEffect(1 / scale, anchor: .topLeading) })
    }
}

/// Proposes `1 / factor` of its proposal to its one subview, places it at the top leading corner
/// and reports `factor` of the subview's size. Paired with a `scaleEffect` of the same factor,
/// the subview looks unchanged while the frame around it is resized.
private struct SkinRenderScaleFrame: Layout {
    let factor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(inner(proposal))
        return CGSize(width: size.width * factor, height: size.height * factor)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: inner(proposal))
    }

    private func inner(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 / factor }, height: proposal.height.map { $0 / factor })
    }
}

/// Precompiled package shader libraries, loaded once per file.
@MainActor
enum SkinShaderLibraries {
    private static var loaded: [URL: ShaderLibrary] = [:]

    static func library(_ path: String, root: URL?) -> ShaderLibrary? {
        guard path.hasSuffix(".metallib"), let root, let url = try? SkinResourceResolver.resolve(path, root: root) else { return nil }
        if let library = loaded[url] { return library }
        let library = ShaderLibrary(url: url)
        loaded[url] = library
        return library
    }

    private static var images: [URL: Image] = [:]

    /// Numbers as float; lists of 2 to 4 numbers as float2 to float4; longer lists (such as
    /// `spectrum(64)`) as a float array, which the function receives as `device const float *`
    /// and `int`; colours as half4; `{image: path}` as a package image, `texture2d<half>`.
    static func argument(_ value: SkinValue, root: URL?) -> Shader.Argument {
        if value.type == .record {
            let path = value[member: "image"].textValue
            return .image((path.isEmpty ? nil : image(path, root: root)) ?? Image(nsImage: NSImage(size: NSSize(width: 1, height: 1))))
        }
        if let color = value.colorValue, value.type == .color { return .color(color.swiftUIColor) }
        let numbers = value.listValue.prefix(4096).map { Float($0.number()) }
        switch numbers.count {
        case 2: return .float2(numbers[0], numbers[1])
        case 3: return .float3(numbers[0], numbers[1], numbers[2])
        case 4: return .float4(numbers[0], numbers[1], numbers[2], numbers[3])
        case 5...: return .floatArray(numbers)
        default: return .float(Float(value.number()))
        }
    }

    private static func image(_ path: String, root: URL?) -> Image? {
        guard let root, let url = try? SkinResourceResolver.resolve(path, root: root) else { return nil }
        if let image = images[url] { return image }
        guard let image = NSImage(contentsOf: url).map(Image.init(nsImage:)) else { return nil }
        images[url] = image
        return image
    }
}

/// `bloom`: bright parts of the subtree glow by `radius`, added onto it like plusLighter.
struct SkinSceneBloom: ViewModifier {
    let value: SkinValue
    var dormant = false
    @Environment(\.skinRenderScale) private var renderScale

    func body(content: Content) -> some View {
        let scale = SkinRenderScale.factor(renderScale)
        let radius = max(1, value.numberValue ?? value[member: "radius"].number(16)) * scale
        let intensity = value[member: "intensity"].number(0.8)
        let shader = ShaderLibrary.default.skinFxBloom(.float(radius), .float(intensity), .float(value[member: "threshold"].number().clamped01))
        SkinRenderScale.reduced(AnyView(content), scale: scale) { surface in
            SkinSceneFilters.padded(surface, reach: radius) {
                $0.layerEffect(shader, maxSampleOffset: CGSize(width: radius, height: radius), isEnabled: !dormant && intensity > 0.001)
            }
        }
    }
}

/// `fog`: domain-warped fbm between two colours, drawn at a third of the resolution and scaled up;
/// the noise is soft, so the loss does not show.
struct SkinSceneFog: View {
    let low: Color
    let high: Color
    let time: Double
    let feature: Double
    let speed: Double
    let warp: Double
    let gain: Double
    /// Points the field has slid by; it is endless, so any distance shows new fog.
    var scroll = CGPoint.zero
    private let reduction = 3.0

    var body: some View {
        GeometryReader { proxy in
            let size = CGSize(width: max(1, proxy.size.width / reduction), height: max(1, proxy.size.height / reduction))
            Rectangle().fill(.white)
                .frame(width: size.width, height: size.height)
                .colorEffect(ShaderLibrary.default.skinFxFog(.float(time), .float(max(1, feature) / reduction), .float(speed), .float(warp), .float(gain), .color(low), .color(high),
                                                             .float2(scroll.x / reduction, scroll.y / reduction)))
                .scaleEffect(reduction, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}

/// `camera` on a layer: it looks at layer point centre + (`x`, `y`) and zooms by `zoom`, both
/// scaled by `1 / (1 + depth)`, so far children move less. The pan is in layer points before the
/// zoom, so a camera can follow content laid out in layer coordinates. Rotations turn the whole layer.
nonisolated struct SkinSceneCamera: Equatable, Sendable {
    var x: Double, y: Double, zoom: Double
    var rotation: Double, rotationX: Double, rotationY: Double, perspective: Double
    var rasterize: Bool

    @MainActor init(_ value: SkinValue) {
        x = value[member: "x"].number(); y = value[member: "y"].number(); zoom = max(0.05, value[member: "zoom"].number(1))
        rotation = value[member: "rotation"].number(); rotationX = value[member: "rotationX"].number(); rotationY = value[member: "rotationY"].number()
        perspective = value[member: "perspective"].number(0.5)
        rasterize = value[member: "rasterize"].isTruthy
    }

    /// The child's centre and scale after the camera, for a child at `depth`.
    func place(_ point: CGPoint, depth: Double?, in size: CGSize) -> (point: CGPoint, scale: Double) {
        guard let depth else { return (point, 1) }
        let factor = 1 / (1 + max(-0.9, depth))
        let scale = 1 + (zoom - 1) * factor
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        return (CGPoint(x: centre.x + (point.x - centre.x - x * factor) * scale, y: centre.y + (point.y - centre.y - y * factor) * scale), scale)
    }

    /// The depth-zero camera transform, applied to the whole stage.
    func layerTransform(in size: CGSize) -> CGAffineTransform {
        let origin = place(.zero, depth: 0, in: size).point
        return CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: origin.x, ty: origin.y)
    }
}

/// Evaluates a per-frame camera at most once per display frame, for every child that asks.
@MainActor
final class SkinCameraSource {
    var evaluate: @MainActor (Double) -> SkinSceneCamera = { _ in SkinSceneCamera(.null) }
    var inputs = SkinFrameInputs(frame: [], always: false)
    /// The layer's `follow()` springs, so its children's timelines rest with them.
    var followers: SkinFollowers?
    private var cached: (now: Double, camera: SkinSceneCamera)?

    func isStill(data: SkinSceneData, playing: Bool) -> Bool {
        inputs.isStill(playing: playing, timeMoves: data.timeMoves(playing: playing), following: followers?.isMoving == true)
    }

    func camera(at now: Double) -> SkinSceneCamera {
        if let cached, cached.now == now { return cached.camera }
        let camera = evaluate(now)
        cached = (now, camera)
        return camera
    }
}

/// What a layer hands its children: a camera that changes only with data (`steady`), or the
/// source to ask each frame. The source is compared by identity, so per-frame motion never
/// re-renders the children themselves.
nonisolated struct SkinCameraLink: Equatable {
    enum Placement: Equatable {
        case local, sharedLayer, compensatedSubtree
    }

    let source: SkinCameraSource
    let steady: SkinSceneCamera?
    var placement: Placement = .local

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source === rhs.source && lhs.steady == rhs.steady && lhs.placement == rhs.placement
    }
}

/// The outer layer transform and its child placements use the same camera sample.
nonisolated struct SkinSharedCameraFrame: Equatable {
    let source: SkinCameraSource
    let camera: SkinSceneCamera

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source === rhs.source && lhs.camera == rhs.camera
    }
}

extension EnvironmentValues {
    @Entry var skinSharedCameraFrame: SkinSharedCameraFrame?
    /// The render quality setting's share of display resolution for the scene's offscreen
    /// surfaces; see `SkinRenderScale`. 1 outside a skin host.
    @Entry var skinRenderScale: Double = 1
}

/// Moves one positioned child with its layer's camera: geometry only, on a timeline that wraps
/// the transform and not the child.
struct SkinCameraFollow: ViewModifier {
    let link: SkinCameraLink
    let centre: CGPoint
    /// A compensated repeat wrapper has no camera placement of its own.
    let depth: Double?
    let size: CGSize
    let paused: Bool
    @Environment(\.skinSharedCameraFrame) private var sharedFrame

    func body(content: Content) -> some View {
        if link.placement == .sharedLayer, depth == 0 {
            content
        } else if link.placement != .local, let sharedFrame, sharedFrame.source === link.source {
            place(content, camera: sharedFrame.camera)
        } else if let steady = link.steady {
            place(content, camera: steady)
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: paused)) { timeline in
                place(content, camera: link.source.camera(at: timeline.date.timeIntervalSinceReferenceDate))
            }
        }
    }

    private func place(_ content: Content, camera: SkinSceneCamera) -> some View {
        var placed = camera.place(centre, depth: depth, in: size)
        if link.placement == .sharedLayer {
            // Leave only this child's difference from the shared pan and zoom in its placement.
            placed.point = placed.point.applying(camera.layerTransform(in: size).inverted())
            placed.scale /= camera.zoom
        }
        return content.scaleEffect(placed.scale).offset(x: placed.point.x - centre.x, y: placed.point.y - centre.y)
    }
}

/// Turns a camera layer as a whole.
struct SkinCameraTurn: ViewModifier {
    let link: SkinCameraLink
    let size: CGSize
    let paused: Bool
    @Environment(\.displayScale) private var displayScale
    @Environment(\.skinRenderScale) private var renderScale

    func body(content: Content) -> some View {
        if let steady = link.steady {
            turn(content, camera: steady)
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: paused)) { timeline in
                turn(content, camera: link.source.camera(at: timeline.date.timeIntervalSinceReferenceDate))
            }
        }
    }

    private func turn(_ content: Content, camera: SkinSceneCamera) -> some View {
        Group {
            if link.placement == .sharedLayer {
                sharedStage(content, camera: camera)
            } else if camera.rasterize {
                // Give the perspective transforms one shared surface for overlapping text and shapes.
                SkinRenderScale.reduced(AnyView(content), scale: renderScale) { $0.drawingGroup() }
            } else {
                content
            }
        }
        .rotation3DEffect(.degrees(camera.rotationX), axis: (x: 1, y: 0, z: 0), perspective: camera.perspective)
        .rotation3DEffect(.degrees(camera.rotationY), axis: (x: 0, y: 1, z: 0), perspective: camera.perspective)
        .rotationEffect(.degrees(camera.rotation))
    }

    @ViewBuilder
    private func sharedStage(_ content: Content, camera: SkinSceneCamera) -> some View {
        let sampled = content.environment(\.skinSharedCameraFrame, SkinSharedCameraFrame(source: link.source, camera: camera))
        if camera.rasterize {
            rasterizedStage(sampled, camera: camera)
        } else {
            // Platform-backed children keep their native surfaces inside the shared camera layer.
            sampled.transformEffect(camera.layerTransform(in: size))
        }
    }

    private func rasterizedStage(_ content: some View, camera: SkinSceneCamera) -> some View {
        // Zoomed out, the inverse viewport holds 1 / zoom² of the screen's pixels. Drawn at full
        // size and shrunk afterwards, every glyph, glow and blur in it cost that much more, and the
        // bitmap was resized as the zoom eased. The bitmap takes the zoom-out itself, so it stays
        // about the size of the screen; zooming in still scales the finished bitmap. The render
        // scale shrinks it the same way, and the transform below scales it back up.
        let inner = min(1, camera.zoom) * SkinRenderScale.factor(renderScale)
        let transform = camera.layerTransform(in: size).scaledBy(x: 1 / inner, y: 1 / inner)
        let viewport = CGRect(origin: .zero, size: size)
        let pixel = 1 / max(1, displayScale)
        let tile = 32 * pixel
        // Keep the inverse viewport and a sampling border inside the bitmap. Align its edges
        // to backing pixels so a bounds change does not shift the raster's sampling grid.
        let source = viewport.applying(transform.inverted()).insetBy(dx: -pixel, dy: -pixel)
        let left = floor(source.minX / tile) * tile
        let top = floor(source.minY / tile) * tile
        let right = ceil(source.maxX / tile) * tile
        let bottom = ceil(source.maxY / tile) * tile
        let insets = EdgeInsets(top: -top, leading: -left, bottom: bottom - size.height, trailing: right - size.width)
        let restore = EdgeInsets(top: top, leading: left, bottom: size.height - bottom, trailing: size.width - right)
        return content
            .scaleEffect(inner, anchor: .topLeading)
            .padding(insets)
            .drawingGroup()
            .padding(restore)
            .transformEffect(transform)
            .clipped()
    }
}

/// Plain texts with `glyphMotion` time their glyphs from when the text last changed. A reference
/// type, so the renderer can restart the clock in the same frame the text changes.
final class SkinGlyphClock {
    private var key: String?
    private var start = 0.0

    func start(for key: String, now: Double) -> Double {
        if key != self.key { self.key = key; start = now }
        return start
    }
}

/// The display padding of a text with `glyphMotion`, kept while the text stays the same and
/// only ever grown. A reference type, so the renderer can update it while drawing a frame.
final class SkinGlyphPadding {
    private var key: String?
    private var value = 0.0

    func stable(for key: String, wanted: Double) -> Double {
        if key != self.key { self.key = key; value = wanted } else { value = max(value, wanted) }
        return value
    }
}
