import AppKit
import SwiftUI

/// The composition of a v2 scene as a few flat blocks, for the skin selection card.
///
/// It never draws the scene. The compiled program is walked once at a fixed moment with sample
/// data and only the main subjects are kept: one artwork, up to three lyric lines, up to two
/// lines of type and one visualizer. Backdrops, controls, symbols, decoration and anything too
/// small to read on a card are left out, so the card shows where things sit rather than how
/// they look.
struct SkinSceneSilhouette {
    enum Kind { case artwork, lyric, text, visualizer }

    struct Block {
        var kind: Kind
        var rect: CGRect
        var rotation: Double = 0
        var cornerRadius: CGFloat = 0
        var isCircle = false
        /// 0…1; the current lyric line and large type read brightest.
        var emphasis: Double = 0.5
    }

    let viewport: CGSize
    let blocks: [Block]

    var hasContent: Bool { !blocks.isEmpty }

    /// Keeps the main subjects only, largest first within each kind.
    static func essentials(of blocks: [Block], viewport: CGSize) -> [Block] {
        // Type thinner than this is a hairline on a card.
        let minimumBar = viewport.width * 0.009
        let minimumSide = viewport.width * 0.05
        func area(_ block: Block) -> CGFloat { block.rect.width * block.rect.height }

        let artwork = blocks.filter { $0.kind == .artwork && min($0.rect.width, $0.rect.height) >= minimumSide }
            .max { area($0) < area($1) }
        let visualizer = blocks.filter { $0.kind == .visualizer && $0.rect.width >= minimumSide * 2 }
            .max { area($0) < area($1) }

        // The current line and the two nearest it.
        let lyrics = blocks.filter { $0.kind == .lyric && $0.rect.height >= minimumBar }
        var keptLyrics: [Block] = []
        if let current = lyrics.max(by: { $0.emphasis < $1.emphasis }) {
            keptLyrics = Array(lyrics.sorted { abs($0.rect.midY - current.rect.midY) < abs($1.rect.midY - current.rect.midY) }.prefix(3))
        }

        let text = blocks.filter { $0.kind == .text && $0.rect.height >= minimumBar && $0.rect.width >= minimumSide }
            .sorted { $0.rect.height == $1.rect.height ? $0.rect.width > $1.rect.width : $0.rect.height > $1.rect.height }
            .prefix(2)

        return [artwork, visualizer].compactMap { $0 } + keptLyrics + text
    }

    /// The logical size each surface is sampled at: a wide fullscreen and the window area above
    /// the fixed playback bar.
    static func viewport(for surface: SkinSurface) -> CGSize {
        surface == .fullscreen ? CGSize(width: 1440, height: 900) : CGSize(width: 1100, height: 620)
    }
}

/// Walks a compiled program with sample data; see `SkinSceneSilhouette`.
@MainActor
struct SkinSceneSilhouetteExtractor {
    private static let sampleLyric = "此刻唱到的这一行歌词"
    private static let lyricDomains: Set<SkinDataDomain> = [.lyrics, .lyricsTimeline]
    private static let maximumBlocks = 160
    private static let maximumDepth = 40

    private let data = SkinSceneData()
    private let viewport: CGSize
    private let live: SkinLiveViewport
    private var blocks: [SkinSceneSilhouette.Block] = []

    static func silhouette(of program: SkinSceneProgram, skin: any NowPlayingSkin, surface: SkinSurface) -> SkinSceneSilhouette {
        var extractor = Self(program: program, skin: skin, surface: surface)
        let bounds = CGRect(origin: .zero, size: extractor.viewport)
        extractor.place(program.root, in: bounds, positioned: false, locals: [:], depth: 0)
        return SkinSceneSilhouette(viewport: extractor.viewport,
                                   blocks: SkinSceneSilhouette.essentials(of: extractor.blocks, viewport: extractor.viewport))
    }

    private init(program: SkinSceneProgram, skin: any NowPlayingSkin, surface: SkinSurface) {
        viewport = SkinSceneSilhouette.viewport(for: surface)
        live = SkinLiveViewport(size: viewport, surface: surface, lyricsVisible: true, presentation: skin.descriptor.presentation)
        data.set(.viewport, live.facts.merging([
            "viewport.surface": .text(surface.rawValue), "viewport.isFullscreen": .boolean(surface == .fullscreen),
            "viewport.isDark": .boolean(true), "viewport.colorScheme": .text("dark"),
        ]) { _, new in new })
        data.set(.track, [
            "track.hasTrack": .boolean(true), "track.title": .text("夜航"), "track.artist": .text("样例歌手"),
            "track.album": .text("样例专辑"),
        ])
        data.set(.playback, [
            "playback.isPlaying": .boolean(true), "playback.progress": .number(0.35),
            "playback.duration": .number(240), "playback.position": .number(84), "playback.volume": .number(0.7),
        ])
        data.set(.lyrics, ["lyrics.available": .boolean(true), "lyrics.availability": .text("available")])
        data.set(.params, Dictionary(skin.parameterDefinitions.map { ($0.id, SkinValue($0.defaultValue)) }) { first, _ in first })
        data.initialState = program.state
        data.resetState(program.state)
    }

    // MARK: Walk

    private mutating func place(_ node: SkinCompiledSceneNode, in parent: CGRect, positioned: Bool,
                                locals: [String: SkinValue], depth: Int) {
        guard depth < Self.maximumDepth, blocks.count < Self.maximumBlocks else { return }
        let values = evaluate(node, size: parent.size, locals: locals)
        guard values["visible"]?.isTruthy != false else { return }
        let rect = frame(of: node, values: values, in: parent, positioned: positioned)
        let rotation = values["rotation"]?.numberValue ?? 0

        if let component = node.component ?? (node.type == "lyrics" ? "lyrics.native" : nil) {
            placeComponent(component, node: node, rect: rect, locals: locals, depth: depth)
            return
        }
        // Buttons and other small tappable things stay off the card.
        if !(node.actions["tap"] ?? []).isEmpty, node.type != "layer", rect.width < 160, rect.height < 160 { return }

        switch node.type {
        case "layer":
            for child in node.children { place(child, in: rect, positioned: true, locals: locals, depth: depth + 1) }
        case "row", "column", "stack", "scroll", "grid", "glassGroup":
            stack(node, values: values, in: rect, locals: locals, depth: depth)
        case "repeat":
            placeRepeat(node, values: values, in: rect, locals: locals, depth: depth)
        case "switch":
            if let selected = node.children.first(where: { evaluate($0, size: rect.size, locals: locals)["when"]?.isTruthy != false }) {
                place(selected, in: rect, positioned: positioned, locals: locals, depth: depth + 1)
            }
        case "text", "lyricLine":
            placeText(node, values: values, in: rect, rotation: rotation)
        case "artwork":
            let radius = values["cornerRadius"]?.numberValue ?? 0
            add(.artwork, rect, rotation: rotation, cornerRadius: CGFloat(radius),
                isCircle: values["shape"]?.textValue == "circle" || CGFloat(radius) * 2 >= min(rect.width, rect.height) * 0.98)
        case "spectrum", "waveform", "meter":
            add(.visualizer, rect, rotation: rotation)
        default:
            // Backdrops, shapes, symbols and effects are left out.
            break
        }
    }

    private mutating func placeComponent(_ name: String, node: SkinCompiledSceneNode, rect: CGRect,
                                         locals: [String: SkinValue], depth: Int) {
        func has(_ part: String) -> Bool { name.contains(part) }
        if name.hasPrefix("lyrics.") || (name.hasPrefix("builtin.") && has("lyrics")) {
            addLyricLines(in: rect, alignment: .leading)
        } else if name.hasPrefix("artwork.") || name.hasPrefix("cassette.") || name.hasPrefix("transition.")
                    || (name.hasPrefix("builtin.") && has("artwork")) {
            let side = min(rect.width, rect.height)
            let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            add(.artwork, square, cornerRadius: side * 0.06, isCircle: has("rotatingDisc"))
        } else if name.hasPrefix("visualizer.") {
            add(.visualizer, rect)
        } else if name.hasPrefix("control.") {
            return
        } else if name.hasPrefix("text.") {
            addTextLines(in: rect, fontSize: 28, lineCount: 1, kind: .text, emphasis: 0.55, alignment: .leading)
        } else if name.hasPrefix("template.") {
            addTemplate(in: rect)
        }
        // Behaviour components and the like wrap their children in place.
        for child in node.children { place(child, in: rect, positioned: false, locals: locals, depth: depth + 1) }
    }

    /// Children share the main axis by their own sizes; the rest is split among flexible ones.
    private mutating func stack(_ node: SkinCompiledSceneNode, values: [String: SkinValue], in rect: CGRect,
                                locals: [String: SkinValue], depth: Int) {
        let spacing = CGFloat(values["spacing"]?.number(12) ?? 12)
        let horizontal = node.type == "row" || (node.type == "stack" && values["layout"]?.textValue == "row")
        if node.type == "glassGroup" || (node.type == "grid") {
            for child in node.children { place(child, in: rect, positioned: false, locals: locals, depth: depth + 1) }
            return
        }
        let children = node.children.map { ($0, evaluate($0, size: rect.size, locals: locals)) }
            .filter { $0.0.type == "spacer" || $0.1["visible"]?.isTruthy != false }
        let sizes = children.map { intrinsicSize($0.0, values: $0.1, in: rect.size) }
        let fixed = sizes.reduce(CGFloat(0)) { $0 + ((horizontal ? $1.width : $1.height) ?? 0) }
        let flexibleCount = CGFloat(sizes.filter { (horizontal ? $0.width : $0.height) == nil }.count)
        let gaps = spacing * CGFloat(max(0, children.count - 1))
        let mainLength = horizontal ? rect.width : rect.height
        let share = flexibleCount > 0 ? max(0, (mainLength - fixed - gaps) / flexibleCount) : 0
        let total = flexibleCount > 0 ? mainLength : min(mainLength, fixed + gaps)
        var cursor = (horizontal ? rect.minX : rect.minY) + (mainLength - total) / 2
        for ((child, _), size) in zip(children, sizes) {
            let main = (horizontal ? size.width : size.height) ?? share
            let crossLimit = horizontal ? rect.height : rect.width
            let cross = min(crossLimit, (horizontal ? size.height : size.width) ?? crossLimit)
            let slot = horizontal
                ? CGRect(x: cursor, y: rect.midY - cross / 2, width: main, height: cross)
                : CGRect(x: rect.midX - cross / 2, y: cursor, width: cross, height: main)
            if child.type != "spacer" { place(child, in: slot, positioned: false, locals: locals, depth: depth + 1) }
            cursor += main + spacing
        }
    }

    private mutating func placeRepeat(_ node: SkinCompiledSceneNode, values: [String: SkinValue], in rect: CGRect,
                                      locals: [String: SkinValue], depth: Int) {
        let items = Array((values["items"]?.listValue ?? []).prefix(min(node.repeatLimit, 6)))
        guard let template = node.children.first else { return }
        if items.isEmpty {
            // Lyrics are not loaded for the sample; a repeat over them stands for a block of lines.
            if !node.domains.isDisjoint(with: Self.lyricDomains) { addLyricLines(in: rect, alignment: .center) }
            return
        }
        let free = values["layout"]?.textValue == "free"
        let row = values["layout"]?.textValue == "row"
        let spacing = CGFloat(values["spacing"]?.number(12) ?? 12)
        var cursor = row ? rect.minX : rect.minY
        for index in items.indices {
            let scoped = locals.merging(["item": items[index], "index": .number(Double(index)), "count": .number(Double(items.count))]) { _, new in new }
            if free {
                place(template, in: rect, positioned: true, locals: scoped, depth: depth + 1)
                continue
            }
            let size = intrinsicSize(template, values: evaluate(template, size: rect.size, locals: scoped), in: rect.size)
            let length = (row ? size.width : size.height) ?? (row ? rect.width : rect.height) / CGFloat(items.count)
            let slot = row
                ? CGRect(x: cursor, y: rect.minY, width: length, height: rect.height)
                : CGRect(x: rect.minX, y: cursor, width: rect.width, height: length)
            place(template, in: slot, positioned: false, locals: scoped, depth: depth + 1)
            cursor += length + spacing
        }
    }

    private mutating func placeText(_ node: SkinCompiledSceneNode, values: [String: SkinValue], in rect: CGRect, rotation: Double) {
        let readsLyrics = node.type == "lyricLine" || !node.ownDomains.isDisjoint(with: Self.lyricDomains)
        var text = node.type == "lyricLine" ? "" : values["text"]?.textValue ?? ""
        if text.isEmpty, readsLyrics { text = Self.sampleLyric }
        guard !text.isEmpty else { return }
        let fontSize = CGFloat(values["fontSize"]?.number(24) ?? 24)
        let lines = min(3, max(1, values["lineLimit"]?.integer(3) ?? 3))
        let offset = values["index"]?.integer() ?? 0
        let emphasis = readsLyrics ? (offset == 0 ? 1 : 0.4) : min(1, 0.35 + Double(fontSize) / 80)
        let width = Self.textWidth(text, fontSize: fontSize)
        let lineCount = min(lines, max(1, Int(ceil(width / max(1, rect.width)))))
        let alignment = values["alignment"]?.textValue ?? ""
        addTextLines(in: rect, fontSize: fontSize, lineCount: lineCount, kind: readsLyrics ? .lyric : .text,
                     emphasis: emphasis, alignment: alignment == "leading" ? .leading : alignment == "trailing" ? .trailing : .center,
                     textWidth: min(width, rect.width), rotation: rotation)
    }

    // MARK: Blocks

    private mutating func add(_ kind: SkinSceneSilhouette.Kind, _ rect: CGRect, rotation: Double = 0,
                              cornerRadius: CGFloat = 0, isCircle: Bool = false, emphasis: Double = 0.5) {
        guard rect.width >= 1, rect.height >= 1, rect.intersects(CGRect(origin: .zero, size: viewport)) else { return }
        blocks.append(.init(kind: kind, rect: rect, rotation: rotation, cornerRadius: cornerRadius, isCircle: isCircle, emphasis: emphasis))
    }

    private enum Align { case leading, center, trailing }

    private mutating func addTextLines(in rect: CGRect, fontSize: CGFloat, lineCount: Int, kind: SkinSceneSilhouette.Kind,
                                       emphasis: Double, alignment: Align, textWidth: CGFloat? = nil, rotation: Double = 0) {
        let lineHeight = fontSize * 1.3
        let barHeight = max(2, fontSize * 0.5)
        let total = lineHeight * CGFloat(lineCount)
        let top = rect.midY - total / 2
        let full = textWidth ?? rect.width * 0.6
        for line in 0..<lineCount {
            let isLast = line == lineCount - 1 && lineCount > 1
            let width = isLast ? full * 0.6 : full
            let x: CGFloat
            switch alignment {
            case .leading: x = rect.minX
            case .trailing: x = rect.maxX - width
            case .center: x = rect.midX - width / 2
            }
            let y = top + lineHeight * CGFloat(line) + (lineHeight - barHeight) / 2
            add(kind, CGRect(x: x, y: y, width: width, height: barHeight), rotation: rotation, cornerRadius: barHeight / 2, emphasis: emphasis)
        }
    }

    /// Five lines of varied length, the second one current.
    private mutating func addLyricLines(in rect: CGRect, alignment: Align) {
        let widths: [CGFloat] = [0.62, 0.86, 0.5, 0.74, 0.56]
        let lineHeight = min(rect.height / CGFloat(widths.count + 1), viewport.height * 0.075)
        let barHeight = lineHeight * 0.42
        let top = rect.midY - lineHeight * CGFloat(widths.count) / 2
        let span = min(rect.width, viewport.width * 0.5)
        for (index, fraction) in widths.enumerated() {
            let width = span * fraction * (index == 1 ? 1.12 : 1)
            let x = alignment == .leading ? rect.minX + rect.width * 0.08 : rect.midX - width / 2
            let height = index == 1 ? barHeight * 1.35 : barHeight
            let y = top + lineHeight * CGFloat(index) + (lineHeight - height) / 2
            add(.lyric, CGRect(x: x, y: y, width: width, height: height), cornerRadius: height / 2,
                emphasis: index == 1 ? 1 : max(0.18, 0.45 - Double(abs(index - 1)) * 0.1))
        }
    }

    /// Built-in layouts: artwork on the leading half, lyrics on the trailing half.
    private mutating func addTemplate(in rect: CGRect) {
        let side = min(rect.width * 0.34, rect.height * 0.5)
        add(.artwork, CGRect(x: rect.minX + rect.width * 0.25 - side / 2, y: rect.midY - side / 2, width: side, height: side),
            cornerRadius: side * 0.06)
        addLyricLines(in: CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height), alignment: .leading)
    }

    // MARK: Geometry

    private func evaluate(_ node: SkinCompiledSceneNode, size: CGSize, locals: [String: SkinValue]) -> [String: SkinValue] {
        var scoped = locals
        scoped["parent"] = .record(["width": .number(size.width), "height": .number(size.height)])
        scoped["self"] = .record(["hovered": .boolean(false), "pressed": .boolean(false), "dragging": .boolean(false)])
        var context = SkinEvaluationContext(data: data, locals: scoped, now: data.startTime + 30, live: live)
        context.moves = false
        return node.values(context)
    }

    private func frame(of node: SkinCompiledSceneNode, values: [String: SkinValue], in parent: CGRect, positioned: Bool) -> CGRect {
        let frame = values["frame"] ?? .null
        var width = dimension(frame[member: "width"], base: parent.width) ?? dimension(frame[member: "size"], base: parent.width)
        var height = dimension(frame[member: "height"], base: parent.height) ?? dimension(frame[member: "size"], base: parent.height)
        if let aspect = frame[member: "aspectRatio"].numberValue, aspect > 0 {
            if width == nil, let height { width = height * aspect }
            if height == nil, let width { height = width / aspect }
        }
        if positioned, width == nil || height == nil, !Self.fillsParent(node) {
            let intrinsic = intrinsicSize(node, values: values, in: parent.size)
            width = width ?? intrinsic.width
            height = height ?? intrinsic.height
        }
        let w = width ?? parent.width
        let h = height ?? parent.height
        guard positioned else {
            return CGRect(x: parent.midX - w / 2, y: parent.midY - h / 2, width: w, height: h)
        }
        let anchor = frame[member: "anchor"].textValue
        let point = unitPoint(anchor.isEmpty ? "center" : anchor)
        let x = dimension(frame[member: "x"], base: parent.width, signed: true) ?? parent.width / 2
        let y = dimension(frame[member: "y"], base: parent.height, signed: true) ?? parent.height / 2
        let centre = CGPoint(x: parent.minX + x + (0.5 - point.x) * w, y: parent.minY + y + (0.5 - point.y) * h)
        return CGRect(x: centre.x - w / 2, y: centre.y - h / 2, width: w, height: h)
    }

    /// The size a node asks for in a stack; nil on an axis it fills.
    private func intrinsicSize(_ node: SkinCompiledSceneNode, values: [String: SkinValue], in available: CGSize) -> (width: CGFloat?, height: CGFloat?) {
        let frame = values["frame"] ?? .null
        let width = dimension(frame[member: "width"], base: available.width) ?? dimension(frame[member: "size"], base: available.width)
        let height = dimension(frame[member: "height"], base: available.height) ?? dimension(frame[member: "size"], base: available.height)
        if width != nil, height != nil { return (width, height) }
        switch node.type {
        case "text", "lyricLine":
            let fontSize = CGFloat(values["fontSize"]?.number(24) ?? 24)
            let text = node.type == "lyricLine" || (values["text"]?.textValue ?? "").isEmpty ? Self.sampleLyric : values["text"]?.textValue ?? ""
            let measured = min(available.width, Self.textWidth(text, fontSize: fontSize))
            let lines = ceil(Self.textWidth(text, fontSize: fontSize) / max(1, available.width))
            return (width ?? measured, height ?? fontSize * 1.3 * min(3, max(1, lines)))
        case "symbol", "spacer":
            let side = CGFloat(values["size"]?.number(24) ?? 24)
            return (width ?? side, height ?? side)
        default:
            return (width, height)
        }
    }

    private static func fillsParent(_ node: SkinCompiledSceneNode) -> Bool {
        ["layer", "gradient", "shader", "fog", "particles", "comet", "repeat", "switch", "component", "lyrics", "scroll"].contains(node.type)
    }

    private func dimension(_ value: SkinValue, base: CGFloat, signed: Bool = false) -> CGFloat? {
        let floor = signed ? -Double.infinity : 0
        if let number = value.numberValue { return CGFloat(max(floor, number)) }
        let text = value.textValue
        let units: [(String, Double)] = [("vmin", min(viewport.width, viewport.height)), ("vmax", max(viewport.width, viewport.height)),
                                         ("vw", viewport.width), ("vh", viewport.height), ("%", base)]
        for (suffix, unit) in units where text.hasSuffix(suffix) {
            if let number = Double(text.dropLast(suffix.count)) { return CGFloat(max(floor, unit * number / 100)) }
        }
        return nil
    }

    /// CJK characters take a full em, others a little over half.
    private static func textWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        text.unicodeScalars.reduce(CGFloat(0)) { $0 + ($1.value >= 0x2E80 ? 1 : 0.55) } * fontSize
    }
}
