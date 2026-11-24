import AppKit
import MotionKit
import SwiftUI

struct SkinSceneV2View: View {
    let program: SkinSceneProgram
    let snapshot: SkinSceneSnapshot
    let viewport: SkinViewport
    let components: SkinComponents
    @State private var data = SkinSceneData()
    @State private var fonts = SkinFontLease()
    @State private var resourceError: String?
    @State private var metricsID = UUID().uuidString
    @State private var didPrepare = false
    @State private var readsBackdrop = false
    @Environment(\.skinPackageResources) private var resources
    @Environment(\.skinPackageFonts) private var fontPaths
    @Environment(\.skinSceneLyricsVisible) private var lyricsVisible
    @Environment(\.skinScenePresentation) private var presentation
    @Environment(\.skinSceneHost) private var host

    var body: some View {
        let nodes = Group {
            if didPrepare { SkinSceneNodeV2View(node: program.root, data: data, components: components, size: viewport.size) }
            else { Color.clear }
        }
            // Layout follows the window as it is dragged: units read this frame's size, and
            // implicit animations sit out the resize so nodes do not spring after the edge.
            .environment(\.skinSceneLiveViewport, SkinLiveViewport(size: viewport.size, surface: viewport.surface,
                                                                   lyricsVisible: lyricsVisible, presentation: presentation))
            .transaction(value: viewport.size) { $0.disablesAnimations = true }
        (host?.backdrop(AnyView(nodes), snapshot: snapshot, size: viewport.size, enabled: readsBackdrop) ?? AnyView(nodes))
            .coordinateSpace(.named(SkinSceneSpace.name))
            .background {
                host?.feeds(.init(data: data, program: program, snapshot: snapshot, viewport: viewport, parameters: components.parameters))
            }
            .onAppear {
                guard !didPrepare else { return }
                data.scripts = program.scripts
                didPrepare = true
                readsBackdrop = program.root.readsBackdrop
                SkinSceneRuntimeMetrics.shared.mount(metricsID, nodes: program.nodeCount)
                data.initialState = program.state; data.resetState(program.state)
                do { try fonts.load(paths: fontPaths, root: resources) }
                catch { resourceError = error.localizedDescription }
            }
            // A reloaded package brings a fresh script context.
            .onChange(of: program.scripts.map(ObjectIdentifier.init)) { data.scripts = program.scripts }
            .onDisappear { fonts.release(); didPrepare = false; SkinSceneRuntimeMetrics.shared.unmount(metricsID) }
            .environment(\.skinSceneMetricsID, metricsID)
            .environment(\.skinSceneData, data)
            .environment(\.skinMotionCustomTokens, program.motion.tokens)
            .alert("皮肤资源", isPresented: Binding(get: { resourceError != nil }, set: { if !$0 { resourceError = nil } })) {
                Button("好", role: .cancel) { resourceError = nil }
            } message: { Text(resourceError ?? "") }
            .modifier(SkinSceneEventModifier(program: program, data: data))
    }
}

struct SkinSceneNodeV2View: View {
    let node: SkinCompiledSceneNode
    let data: SkinSceneData
    let components: SkinComponents
    let size: CGSize
    var locals: [String: SkinValue] = [:]
    var positioned = false
    /// A `repeat` directly inside `scroll` builds only the cells in view.
    var lazy = false
    /// The enclosing layer's camera, for a positioned child.
    var camera: SkinCameraLink?
    @Environment(\.skinSceneIsActive) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.skinPackageResources) private var resources
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @Environment(\.skinSceneActions) private var actions
    @Environment(\.skinSceneMetricsID) private var metricsID
    @Environment(\.skinSceneLiveViewport) private var live
    @Environment(\.skinRenderScale) private var renderScale
    @State private var hovered = false
    @State private var dragging = false
    @State private var animationStart = Date.timeIntervalSinceReferenceDate
    @State private var backdropReading: SkinBackdropReading?
    @State private var measuredFrame: CGRect?
    @State private var glyphClock = SkinGlyphClock()
    @State private var glyphPadding = SkinGlyphPadding()
    @State private var valueCache = SkinNodeValueCache()
    @State private var cameraSource = SkinCameraSource()
    @State private var followers = SkinFollowers()
    /// Set once a hidden node's transition has had its time; see `render(at:)`.
    @State private var collapsed = false
    @Environment(\.skinBackdropReading) private var inheritedReading
    @Environment(\.skinSceneHost) private var host
    @Namespace private var glassNamespace

    /// A `render: "gpu"` layer draws on its own display clock and evaluates its own `visible`
    /// and `opacity` there, so its view updates only when data changes.
    private var gpuSurface: Bool {
        guard node.type == "layer", case .expression(let render)? = node.properties["render"] else { return false }
        return render.constantValue?.textValue == "gpu" && SkinGPURenderer.shared != nil
    }

    private var needsFrames: Bool {
        if gpuSurface { return false }
        return node.tier == .frame || node.watches.contains(where: { $0.value.tier == .frame }) || node.properties["keyframes"] != nil || node.properties["glyphMotion"] != nil
            || ["spectrum", "waveform", "meter", "particles", "shader", "fog", "lyricLine", "comet"].contains(node.type)
    }

    /// Clock, lyric and audio inputs stand still while paused; scene time once the playback flow
    /// settles; follow springs once they land.
    private var framesPaused: Bool {
        // Read so a seek while paused draws the node once at the new position; its watches
        // then see the new line.
        _ = data.seekRevision
        let playing = components.snapshot.playback.isPlaying
        return !active || node.frameInputs.isStill(playing: playing, timeMoves: data.timeMoves(playing: playing), following: followers.isMoving)
    }

    private var moves: Bool { configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full }

    var body: some View {
        Group {
            if needsFrames {
                TimelineView(.animation(minimumInterval: nil, paused: framesPaused)) { timeline in
                    render(at: timeline.date.timeIntervalSinceReferenceDate)
                        .onChange(of: timeline.date) { _, _ in SkinSceneRuntimeMetrics.shared.frame(metricsID, audioReaders: data.audioReaders.count) }
                }
            } else { render(at: Date.timeIntervalSinceReferenceDate) }
        }
    }

    /// `memo` keeps let values for one drawing pass; actions run without it, since their commands
    /// change state between reads.
    private func context(now: Double, gesture: SkinValue? = nil, memo: SkinLetMemo? = nil) -> SkinEvaluationContext {
        var values = locals
        var own: [String: SkinValue] = ["hovered": .boolean(hovered), "pressed": .boolean(dragging), "dragging": .boolean(dragging)]
        if case .record(let reading)? = (backdropReading ?? inheritedReading)?.value { own.merge(reading) { _, new in new } }
        if let frame = measuredFrame {
            own.merge(["x": .number(frame.minX), "y": .number(frame.minY), "width": .number(frame.width), "height": .number(frame.height),
                       "midX": .number(frame.midX), "midY": .number(frame.midY)]) { _, new in new }
        }
        values["self"] = .record(own)
        values["parent"] = .record(["width": .number(size.width), "height": .number(size.height)])
        if let gesture { values["gesture"] = gesture }
        var context = SkinEvaluationContext(data: data, locals: values, now: now, live: live)
        context.motionTokens = motionTokens
        context.moves = moves
        context.followers = followers
        context.memo = memo
        return context
    }

    private func render(at now: Double) -> AnyView {
        let context = context(now: now, memo: SkinLetMemo())
        // A hidden node with no transition draws nothing, so the rest of its values are not evaluated.
        let gpuSurface = gpuSurface
        if !gpuSurface, node.hidesWithoutTransition, node.properties["visible"]?.evaluate(context).isTruthy == false {
            return AnyView(EmptyView())
        }
        var values = node.values(context, cache: valueCache)
        for effect in values["effects"]?.listValue ?? [] {
            let name = effect[member: "type"].textValue
            if SkinSceneCompiler.effectNames.contains(name) { values[name] = effect[member: "value"] }
        }
        applyKeyframes(&values, now: now)
        if gpuSurface { values["visible"] = nil; values["opacity"] = nil }
        // With a transition the node stays mounted and animates to its hidden look instead.
        let hidden = values["visible"]?.isTruthy == false
        let transition = values["transition"]
        guard !hidden || transition != nil else { return AnyView(EmptyView()) }
        let frame = values["frame"] ?? .null
        let width = dimension(frame[member: "width"], horizontal: true) ?? dimension(frame[member: "size"], horizontal: true)
        let height = dimension(frame[member: "height"], horizontal: false) ?? dimension(frame[member: "size"], horizontal: false)
        let childSize = CGSize(width: width ?? size.width, height: height ?? size.height)
        let centre = positioned ? self.centre(of: frame, width: width, height: height) : nil
        let forwardsCamera = node.type == "repeat" && values["layout"]?.textValue == "free"
        // A viewport-sized, untransformed repeat shares the camera layer's coordinates.
        // For other repeats, cancel the shared transform at the wrapper and keep its cells local.
        let compensateRepeat = forwardsCamera && camera?.placement == .sharedLayer
            && !sharesCameraCoordinates(centre: centre, childSize: childSize, frame: frame, values: values)
        var repeatCamera = camera
        if compensateRepeat { repeatCamera?.placement = .compensatedSubtree }
        // A node hidden behind a transition stays mounted so it can fade out. Once the fade has
        // had its time it keeps only this shell: a hidden subtree would otherwise still draw and
        // animate every frame at zero opacity. Showing it again brings the content straight back,
        // so the fade-in plays as before. Only a positioned node does this: in a stack its empty
        // shell would give up the space its siblings are laid out around.
        let collapses = positioned && hidden && transition != nil && node.children.allSatisfy(\.mountQuiet)
        var result = collapses && collapsed ? AnyView(EmptyView()) : content(values, size: childSize, now: now, repeatCamera: repeatCamera)
        // Every modifier is one more piece SwiftUI updates on each frame, so the ones a node can
        // never use are left out. The choice is fixed at compile time, so the view keeps its shape.
        func sets(_ names: [String]) -> Bool { node.frameKeys.map { !$0.isDisjoint(with: names) } ?? true }
        if sets(["width", "height", "size", "align"]) {
            result = AnyView(result.frame(width: width, height: height, alignment: alignment(frame[member: "align"].textValue)))
        }
        if sets(["minWidth", "maxWidth", "minHeight", "maxHeight"]) {
            result = AnyView(result.frame(minWidth: dimension(frame[member: "minWidth"], horizontal: true), maxWidth: dimension(frame[member: "maxWidth"], horizontal: true), minHeight: dimension(frame[member: "minHeight"], horizontal: false), maxHeight: dimension(frame[member: "maxHeight"], horizontal: false)))
        }
        if let aspect = frame[member: "aspectRatio"].numberValue, aspect > 0 { result = AnyView(result.aspectRatio(aspect, contentMode: .fit)) }
        if frame[member: "fill"].isTruthy {
            result = AnyView(result.frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        if sets(["padding"]) { result = AnyView(result.padding(frame[member: "padding"].number())) }
        // A GPU layer draws at its `resolution` and adds its grain itself; SwiftUI filters cannot
        // sample its Metal surface.
        let drawsOnGPU = rendersOnGPU(values)
        // `resolution` draws soft content on a smaller surface, scaled with the render quality.
        // Filters and bloom below run on the scaled-up result, so grain keeps full resolution.
        // A shader node sizes its own Metal drawable.
        if !drawsOnGPU, node.type != "shader", let resolution = values["resolution"]?.numberValue, SkinRenderScale.factor(resolution) < 1 {
            let scale = SkinRenderScale.factor(resolution * SkinRenderScale.factor(renderScale))
            result = SkinRenderScale.reduced(result, scale: scale) { $0.drawingGroup() }
        }
        // `group` composites the subtree first, so blend modes inside it mix only with each other.
        if values["group"]?.isTruthy == true { result = AnyView(result.compositingGroup()) }
        // A hidden node that keeps its transition stays mounted; its effects stop with it.
        let dormant = hidden || (values["opacity"]?.number(1) ?? 1) <= 0
        if !drawsOnGPU, let filter = values["filter"] {
            let frozen = !data.timeMoves(playing: components.snapshot.playback.isPlaying)
            result = AnyView(result.modifier(SkinSceneFilters(filters: filter.type == .list ? filter.listValue : [filter], dormant: dormant, frozen: frozen)))
        }
        if !drawsOnGPU, let bloom = values["bloom"] { result = AnyView(result.modifier(SkinSceneBloom(value: bloom, dormant: dormant))) }
        result = SkinNodeStyle.apply(result, values: values, keys: node.styleKeys, reduceTransparency: reduceTransparency)
        if let key = values["key"] {
            result = AnyView(SkinKeyedSwap(key: String(describing: key), transition: transition ?? .null, content: result))
        }
        if values["adaptive"]?.isTruthy == true, let host {
            result = host.adaptive(result, reading: $backdropReading)
        }
        if values["measure"]?.isTruthy == true {
            result = AnyView(result.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SkinSceneSpace.name)) } action: { rect in
                if measuredFrame != rect { measuredFrame = rect }
            })
        }
        if let transition, values["key"] == nil || values["visible"] != nil {
            result = AnyView(result.modifier(SkinVisibilityTransition(value: transition, hidden: hidden)))
        }
        if let mask = node.mask {
            result = AnyView(result.mask(SkinSceneNodeV2View(node: mask, data: data, components: components, size: childSize, locals: locals)))
        }
        if let enter = values["enter"] {
            result = AnyView(result.modifier(SkinEnterTransition(value: enter)))
        }
        let tokens = SkinMotion.tokens(motionTokens, override: values["motion"])
        if let animation = values["animation"] {
            let spec = SkinMotion.spec(animation, tokens: tokens, custom: data.motion.tokens)
            // Per-frame values are already continuous; animating them would chase every frame.
            // The resolution surface's layout cannot follow an animated scale, so it switches at once.
            let animated = values.filter { $0.key != "resolution" && node.properties[$0.key]?.tier != .frame }
            result = AnyView(result.motionAnimation(spec, value: animated))
        }
        if node.tracksPointer {
            result = AnyView(result.onHover { inside in
                hovered = inside; data.pointerMoved()
                perform(inside ? "hoverStart" : "hoverEnd", now: now)
            })
        }
        func mayHave(_ name: String) -> Bool { node.styleKeys?.contains(name) ?? true }
        let keyframed = mayHave("keyframes")
        if keyframed || node.ownDomains.contains(.audio) || node.actions["appear"] != nil || node.actions["disappear"] != nil {
            result = AnyView(result
                .onAppear {
                    animationStart = Date.timeIntervalSinceReferenceDate
                    if node.ownDomains.contains(.audio) { data.audioReaders.insert(readerID) }
                    perform("appear", now: now)
                }
                .onDisappear { data.audioReaders.remove(readerID); perform("disappear", now: now) })
        }
        if keyframed {
            result = AnyView(result.onChange(of: values["keyframes"]?[member: "trigger"]) { _, _ in animationStart = Date.timeIntervalSinceReferenceDate })
        }
        if positioned, mayHave("transition") {
            result = AnyView(result.task(id: collapses) {
                guard collapses else { if collapsed { collapsed = false }; return }
                try? await Task.sleep(for: .seconds(2.5))
                if !Task.isCancelled { collapsed = true }
            })
        }
        if let help = values["help"]?.textValue { result = AnyView(result.help(help)) }
        if let cursor = values["cursor"]?.textValue { result = AnyView(result.background(SkinSceneCursorRegion(name: cursor))) }
        if let controls = values["controls"] { result = AnyView(result.skinProvidesControls(Set(controls.listValue.compactMap { SkinSceneControl(rawValue: $0.textValue) }))) }
        if node.actions["scroll"] != nil {
            result = AnyView(result.background(SkinSceneScrollRegion { x, y, precise in
                perform("scroll", now: Date.timeIntervalSinceReferenceDate,
                        gesture: .record(["deltaX": .number(x), "deltaY": .number(y), "precise": .boolean(precise)]))
            }))
        }
        if node.actions["magnify"] != nil {
            result = AnyView(result.background(SkinSceneMagnifyRegion { magnification in
                perform("magnify", now: Date.timeIntervalSinceReferenceDate, gesture: .record(["magnification": .number(magnification)]))
            }))
        }
        for watch in node.watches {
            result = AnyView(result.onChange(of: watch.value.evaluate(context), initial: watch.initial) { _, _ in
                SkinSceneActionRunner.run(watch.actions, context: self.context(now: Date.timeIntervalSinceReferenceDate), actions: actions)
            })
        }
        let menuKeys = node.actions.keys.filter { $0.hasPrefix("menu") }.sorted()
        if !menuKeys.isEmpty {
            // A snapshot menu from AppKit, so the open menu survives per-frame redraws.
            result = AnyView(result.overlay {
                SkinMenuAnchor(opensOnClick: false) {
                    NSHostingMenu(rootView: ForEach(menuKeys, id: \.self) { key in
                        Button(values["menuTitle" + key.dropFirst(4)]?.textValue ?? "") { perform(key, now: Date.timeIntervalSinceReferenceDate) }
                    })
                }
            })
        }
        // The double tap must be attached first, or the single tap claims every click.
        if node.actions["doubleTap"] != nil { result = AnyView(result.contentShape(Rectangle()).onTapGesture(count: 2) { perform("doubleTap", now: now) }.skinControlRegion()) }
        if node.actions["tap"] != nil { result = AnyView(result.contentShape(Rectangle()).onTapGesture { perform("tap", now: now) }.skinControlRegion()) }
        if node.actions["longPress"] != nil { result = AnyView(result.onLongPressGesture { perform("longPress", now: now) }) }
        if ["drag", "dragStart", "dragEnd"].contains(where: { node.actions[$0] != nil }) {
            result = AnyView(result.gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let gesture = gestureValue(value, size: childSize)
                if !dragging { dragging = true; perform("dragStart", now: Date.timeIntervalSinceReferenceDate, gesture: gesture) }
                perform("drag", now: Date.timeIntervalSinceReferenceDate, gesture: gesture)
            }.onEnded { value in
                dragging = false; perform("dragEnd", now: Date.timeIntervalSinceReferenceDate, gesture: gestureValue(value, size: childSize))
            }).skinControlRegion())
        }
        // Applied after the gestures: a hidden node that keeps its transition stays mounted, and a
        // full-viewport tap layer would otherwise catch every click. The modifiers stay in place
        // either way, so toggling visibility keeps the subtree's identity.
        // A node that can never turn these off leaves the modifiers out.
        let interactive = values["hitTesting"]?.isTruthy != false && !hidden
        let reportsControls = interactive && (values["opacity"]?.number(1) ?? 1) > 0
        if ["hitTesting", "visible", "opacity"].contains(where: mayHave) {
            result = AnyView(result
                .allowsHitTesting(interactive)
                .transformPreference(SkinControlRegionKey.self) { if !interactive { $0 = [] } }
                .transformPreference(SkinSceneControlsKey.self) { if !reportsControls { $0 = [] } })
        }
        if values["motion"] != nil { result = AnyView(result.environment(\.motionTokens, tokens)) }
        // Positioning comes last: `.position` fills the parent layer, so any hit shape,
        // hover or help attached after it would claim the whole layer.
        if let centre {
            if let camera, !forwardsCamera || compensateRepeat {
                let paused = !active || camera.source.isStill(data: data, playing: components.snapshot.playback.isPlaying)
                let depth: Double? = forwardsCamera ? nil : (values["depth"]?.number() ?? 0)
                result = AnyView(result.modifier(SkinCameraFollow(link: camera, centre: centre, depth: depth, size: size, paused: paused)))
            }
            result = AnyView(result.position(centre))
        }
        if let zIndex = values["zIndex"]?.numberValue { result = AnyView(result.zIndex(zIndex)) }
        return result
    }

    private var readerID: String { node.id + ":" + (locals["index"]?.textValue ?? "") }

    private func centre(of frame: SkinValue, width: CGFloat?, height: CGFloat?) -> CGPoint {
        let anchor = frame[member: "anchor"].textValue
        let point = unitPoint(anchor.isEmpty ? "center" : anchor)
        let x = dimension(frame[member: "x"], horizontal: true, signed: true) ?? size.width / 2
        let y = dimension(frame[member: "y"], horizontal: false, signed: true) ?? size.height / 2
        return CGPoint(x: x + (0.5 - point.x) * (width ?? 0), y: y + (0.5 - point.y) * (height ?? 0))
    }

    private static let plainRepeatProperties: Set<String> = ["frame", "layout", "items", "limit", "visible", "hitTesting", "zIndex"]
    private static let plainRepeatFrame: Set<String> = ["x", "y", "width", "height", "size", "anchor", "align"]

    private func sharesCameraCoordinates(centre: CGPoint?, childSize: CGSize, frame: SkinValue, values: [String: SkinValue]) -> Bool {
        guard centre == CGPoint(x: size.width / 2, y: size.height / 2), childSize == size,
              node.mask == nil, Self.plainRepeatProperties.isSuperset(of: values.keys) else { return false }
        if case .record(let fields) = frame { return Self.plainRepeatFrame.isSuperset(of: fields.keys) }
        return frame.type == .null
    }

    private func child(_ node: SkinCompiledSceneNode, size: CGSize, positioned: Bool = false, locals: [String: SkinValue]? = nil, camera: SkinCameraLink? = nil) -> some View {
        SkinSceneNodeV2View(node: node, data: data, components: components, size: size, locals: locals ?? self.locals, positioned: positioned, camera: camera)
    }

    private func content(_ values: [String: SkinValue], size: CGSize, now: Double, repeatCamera: SkinCameraLink?) -> AnyView {
        let spacing = values["spacing"]?.number(12) ?? 12
        let foreground = values["color"]?.colorValue?.swiftUIColor ?? (backdropReading ?? inheritedReading)?.primary
            ?? data.theme["theme.appForeground.primary"]?.colorValue?.swiftUIColor ?? .primary
        switch node.type {
        case "layer" where rendersOnGPU(values):
            return AnyView(SkinGPULayerSurface(inputs: gpuInputs(values, size: size)).frame(width: size.width, height: size.height))
        case "layer":
            let link = cameraLink(now: now)
            let stack = AnyView(ZStack(alignment: .topLeading) { ForEach(node.children) { child($0, size: size, positioned: true, camera: link) } }.frame(width: size.width, height: size.height))
            guard let link else { return stack }
            let paused = !active || link.source.isStill(data: data, playing: components.snapshot.playback.isPlaying)
            return AnyView(stack.modifier(SkinCameraTurn(link: link, size: size, paused: paused)))
        case "row": return AnyView(HStack(spacing: spacing) { ForEach(node.children) { child($0, size: size) } })
        case "column": return AnyView(VStack(spacing: spacing) { ForEach(node.children) { child($0, size: size) } })
        case "stack":
            if values["layout"]?.textValue == "row" { return AnyView(HStack(spacing: spacing) { ForEach(node.children) { child($0, size: size) } }) }
            return AnyView(VStack(spacing: spacing) { ForEach(node.children) { child($0, size: size) } })
        case "grid":
            let columns = max(1, min(64, values["columns"]?.integer(2) ?? 2))
            return AnyView(LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) { ForEach(node.children) { child($0, size: CGSize(width: size.width / Double(columns), height: size.height)) } })
        case "scroll":
            let target = values["scrollTo"]?.numberValue.map { Int($0) }
            return AnyView(SkinSceneFollowingScroll(target: target) {
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(node.children) { SkinSceneNodeV2View(node: $0, data: data, components: components, size: size, locals: locals, lazy: true) }
                }
            }.frame(width: size.width, height: size.height))
        case "repeat":
            let items = Array((values["items"]?.listValue ?? []).prefix(node.repeatLimit))
            // `free`: cells are positioned like a layer's children by their own frame x/y, and
            // follow the enclosing layer's camera with their own depth.
            let free = values["layout"]?.textValue == "free"
            let cells = AnyView(ForEach(items.indices, id: \.self) { index in
                if let template = node.children.first {
                    let scoped = locals.merging(["item": items[index], "index": .number(Double(index)), "count": .number(Double(items.count))]) { _, new in new }
                    // Repeat cells carry their index so a scroll can follow `scrollTo`.
                    child(template, size: size, positioned: free, locals: scoped, camera: free ? repeatCamera : nil).id(index)
                }
            })
            if free { return AnyView(ZStack(alignment: .topLeading) { cells }.frame(width: size.width, height: size.height)) }
            if values["layout"]?.textValue == "row" { return AnyView(HStack(spacing: spacing) { cells }) }
            return lazy ? AnyView(LazyVStack(alignment: .leading, spacing: spacing) { cells }) : AnyView(VStack(alignment: .leading, spacing: spacing) { cells })
        case "switch":
            if let selected = node.children.first(where: { $0.values(context(now: now))["when"]?.isTruthy != false }) { return AnyView(child(selected, size: size)) }
            return AnyView(EmptyView())
        case "glassGroup": return AnyView(GlassEffectContainer(spacing: spacing) { ZStack { ForEach(node.children) { child($0, size: size) } }.environment(\.skinSceneGlassNamespace, glassNamespace) })
        case "component", "lyrics":
            return components.component(node.component ?? "lyrics.native", configuration: .init(values: (values["props"] ?? .record([:])).parameterValue.objectValue ?? [:]), children: AnyView(ZStack { ForEach(node.children) { child($0, size: size) } }))
        case "spacer": return AnyView(Spacer(minLength: values["size"]?.number() ?? 0))
        case "text", "lyricLine":
            let lyricTime = data.clock.lyricsTime(at: now)
            let offset = values["index"]?.integer() ?? 0
            let mode = values["mode"]?.textValue ?? ""
            let field = ["translation", "romanization"].contains(mode) ? mode : "text"
            let value = node.type == "lyricLine" ? data.lyricsTimeline.line(relative: offset, time: lyricTime)[member: field].textValue : values["text"]?.textValue ?? ""
            let fontSize = values["fontSize"]?.number(24) ?? 24
            let font = values["font"]?.textValue ?? ""
            let weight = values["weight"]?.textValue ?? "regular"
            // A family name takes the face nearest `weight`; a PostScript name is used as named.
            let resolved = font.isEmpty ? nil : SkinFontResolver.font(font, size: fontSize, weight: weight)
            var typeface = resolved.map { Font($0 as CTFont) }
                ?? Font.system(size: fontSize, weight: skinFontWeight(weight), design: skinFontDesign(values["design"]?.textValue ?? ""))
            if values["italic"]?.isTruthy == true { typeface = typeface.italic() }
            let tracking = values["tracking"]?.number() ?? 0
            let aligned = textAlignment(values["alignment"]?.textValue ?? "")
            func layout(_ text: Text) -> some View {
                text.font(typeface).tracking(tracking)
                    .multilineTextAlignment(aligned)
                    .lineSpacing(values["lineSpacing"]?.number() ?? 0)
                    .lineLimit(values["lineLimit"].map { max(1, $0.integer(1)) })
                    .minimumScaleFactor((values["minScale"]?.number(1) ?? 1).clamped01)
            }
            let lineIndex = data.lyricsTimeline.currentIndex(at: lyricTime) + offset
            var glyphs = glyphStyle(values, text: value, lineIndex: node.type == "lyricLine" ? lineIndex : nil, lyricTime: lyricTime, now: now, fontSize: fontSize)
            // `subpixel`: plain text fills its glyph outlines, so it moves and zooms smoothly.
            if node.type == "text", values["subpixel"]?.isTruthy == true {
                var style = glyphs ?? SkinGlyphStyle(padding: 1)
                style.vector = SkinGlyphVector(font: font, weight: weight, size: fontSize, color: foreground,
                                               characters: value.filter { !$0.isNewline }.map(String.init))
                glyphs = style
            }
            if node.type == "lyricLine", let highlight = values["highlightColor"]?.colorValue {
                // Word by word: each word moves toward `highlightColor` as it is sung, so wrapped lines stay right.
                if values["highlightStyle"]?.textValue == "word", field == "text",
                   let words = data.lyricsTimeline.wordProgress(index: lineIndex, time: lyricTime) {
                    let base = values["color"]?.colorValue ?? (backdropReading ?? inheritedReading).map { OKLCHColor($0.primaryColor) }
                        ?? data.theme["theme.appForeground.primary"]?.colorValue ?? .white
                    let line = words.reduce(Text("")) { text, word in
                        Text("\(text)\(Text(word.text).foregroundStyle(base.mixed(with: highlight, amount: word.progress).swiftUIColor))")
                    }
                    return AnyView(SkinGlyphLayer(style: glyphs, alignment: aligned, content: layout(line)))
                }
                // A sweep: the sung part takes `highlightColor`, left to right.
                let fraction = data.lyricsTimeline.sungFraction(index: lineIndex, time: lyricTime)
                return AnyView(SkinGlyphLayer(style: glyphs, alignment: aligned, content: layout(Text(value)).foregroundStyle(foreground).overlay {
                    layout(Text(value)).foregroundStyle(highlight.swiftUIColor).mask(alignment: .leading) {
                        GeometryReader { proxy in Rectangle().frame(width: proxy.size.width * fraction) }
                    }
                }))
            }
            return AnyView(SkinGlyphLayer(style: glyphs, alignment: aligned, content: layout(Text(value)).foregroundStyle(foreground)))
        case "symbol": return AnyView(Image(systemName: values["name"]?.textValue ?? "circle").resizable().scaledToFit().foregroundStyle(foreground))
        case "artwork":
            if let id = values["track"]?.textValue, let trackID = UUID(uuidString: id) {
                return host?.trackArtwork(id: trackID, fills: values["fit"]?.textValue == "fill") ?? AnyView(Color.clear)
            }
            return components.component("artwork.basic", configuration: .init(values: values.mapValues(\.parameterValue)))
        case "image": return AnyView(SkinPackageImage(path: values["path"]?.textValue ?? "", fit: values["fit"]?.textValue ?? "fit"))
        case "video": return AnyView(SkinPackageVideo(path: values["path"]?.textValue ?? "", active: active, isPlaying: components.snapshot.playback.isPlaying))
        case "shape":
            let shape = SkinSceneShape(kind: values["shape"]?.textValue ?? "rectangle", points: values["points"]?.textValue ?? "")
            let trimmed = shape.trim(from: (values["trimStart"]?.number() ?? 0).clamped01, to: (values["trimEnd"]?.number(1) ?? 1).clamped01)
            // `stroke` draws the outline; the shape is filled as well only when it names a `color`.
            guard let stroke = values["stroke"] else { return AnyView(trimmed.fill(foreground)) }
            let style = StrokeStyle(lineWidth: max(0, stroke.numberValue ?? stroke[member: "width"].number(1)),
                                    lineCap: stroke[member: "cap"].textValue == "round" ? .round : stroke[member: "cap"].textValue == "square" ? .square : .butt,
                                    lineJoin: stroke[member: "join"].textValue == "round" ? .round : stroke[member: "join"].textValue == "bevel" ? .bevel : .miter,
                                    dash: stroke[member: "dash"].listValue.map { CGFloat(max(0, $0.number())) })
            let line = trimmed.stroke(stroke[member: "color"].colorValue?.swiftUIColor ?? foreground, style: style)
            return values["color"] == nil ? AnyView(line) : AnyView(shape.fill(foreground).overlay(line))
        case "fog":
            let colors = (values["colors"]?.listValue ?? []).compactMap { $0.colorValue?.swiftUIColor }
            let moves = configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full
            return AnyView(SkinSceneFog(low: colors.count > 1 ? colors[0] : .clear, high: colors.last ?? foreground,
                                        time: moves ? data.time(at: now).truncatingRemainder(dividingBy: 3600) : 0,
                                        feature: values["size"]?.number(260) ?? 260, speed: values["speed"]?.number(0.3) ?? 0.3,
                                        warp: values["warp"]?.number(1.5) ?? 1.5, gain: values["gain"]?.number(1.2) ?? 1.2,
                                        scroll: CGPoint(x: values["scrollX"]?.number() ?? 0, y: values["scrollY"]?.number() ?? 0)))
        case "gradient":
            let gradient = skinGradient(values)
            switch values["mode"]?.textValue ?? "" {
            case "radial":
                let radius = max(1, (values["radius"]?.number(0.5) ?? 0.5) * max(size.width, size.height))
                return AnyView(RadialGradient(gradient: gradient, center: unitPoint(values["start"]?.textValue ?? "center"), startRadius: 0, endRadius: radius))
            case "elliptical":
                // Stretches to the frame, so a glow in a wide frame ends inside it instead of at its edges.
                return AnyView(EllipticalGradient(gradient: gradient, center: unitPoint(values["start"]?.textValue ?? "center"),
                                                  startRadiusFraction: 0, endRadiusFraction: values["radius"]?.number(0.5) ?? 0.5))
            case "angular":
                return AnyView(AngularGradient(gradient: gradient, center: unitPoint(values["start"]?.textValue ?? "center")))
            case "light":
                let first = (values["stops"]?.listValue ?? []).first?[member: "color"].colorValue
                    ?? (values["colors"]?.listValue ?? []).first?.colorValue
                return AnyView(SkinSceneLight(color: first?.swiftUIColor ?? .clear, core: values["radius"]?.number(SkinLightGradient.core) ?? SkinLightGradient.core,
                                              centre: unitPoint(values["start"]?.textValue ?? "center")))
            default:
                return AnyView(LinearGradient(gradient: gradient, startPoint: unitPoint(values["start"]?.textValue ?? "topLeading"), endPoint: unitPoint(values["end"]?.textValue ?? "bottomTrailing")))
            }
        case "spectrum", "waveform", "meter": return AnyView(SkinSceneAudioCanvas(kind: node.type, data: data, values: values, now: now, color: components.snapshot.theme.accentColor))
        case "particles": return AnyView(SkinSceneParticles(data: data, values: values, now: now, reduceMotion: reduceMotion))
        case "shader": return AnyView(SkinSceneShader(values: values, data: data, snapshot: components.snapshot, now: now))
        case "comet": return AnyView(SkinSceneComet(values: values).frame(width: size.width, height: size.height))
        default: return AnyView(EmptyView())
        }
    }

    /// Evaluates `glyphMotion` once per glyph. `glyph` carries index, count, char, word, line,
    /// start and end (seconds), age (seconds since the glyph's start), progress (0…1 through it),
    /// lineAge and fontSize. Lyric lines time glyphs by the sung words; plain text from when it last changed.
    private func glyphStyle(_ values: [String: SkinValue], text: String, lineIndex: Int?, lyricTime: Double, now: Double, fontSize: Double) -> SkinGlyphStyle? {
        let fallback = values["color"]?.colorValue ?? data.theme["theme.appForeground.primary"]?.colorValue
        let outline = SkinGlyphOutline(values["outline"], fallback: fallback)
        let extrude = SkinGlyphExtrude(values["extrude"], fallback: nil)
        let glow = SkinGlyphGlow(values["glow"], fallback: fallback)
        // The glow's reach counts from the first frame, so a glyph lighting up later never
        // widens the renderer's padding (a padding change moves glyphs sideways).
        var style = SkinGlyphStyle(outline: outline, extrude: extrude, glow: glow,
                                   padding: (outline?.width ?? 0) + (extrude?.depth ?? 0) + (glow?.reach ?? 0) + 1)
        guard let motion = node.properties["glyphMotion"] else { return outline == nil && extrude == nil ? nil : style }
        let characters = Array(text.filter { !$0.isNewline })
        guard configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full,
              !characters.isEmpty, characters.count <= 512 else { return style }
        var times = lineIndex.map { data.lyricsTimeline.glyphTimes(index: $0, text: String(characters)) } ?? []
        let clock: Double
        if lineIndex != nil {
            clock = lyricTime
        } else {
            clock = now
            let start = glyphClock.start(for: text + "\u{1F}" + (values["key"]?.textValue ?? ""), now: now)
            times = Array(repeating: (start: start, end: start, word: 0), count: characters.count)
        }
        if times.count != characters.count { times = Array(repeating: (start: clock, end: clock, word: 0), count: characters.count) }
        let lineStart = times.first?.start ?? clock
        var scope = context(now: now, memo: SkinLetMemo())
        let glyphMemo = SkinLetMemo()
        scope.glyphMemo = glyphMemo
        var reach = 0.0, growth = 0.0
        style.transforms.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            let time = times[index]
            scope.followSlot = index + 1
            glyphMemo.values.removeAll(keepingCapacity: true)
            scope.locals["glyph"] = .record([
                "index": .number(Double(index)), "count": .number(Double(characters.count)), "char": .text(String(character)),
                "word": .number(Double(time.word)), "line": .number(Double(lineIndex ?? 0)),
                "start": .number(time.start), "end": .number(time.end), "age": .number(clock - time.start),
                "progress": .number(time.end > time.start ? ((clock - time.start) / (time.end - time.start)).clamped01 : (clock >= time.start ? 1 : 0)),
                "lineAge": .number(clock - lineStart), "fontSize": .number(fontSize),
            ])
            let transform = SkinGlyphTransform(motion.evaluate(scope))
            // An entering glyph is both offset and blurred, so its blur reaches past the offset.
            // Ink that runs past the padding meets the edge of the text's layer and smears into
            // thin lines along the entry direction.
            reach = max(reach, abs(transform.x) + abs(transform.split) + abs(transform.smearX) / 2 + transform.blur * 3,
                        abs(transform.y) + abs(transform.smearY) / 2 + transform.blur * 3)
            growth = max(growth, transform.scale - 1, abs(transform.rotation) > 0.5 ? 0.5 : 0)
            style.transforms.append(transform)
        }
        // Heavy and italic faces ink past their advance; leave room so they are not cut.
        let wanted = style.padding + reach + growth * fontSize + fontSize * 0.12
        // A renderer's display padding that changes under a text moves its glyphs sideways, so a
        // padding that shrank as an entrance settled made the glyph jump half an em. It is kept per
        // text and only grows; the first frame of an entrance usually reaches the most it needs.
        style.padding = glyphPadding.stable(for: text + "\u{1F}" + String(fontSize), wanted: max(wanted, style.padding + fontSize * 0.6))
        return style
    }

    /// A layer's camera for its positioned children. A per-frame camera is evaluated once per
    /// display frame by whichever child asks first; the layer itself stays off the timeline.
    private func cameraLink(now: Double) -> SkinCameraLink? {
        guard let property = node.camera else { return nil }
        let moves = configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full
        guard property.tier == .frame, moves else {
            return SkinCameraLink(source: cameraSource, steady: SkinSceneCamera(property.evaluate(context(now: now))))
        }
        let placement: SkinCameraLink.Placement
        if case .object(let fields) = property, ["rasterize", "sharedMotion"].contains(where: { name in
            guard case .expression(let flag)? = fields[name] else { return false }
            return flag.constantValue?.isTruthy == true
        }) {
            placement = .sharedLayer
        } else {
            placement = .local
        }
        let view = self
        cameraSource.inputs = node.cameraInputs
        cameraSource.followers = followers
        cameraSource.evaluate = { now in SkinSceneCamera(property.evaluate(view.context(now: now))) }
        return SkinCameraLink(source: cameraSource, steady: nil, placement: placement)
    }

    /// A `render: "gpu"` layer, when Metal is there to draw it; otherwise its children draw as views.
    private func rendersOnGPU(_ values: [String: SkinValue]) -> Bool {
        node.type == "layer" && values["render"]?.textValue == "gpu" && SkinGPURenderer.shared != nil
    }

    private func gpuInputs(_ values: [String: SkinValue], size: CGSize) -> SkinGPULayerInputs {
        var filters: [SkinValue] = []
        if let filter = values["filter"] { filters = filter.type == .list ? filter.listValue : [filter] }
        var grain = 0.0
        var grainRate = SkinGrain.defaultRate
        if let entry = filters.first(where: { $0[member: "type"].textValue == "grain" }) {
            grain = entry[member: "amount"].number(0.08)
            grainRate = entry[member: "rate"].number(SkinGrain.defaultRate)
        }
        let lens = filters.first(where: { $0[member: "type"].textValue == "fov" }).map(SkinGPULens.init)
        let bokeh = filters.first(where: { $0[member: "type"].textValue == "bokeh" }).flatMap(SkinGPUBokeh.init)
        let lut = filters.first(where: { $0[member: "type"].textValue == "lut" })
            .flatMap { SkinColorLUTFilter($0, root: resources) }
        let view = self, node = node, followers = followers, data = data
        var camera: (@MainActor (Double) -> SkinSceneCamera)?
        if let property = node.camera {
            camera = { now in SkinSceneCamera(property.evaluate(view.context(now: now))) }
        }
        return SkinGPULayerInputs(
            node: node, data: data, size: size, locals: locals, live: live, motionTokens: motionTokens, moves: moves,
            playing: components.snapshot.playback.isPlaying, active: active, renderScale: renderScale,
            resolution: values["resolution"]?.numberValue ?? 1, grain: grain, grainRate: grainRate, lens: lens, bokeh: bokeh, lut: lut, camera: camera,
            cameraStill: { playing, timeMoves in
                node.camera == nil || node.cameraInputs.isStill(playing: playing, timeMoves: timeMoves, following: followers.isMoving)
            },
            metricsID: metricsID)
    }

    private func perform(_ event: String, now: Double, gesture: SkinValue? = nil) {
        SkinSceneActionRunner.run(node.actions[event] ?? [], context: context(now: Date.timeIntervalSinceReferenceDate, gesture: gesture), actions: actions)
    }

    private func gestureValue(_ value: DragGesture.Value, size: CGSize) -> SkinValue {
        .record(["x": .number(value.location.x), "y": .number(value.location.y),
                 "fractionX": .number((value.location.x / max(1, size.width)).clamped01), "fractionY": .number((value.location.y / max(1, size.height)).clamped01),
                 "translationX": .number(value.translation.width), "translationY": .number(value.translation.height)])
    }

    /// Sizes stay non-negative; `signed` positions may lie left of or above the layer.
    private func dimension(_ value: SkinValue, horizontal: Bool, signed: Bool = false) -> CGFloat? {
        let floor = signed ? -Double.infinity : 0
        if let number = value.numberValue { return CGFloat(max(floor, number)) }
        let text = value.textValue
        let viewport = live?.size ?? data.viewportSize
        let units: [(String, Double)] = [("vmin", min(viewport.width, viewport.height)), ("vmax", max(viewport.width, viewport.height)), ("vw", viewport.width), ("vh", viewport.height), ("%", horizontal ? size.width : size.height)]
        for (suffix, base) in units where text.hasSuffix(suffix) {
            if let number = Double(text.dropLast(suffix.count)) { return CGFloat(max(floor, base * number / 100)) }
        }
        return nil
    }

    private func applyKeyframes(_ values: inout [String: SkinValue], now: Double) {
        guard configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full,
              let keyframes = values["keyframes"] else { return }
        let duration = max(0.001, keyframes[member: "duration"].number(1))
        let elapsed = max(0, now - animationStart)
        let fraction = keyframes[member: "repeat"].isTruthy ? elapsed.truncatingRemainder(dividingBy: duration) / duration : min(1, elapsed / duration)
        guard case .record(let tracks) = keyframes[member: "tracks"] else { return }
        for (key, track) in tracks {
            let points = track.listValue
            guard !points.isEmpty else { continue }
            let position = fraction * Double(max(0, points.count - 1))
            let first = min(points.count - 1, Int(position)), second = min(points.count - 1, first + 1)
            let a = points[first].number(), b = points[second].number()
            values[key] = .number(a + (b - a) * (position - Double(first)))
        }
    }
}

func unitPoint(_ name: String) -> UnitPoint {
    switch name {
    case "topLeading": .topLeading
    case "top": .top
    case "topTrailing": .topTrailing
    case "leading": .leading
    case "trailing": .trailing
    case "bottomLeading": .bottomLeading
    case "bottom": .bottom
    case "bottomTrailing": .bottomTrailing
    default: .center
    }
}

private func alignment(_ name: String) -> Alignment {
    switch name {
    case "topLeading": .topLeading
    case "top": .top
    case "topTrailing": .topTrailing
    case "leading": .leading
    case "trailing": .trailing
    case "bottomLeading": .bottomLeading
    case "bottom": .bottom
    case "bottomTrailing": .bottomTrailing
    default: .center
    }
}

private func textAlignment(_ name: String) -> TextAlignment {
    switch name {
    case "center": .center
    case "trailing": .trailing
    default: .leading
    }
}

/// A scroll region that brings the repeat cell at `target` to its centre when the value changes.
private struct SkinSceneFollowingScroll<Content: View>: View {
    let target: Int?
    @ViewBuilder let content: () -> Content
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content() }
                .onChange(of: target, initial: true) { _, next in
                    guard let next, next >= 0 else { return }
                    let animation = motionPolicy.resolvedAnimation(for: motionTokens[.layout], accessibilityReduceMotion: accessibilityReduceMotion)
                    withAnimation(animation) { proxy.scrollTo(next, anchor: .center) }
                }
        }
    }
}

/// `stops` ({color, at}) when given, otherwise `colors` spaced evenly.
private func skinGradient(_ values: [String: SkinValue]) -> Gradient {
    let stops = (values["stops"]?.listValue ?? []).compactMap { stop -> Gradient.Stop? in
        guard let color = stop[member: "color"].colorValue else { return nil }
        return .init(color: color.swiftUIColor, location: stop[member: "at"].number().clamped01)
    }
    if !stops.isEmpty { return Gradient(stops: stops.sorted { $0.location < $1.location }) }
    return Gradient(colors: (values["colors"]?.listValue ?? []).compactMap { $0.colorValue?.swiftUIColor })
}

/// Size-derived viewport and host facts, computed with the size SwiftUI is laying out. The feeds
/// write the same facts after the update, which alone would leave units one size behind.
struct SkinLiveViewport: Equatable {
    let size: CGSize
    let facts: [String: SkinValue]

    init(size: CGSize, surface: SkinSurface, lyricsVisible: Bool, presentation: SkinPresentationPolicy) {
        self.size = size
        let layout = SkinHostLayout.frames(size: size, surface: surface, lyricsVisible: lyricsVisible, presentation: presentation)
        facts = [
            "viewport.width": .number(size.width), "viewport.height": .number(size.height),
            "viewport.w": .number(size.width), "viewport.h": .number(size.height),
            "viewport.min": .number(min(size.width, size.height)), "viewport.max": .number(max(size.width, size.height)),
            "viewport.aspect": .number(size.width / max(1, size.height)),
            "host.layout": SkinHostLayout.value(layout),
        ]
    }
}

extension EnvironmentValues {
    @Entry var skinSceneLiveViewport: SkinLiveViewport?
}

private func skinFontDesign(_ name: String) -> Font.Design {
    switch name {
    case "rounded": .rounded
    case "serif": .serif
    case "monospaced": .monospaced
    default: .default
    }
}

private func skinFontWeight(_ name: String) -> Font.Weight {
    switch name {
    case "ultralight": .ultraLight
    case "thin": .thin
    case "light": .light
    case "medium": .medium
    case "semibold": .semibold
    case "bold": .bold
    case "heavy": .heavy
    case "black": .black
    default: .regular
    }
}
