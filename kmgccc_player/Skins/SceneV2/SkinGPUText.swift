import AppKit
import CoreText
import Metal
import SwiftUI

// Text inside a `render: "gpu"` layer: Core Text lays a node out once, each glyph is rasterised
// once per size step into a small mipmapped mask, and every frame draws one quad per glyph
// with its `glyphMotion` (offset, turn, scale, blur, split, smear, glow) applied in the shader.

nonisolated struct SkinGPUGlyph {
    var affine0: SIMD4<Float>
    var affine1: SIMD4<Float>
    var rect: SIMD4<Float>
    var color: SIMD4<Float>
    var motion: SIMD4<Float>
    var extra: SIMD4<Float>
}

nonisolated struct SkinGPUPost {
    var size: SIMD2<Float>
    var distortion: Float = 0
    var chromatic: Float = 0
    var blur: Float = 0
    var start: Float = 0
    var axis = SIMD2<Float>(1, 0)
    var grain: Float = 0
    var time: Float = 0
    var pointScale: Float = 1
    /// The `lut` filter's strength in the last pass, 0 to 1.
    var lut: Float = 0
}

/// The `fov` filter of a GPU layer, in points.
nonisolated struct SkinGPULens: Equatable {
    var distortion: Double
    var chromatic: Double
    var blur: Double
    var start: Double

    @MainActor init(_ value: SkinValue) {
        distortion = min(0.6, max(-0.6, value[member: "distortion"].number(0.2)))
        chromatic = max(0, min(24, value[member: "chromatic"].number(1.5)))
        blur = max(0, min(32, value[member: "blur"].number(6)))
        start = value[member: "start"].number(0.45).clamped01
    }

    var bends: Bool { abs(distortion) > 0.001 || chromatic > 0.05 }
    var blurs: Bool { blur > 0.4 }
}

// MARK: - Layout

nonisolated struct SkinGPUTextGlyph {
    let font: CTFont
    let glyph: CGGlyph
    /// Baseline origin in the text box, y down.
    let position: CGPoint
    let advance: Double
    let ascent: Double
    let descent: Double
}

nonisolated struct SkinGPUTextLayout {
    let glyphs: [SkinGPUTextGlyph]
    let size: CGSize
}

/// Lays text out as SwiftUI's `Text` does for a scene text: lines broken to the frame width,
/// cut at `lineLimit`, stacked by the font's line height and aligned inside the frame.
@MainActor
enum SkinGPUTextLayouts {
    private struct Key: Hashable {
        let text: String, font: String, weight: String, size: Double, width: Double?, lineLimit: Int?, alignment: String, tracking: Double
        var lineSpacing: Double = 0
    }
    private static var cache: [Key: SkinGPUTextLayout] = [:]

    static func layout(_ text: String, font name: String, weight: String, size: Double, width: Double?, lineLimit: Int?,
                       alignment: String, tracking: Double, lineSpacing: Double = 0) -> SkinGPUTextLayout {
        let key = Key(text: text, font: name, weight: weight, size: size, width: width, lineLimit: lineLimit, alignment: alignment, tracking: tracking,
                      lineSpacing: max(0, lineSpacing))
        if let cached = cache[key] { return cached }
        if cache.count > 2048 { cache.removeAll(keepingCapacity: true) }
        let result = make(key)
        cache[key] = result
        return result
    }

    private static func make(_ key: Key) -> SkinGPUTextLayout {
        let base = SkinFontResolver.font(key.font, size: key.size, weight: key.weight) as CTFont
        var attributes: [NSAttributedString.Key: Any] = [.font: base]
        if key.tracking != 0 { attributes[.kern] = key.tracking }
        let string = NSAttributedString(string: key.text, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let length = string.length
        var lines: [CTLine] = []
        var start = 0
        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, key.width ?? 1e7)
            if count <= 0 { count = 1 }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
            if let limit = key.lineLimit, lines.count >= limit { break }
        }
        let ascent = CTFontGetAscent(base), descent = CTFontGetDescent(base), leading = CTFontGetLeading(base)
        let widths = lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth($0) }
        let textWidth = widths.max() ?? 0
        let boxWidth = key.width ?? textWidth
        let height = Double(lines.count) * (ascent + descent) + Double(max(0, lines.count - 1)) * (leading + key.lineSpacing)
        let units = Array(key.text.utf16)
        var glyphs: [SkinGPUTextGlyph] = []
        for (index, line) in lines.enumerated() {
            let baseline = ascent + Double(index) * (ascent + descent + leading + key.lineSpacing)
            let free = textWidth - widths[index]
            let inset = (boxWidth - textWidth) / 2 + (key.alignment == "center" ? free / 2 : key.alignment == "trailing" ? free : 0)
            for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let runAttributes = CTRunGetAttributes(run) as NSDictionary
                let font = runAttributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? base
                var ids = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
                CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
                let runAscent = CTFontGetAscent(font), runDescent = CTFontGetDescent(font)
                for slot in 0..<count {
                    // Line breaks have no slice in SwiftUI's layout, and glyph motion skips them.
                    let unit = indices[slot] < units.count ? units[indices[slot]] : 0
                    if unit == 10 || unit == 13 || unit == 0x2028 || unit == 0x2029 { continue }
                    glyphs.append(SkinGPUTextGlyph(font: font, glyph: ids[slot],
                                                   position: CGPoint(x: inset + positions[slot].x, y: baseline - positions[slot].y),
                                                   advance: advances[slot].width, ascent: runAscent, descent: runDescent))
                }
            }
        }
        return SkinGPUTextLayout(glyphs: glyphs, size: CGSize(width: boxWidth, height: height))
    }
}

// MARK: - Glyph masks

/// One mipmapped coverage mask per font, glyph and size step. Masks unused for a while are
/// dropped, and the whole set stays under a memory budget.
@MainActor
final class SkinGPUGlyphAtlas {
    final class Entry {
        let texture: MTLTexture
        /// The mask's rectangle in ems, baseline origin, y down.
        let rect: CGRect
        let levels: Int
        let bytes: Int
        var used = 0

        init(texture: MTLTexture, rect: CGRect, levels: Int, bytes: Int) {
            self.texture = texture; self.rect = rect; self.levels = levels; self.bytes = bytes
        }
    }

    private struct Key: Hashable {
        let font: String
        let glyph: CGGlyph
        let em: Int
    }

    private let device: MTLDevice
    private var entries: [Key: Entry?] = [:]
    private var fontNames: [ObjectIdentifier: String] = [:]
    private var pending: [MTLTexture] = []
    private var frame = 0
    private var bytes = 0
    private static let budget = 64 * 1024 * 1024

    init(device: MTLDevice) { self.device = device }

    /// The Gaussian deviation of a blur radius, as the layer's shapes read it.
    static let blurDeviation = 0.5

    /// The empty margin around a mask, in texels, where a little blur fades out.
    static func pad(em: Int) -> Int { max(4, Int(ceil(Double(em) * 0.4))) }

    /// The size step at or above `pixels` per em: half-octave steps from 12 to 512 pixels.
    static func step(_ pixels: Double) -> Int {
        let clamped = min(512, max(12, pixels))
        return Int(pow(2, ceil(log2(clamped) * 2) / 2).rounded())
    }

    /// Nil for a glyph with no ink, such as a space.
    func entry(font: CTFont, glyph: CGGlyph, em: Int) -> Entry? {
        let key = Key(font: name(of: font), glyph: glyph, em: em)
        if let cached = entries[key] {
            cached?.used = frame
            return cached
        }
        let created = rasterise(font: font, glyph: glyph, em: em)
        created?.used = frame
        entries[key] = created
        if let created { bytes += created.bytes }
        return created
    }

    /// Masks created since the last call, whose mip levels still need generating.
    func takePending() -> [MTLTexture] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    func endFrame() {
        frame += 1
        if frame % 300 == 0 {
            DebugUIHooks.record("glyph-atlas bytes=\(bytes) entries=\(entries.count) fonts=\(fontNames.count)")
        }
        guard frame % 120 == 0 || bytes > Self.budget else { return }
        let stale = frame - 600
        for (key, entry) in entries where (entry?.used ?? -1) < stale {
            bytes -= entry?.bytes ?? 0
            entries[key] = nil
        }
        if bytes > Self.budget {
            let oldest = entries.compactMap { key, entry in entry.map { (key, $0) } }.sorted { $0.1.used < $1.1.used }
            for (key, entry) in oldest where bytes > Self.budget * 3 / 4 {
                bytes -= entry.bytes
                entries[key] = nil
            }
        }
    }

    private func name(of font: CTFont) -> String {
        let id = ObjectIdentifier(font)
        if let name = fontNames[id] { return name }
        let variation = (CTFontCopyVariation(font) as NSDictionary?)?.description ?? ""
        let name = (CTFontCopyPostScriptName(font) as String) + "|" + variation
        if fontNames.count > 256 { fontNames.removeAll() }
        fontNames[id] = name
        return name
    }

    private func rasterise(font: CTFont, glyph: CGGlyph, em: Int) -> Entry? {
        let sized = CTFontCreateCopyWithAttributes(font, CGFloat(em), nil, nil)
        var id = glyph
        let bounds = CTFontGetBoundingRectsForGlyphs(sized, .default, &id, nil, 1)
        guard !bounds.isNull, bounds.width > 0.01, bounds.height > 0.01 else { return nil }
        // Room for blur to fade out inside the mask; a wider blur grows the glyph's quad past it.
        let pad = Self.pad(em: em)
        let left = floor(bounds.minX), bottom = floor(bounds.minY)
        let width = min(4096, Int(ceil(bounds.maxX) - left) + 2 * pad)
        let height = min(4096, Int(ceil(bounds.maxY) - bottom) + 2 * pad)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(false)
            context.setShouldSubpixelPositionFonts(true)
            var position = CGPoint(x: CGFloat(pad) - left, y: CGFloat(pad) - bottom)
            CTFontDrawGlyphs(sized, &id, &position, 1, context)
            return true
        }
        guard drawn else { return nil }
        let levels = Int(floor(log2(Double(max(width, height))))) + 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width)
        pending.append(texture)
        let scale = 1 / Double(em)
        let rect = CGRect(x: (left - CGFloat(pad)) * scale, y: -(bottom + CGFloat(height - pad)) * scale,
                          width: Double(width) * scale, height: Double(height) * scale)
        return Entry(texture: texture, rect: rect, levels: levels, bytes: width * height * 4 / 3)
    }
}

// MARK: - Text nodes

extension SkinGPULayerModel {
    /// One motion result per glyph, as `SkinGlyphTransform` reads it, plus its tint.
    struct GlyphMotion {
        var x = 0.0, y = 0.0, rotation = 0.0, scale = 1.0, opacity = 1.0, blur = 0.0
        var split = 0.0, smearX = 0.0, smearY = 0.0, glow = 0.0
        var tint: OKLCHColor?

        init() {}

        init(_ value: SkinValue) {
            glow = max(0, value[member: "glow"].number())
            x = value[member: "x"].number(); y = value[member: "y"].number()
            rotation = value[member: "rotation"].number(); scale = value[member: "scale"].number(1)
            opacity = value[member: "opacity"].number(1).clamped01; blur = max(0, value[member: "blur"].number())
            split = value[member: "split"].number(); smearX = value[member: "smearX"].number(); smearY = value[member: "smearY"].number()
            if let color = value[member: "tint"].colorValue, color.lightness < 0.999 || color.chroma > 0.001 || color.alpha < 0.999 { tint = color }
        }
    }

    func text(_ node: SkinCompiledSceneNode, values: [String: SkinValue], context: SkinEvaluationContext, world: CGAffineTransform,
              parent: CGSize, opacity: Double, clock: SkinGlyphClock, anchors: inout [CGPoint], now: Double, pixelsPerPoint: Double,
              into scene: inout SkinGPUScene) {
        guard let inputs, let atlas = SkinGPURenderer.shared?.atlas else { return }
        let string = values["text"]?.textValue ?? ""
        let fontSize = values["fontSize"]?.number(24) ?? 24
        guard !string.isEmpty, fontSize > 0.5 else { return }
        let frame = values["frame"] ?? .null
        let viewport = inputs.live?.size ?? inputs.data.viewportSize
        func dimension(_ value: SkinValue, horizontal: Bool, signed: Bool = false) -> Double? {
            skinDimension(value, horizontal: horizontal, signed: signed, viewport: viewport, parent: parent).map(Double.init)
        }
        let width = dimension(frame[member: "width"], horizontal: true)
        let layout = SkinGPUTextLayouts.layout(string, font: values["font"]?.textValue ?? "", weight: values["weight"]?.textValue ?? "regular",
                                               size: fontSize, width: width, lineLimit: values["lineLimit"].map { max(1, $0.integer(1)) },
                                               alignment: values["alignment"]?.textValue ?? "", tracking: values["tracking"]?.number() ?? 0,
                                               lineSpacing: values["lineSpacing"]?.number() ?? 0)
        guard !layout.glyphs.isEmpty else { return }
        let anchorName = frame[member: "anchor"].textValue
        let anchor = unitPoint(anchorName.isEmpty ? "center" : anchorName)
        let height = dimension(frame[member: "height"], horizontal: false)
        let x = (dimension(frame[member: "x"], horizontal: true, signed: true) ?? parent.width / 2) + (0.5 - anchor.x) * (width ?? 0)
        let y = (dimension(frame[member: "y"], horizontal: false, signed: true) ?? parent.height / 2) + (0.5 - anchor.y) * (height ?? 0)
        let box = layout.size
        // As the view renderer orders them: turn and scale about the frame's centre, then offset.
        let local = CGAffineTransform(translationX: x + (values["offsetX"]?.number() ?? 0), y: y + (values["offsetY"]?.number() ?? 0))
            .rotated(by: (values["rotation"]?.number() ?? 0) * .pi / 180)
            .scaledBy(x: values["scale"]?.number(1) ?? 1, y: values["scale"]?.number(1) ?? 1)
            .translatedBy(x: -box.width / 2, y: -box.height / 2)
        let toLayer = local.concatenating(world)
        let worldScale = sqrt(abs(toLayer.a * toLayer.d - toLayer.b * toLayer.c))
        let em = SkinGPUGlyphAtlas.step(fontSize * worldScale * pixelsPerPoint)
        let color = values["color"]?.colorValue ?? inputs.data.theme["theme.appForeground.primary"]?.colorValue
        let nodeBlur = max(0, values["blur"]?.number() ?? 0)
        let glow = SkinGlyphGlow(values["glow"], fallback: color)
        let glowColor = values["glow"]?[member: "color"].colorValue ?? color
        let motions = glyphMotions(node, values: values, text: string, context: context, clock: clock, now: now, fontSize: fontSize)
        let white = SIMD4<Float>(1, 1, 1, 1)
        for (index, glyph) in layout.glyphs.enumerated() {
            let motion = index < motions.count ? motions[index] : GlyphMotion()
            let glyphOpacity = opacity * motion.opacity
            let mid = CGPoint(x: glyph.position.x + glyph.advance / 2, y: glyph.position.y - (glyph.ascent - glyph.descent) / 2)
            let anchor = CGPoint(x: mid.x + motion.x, y: mid.y + motion.y).applying(toLayer)
            // Its own move since the previous frame, in layer points. The previous anchor already
            // sat in the previous frame's camera, so the lens's own travel is counted once here
            // and needs no second term.
            var travel = CGPoint.zero
            if index < anchors.count {
                travel = CGPoint(x: anchor.x - anchors[index].x, y: anchor.y - anchors[index].y)
                anchors[index] = anchor
            } else {
                anchors.append(anchor)
            }
            travel = shutterTravel(travel)
            guard glyphOpacity > 0.001, let entry = atlas.entry(font: glyph.font, glyph: glyph.glyph, em: em) else { continue }
            let size = CTFontGetSize(glyph.font)
            let rect = CGRect(x: entry.rect.minX * size, y: entry.rect.minY * size, width: entry.rect.width * size, height: entry.rect.height * size)
            // The glyph is drawn at the middle of the exposure, so the trail spans the path from
            // where it was to where it is now, once each side of it.
            let back = worldScale > 1e-4 ? 0.5 / worldScale : 0
            let moved = CGAffineTransform(translationX: mid.x + motion.x - travel.x * back, y: mid.y + motion.y - travel.y * back)
                .rotated(by: motion.rotation * .pi / 180)
                .scaledBy(x: motion.scale, y: motion.scale)
                .translatedBy(x: glyph.position.x - mid.x, y: glyph.position.y - mid.y)
            let full = moved.concatenating(toLayer)
            let pixelsPerGlyphPoint = Double(em) / size
            let radius = nodeBlur + motion.blur
            // The blur as a Gaussian deviation in mask texels.
            func deviation(_ blur: Double) -> Double { blur > 0.05 ? blur * pixelsPerGlyphPoint * SkinGPUGlyphAtlas.blurDeviation : 0 }
            let texel = SIMD2<Float>(1 / Float(entry.texture.width), 1 / Float(entry.texture.height))
            let pad = Double(SkinGPUGlyphAtlas.pad(em: em))
            let side = Double(min(entry.texture.width, entry.texture.height))
            func draw(ink: SIMD4<Float>, alpha: Double, blur: Double, split: Double = 0, smear: CGSize = .zero, additive: Bool, emits: Bool = false) {
                let splitUV = split / rect.width
                let smearUV = CGSize(width: smear.width / rect.width, height: smear.height / rect.height)
                let sigma = deviation(blur)
                // Room for the blur's tail past the mask's own margin.
                let tail = max(0, 2.6 * sigma - pad) / side
                let expand = max(abs(splitUV) + abs(smearUV.width) / 2, abs(smearUV.height) / 2) + tail
                let instance = SkinGPUGlyph(
                    affine0: SIMD4(Float(full.a), Float(full.b), Float(full.c), Float(full.d)),
                    affine1: SIMD4(Float(full.tx), Float(full.ty), 0, 0),
                    rect: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
                    color: ink,
                    motion: SIMD4(Float(splitUV), Float(smearUV.width), Float(smearUV.height), Float(sigma)),
                    extra: SIMD4(Float(expand), Float(alpha), texel.x, texel.y))
                if emits {
                    scene.emit(.glyph(instance, texture: entry.texture, additive: true), color: glowColor, saturation: glow?.saturation ?? 1)
                } else {
                    scene.items.append(.glyph(instance, texture: entry.texture, additive: additive))
                }
            }
            let amount = motion.glow
            let lit = amount > 0.001 ? glow : nil
            if let glow = lit {
                // The glyph as light, grey and brighter than white: the bloom spreads it and
                // colours each octave from `glowColor`.
                let light = Float(glow.strength * amount)
                draw(ink: SIMD4(light, light, light, 1), alpha: glyphOpacity, blur: radius, smear: smear(motion, travel: travel, scale: worldScale),
                     additive: true, emits: true)
                scene.bloomReach = max(scene.bloomReach, glow.radius * worldScale * motion.scale)
                scene.bloomHaze = max(scene.bloomHaze, glow.haze)
            }
            var ink = premultiplied(color)
            if let tint = motion.tint { ink *= premultiplied(tint) }
            draw(ink: ink, alpha: glyphOpacity, blur: radius, split: motion.split,
                 smear: smear(motion, travel: travel, scale: worldScale), additive: false)
            if let glow = lit, glow.core > 0.001 {
                draw(ink: white, alpha: glyphOpacity * min(1, glow.core * amount), blur: radius, additive: true)
            }
        }
        if anchors.count > layout.glyphs.count { anchors.removeSubrange(layout.glyphs.count..<anchors.count) }
    }

    /// The authored `smearX/Y` plus this frame's travel, in glyph points: the vector the shader
    /// integrates along. Capped so a cut or a re-layout cannot draw a glyph across the layer.
    private func smear(_ motion: GlyphMotion, travel: CGPoint, scale: Double) -> CGSize {
        var smear = CGSize(width: motion.smearX, height: motion.smearY)
        guard scale > 1e-4, travel.x != 0 || travel.y != 0 else { return smear }
        let length = hypot(travel.x, travel.y), cap = 160.0
        let share = length > cap ? cap / length : 1
        smear.width += travel.x * share / scale
        smear.height += travel.y * share / scale
        return smear
    }

    /// `glyphMotion` once per glyph, timed from when the text last changed, as the view renderer
    /// does for plain texts.
    private func glyphMotions(_ node: SkinCompiledSceneNode, values: [String: SkinValue], text: String, context: SkinEvaluationContext,
                              clock: SkinGlyphClock, now: Double, fontSize: Double) -> [GlyphMotion] {
        guard let inputs, inputs.moves, let motion = node.properties["glyphMotion"] else { return [] }
        let characters = Array(text.filter { !$0.isNewline })
        guard !characters.isEmpty, characters.count <= 512 else { return [] }
        let start = clock.start(for: text + "\u{1F}" + (values["key"]?.textValue ?? ""), now: now)
        var scope = context
        scope.memo = SkinLetMemo()
        let glyphMemo = SkinLetMemo()
        scope.glyphMemo = glyphMemo
        var result: [GlyphMotion] = []
        result.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            scope.followSlot = index + 1
            glyphMemo.values.removeAll(keepingCapacity: true)
            scope.locals["glyph"] = .record([
                "index": .number(Double(index)), "count": .number(Double(characters.count)), "char": .text(String(character)),
                "word": .number(0), "line": .number(0), "start": .number(start), "end": .number(start), "age": .number(now - start),
                "progress": .number(now >= start ? 1 : 0), "lineAge": .number(now - start), "fontSize": .number(fontSize),
            ])
            result.append(GlyphMotion(motion.evaluate(scope)))
        }
        return result
    }
}
