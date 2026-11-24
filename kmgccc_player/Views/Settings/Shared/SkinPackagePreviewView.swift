//
//  SkinPackagePreviewView.swift
//  kmgccc_player
//
//  Square card preview for a skin package: the author's picture when the manifest names one,
//  otherwise the scene's silhouette in flat blocks, otherwise the skin's first letter.
//

import AppKit
import SwiftUI

struct SkinPackagePreviewView: View {
    let skinID: String
    let surface: SkinSurface
    let foreground: Color
    let accent: Color
    @Environment(\.self) private var environment

    var body: some View {
        if let skin = SkinRegistry.catalog.registeredSkin(for: skinID) as? PackagedSkin {
            let roles = SkinPreviewRoles(foreground: foreground, accent: accent, in: environment)
            if let image = SkinPackagePreviewCache.authorImage(for: skin, roles: roles) {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let silhouette = SkinPackagePreviewCache.silhouette(for: skin, surface: surface), silhouette.hasContent {
                SkinSilhouetteCanvas(silhouette: silhouette, foreground: foreground, accent: roles.color(\.accent))
            } else {
                placeholder(skin.name, accent: roles.color(\.accent))
            }
        } else {
            placeholder(skinID, accent: accent)
        }
    }

    private func placeholder(_ name: String, accent: Color) -> some View {
        GeometryReader { proxy in
            ZStack {
                accent.opacity(0.16)
                Text(name.first.map(String.init) ?? "")
                    .font(.system(size: proxy.size.width * 0.38, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.55))
            }
        }
    }
}

/// The three colours a themed preview is painted in. All three read against the card: on a dark
/// card they are light, on a light card dark. The card is taken as dark when its foreground is
/// light, which also covers the fullscreen panel's fixed light-on-dark style.
struct SkinPreviewRoles: Equatable {
    /// Red: the theme accent at a lightness that stands out from the card.
    let accent: SIMD3<Float>
    /// Green: the card's primary foreground.
    let foreground: SIMD3<Float>
    /// Blue: a quiet neutral tinted with the accent, between the two in strength.
    let quiet: SIMD3<Float>
    let onDark: Bool

    init(foreground: Color, accent: Color, in environment: EnvironmentValues) {
        let resolvedForeground = foreground.resolve(in: environment)
        let foregroundColor = NSColor(Color(resolvedForeground))
        let foregroundLCH = OKColor.nsColorToOKLCH(foregroundColor) ?? .init(l: 0.9, c: 0, h: 0)
        onDark = foregroundLCH.l > 0.5
        let accentLCH = OKColor.nsColorToOKLCH(NSColor(Color(accent.resolve(in: environment)))) ?? foregroundLCH
        let strong = OKColor.OKLCH(l: onDark ? max(accentLCH.l, 0.8) : min(accentLCH.l, 0.42),
                                   c: min(max(accentLCH.c, 0.04), 0.14), h: accentLCH.h)
        let soft = OKColor.OKLCH(l: onDark ? 0.66 : 0.5, c: min(accentLCH.c, 0.03), h: accentLCH.h)
        func components(_ color: NSColor) -> SIMD3<Float> {
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
        }
        self.accent = components(OKColor.okLCHToNSColor(strong, alpha: 1))
        self.foreground = components(foregroundColor)
        quiet = components(OKColor.okLCHToNSColor(soft, alpha: 1))
    }

    func color(_ role: KeyPath<Self, SIMD3<Float>>) -> Color {
        let value = self[keyPath: role]
        return Color(.sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z))
    }

    var cacheKey: String {
        [accent, foreground, quiet].map { String(format: "%.3f,%.3f,%.3f", $0.x, $0.y, $0.z) }.joined(separator: "|")
    }
}

/// A few flat blocks on the card's own surface: the scene is scaled to the square's width and
/// centred. Bars keep a minimum thickness so type still reads.
struct SkinSilhouetteCanvas: View {
    let silhouette: SkinSceneSilhouette
    let foreground: Color
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let scale = size.width / max(1, silhouette.viewport.width)
            let offsetY = (size.height - silhouette.viewport.height * scale) / 2
            for block in silhouette.blocks {
                var rect = CGRect(x: block.rect.minX * scale, y: block.rect.minY * scale + offsetY,
                                  width: block.rect.width * scale, height: block.rect.height * scale)
                if rect.height < 3 { rect = rect.insetBy(dx: 0, dy: (rect.height - 3) / 2) }
                var layer = context
                layer.translateBy(x: rect.midX, y: rect.midY)
                if block.rotation != 0 { layer.rotate(by: .degrees(block.rotation)) }
                let local = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
                draw(block, in: local, scale: scale, context: &layer)
            }
        }
    }

    private func draw(_ block: SkinSceneSilhouette.Block, in rect: CGRect, scale: CGFloat, context: inout GraphicsContext) {
        func shape(_ rect: CGRect, radius: CGFloat) -> Path {
            block.isCircle ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: min(radius, min(rect.width, rect.height) / 2), style: .continuous)
        }
        switch block.kind {
        case .artwork:
            context.fill(shape(rect, radius: max(2, block.cornerRadius * scale)), with: .color(accent.opacity(0.8)))
        case .lyric:
            context.fill(shape(rect, radius: rect.height / 2), with: .color(foreground.opacity(block.emphasis >= 1 ? 0.7 : 0.25)))
        case .text:
            context.fill(shape(rect, radius: rect.height / 2), with: .color(foreground.opacity(0.35)))
        case .visualizer:
            // Five even bars stepping up and down.
            let levels: [CGFloat] = [0.45, 0.8, 1, 0.65, 0.4]
            let slot = rect.width / CGFloat(levels.count)
            let barWidth = min(slot * 0.55, max(3, rect.height * 0.25))
            for (index, level) in levels.enumerated() {
                let height = max(barWidth, rect.height * level)
                let bar = CGRect(x: rect.minX + slot * (CGFloat(index) + 0.5) - barWidth / 2, y: rect.maxY - height, width: barWidth, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: barWidth / 2), with: .color(accent.opacity(0.6)))
            }
        }
    }
}

/// Silhouettes are worked out once per compiled scene; author pictures once per file.
@MainActor
enum SkinPackagePreviewCache {
    private struct Entry {
        let root: SkinCompiledSceneNode
        let silhouette: SkinSceneSilhouette
    }

    private static var silhouettes: [String: Entry] = [:]
    private static var images: [String: NSImage] = [:]

    static func silhouette(for skin: PackagedSkin, surface: SkinSurface) -> SkinSceneSilhouette? {
        guard let program = skin.programs[surface.rawValue] ?? skin.programs["default"] else { return nil }
        let key = skin.id + "|" + surface.rawValue
        // A reload compiles a new program, which replaces the entry.
        if let entry = silhouettes[key], entry.root === program.root { return entry.silhouette }
        let silhouette = SkinSceneSilhouetteExtractor.silhouette(of: program, skin: skin, surface: surface)
        silhouettes[key] = Entry(root: program.root, silhouette: silhouette)
        return silhouette
    }

    /// The author's picture, the dark version on a dark card; a themed one is repainted in `roles`.
    static func authorImage(for skin: PackagedSkin, roles: SkinPreviewRoles) -> NSImage? {
        let dark = roles.onDark
        guard let preview = skin.manifest.preview else { return nil }
        let root: URL
        switch skin.origin {
        case .installed(let url), .development(let url): root = url
        case .bundled: guard let url = Bundle.main.resourceURL else { return nil }; root = url
        }
        let path = dark ? preview.dark ?? preview.image : preview.image
        guard let url = try? SkinResourceResolver.resolve(path, root: root) else { return nil }
        // An edited picture in a linked directory has a new date, so it loads again.
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        var key = url.path + "|" + String(modified)
        if preview.themed { key += "|" + roles.cacheKey }
        if let image = images[key] { return image }
        guard let source = NSImage(contentsOf: url) else { return nil }
        let image = preview.themed ? repaint(source, roles: roles) ?? source : source
        images[key] = image
        return image
    }

    /// Maps the red, green and blue channels onto the three role colours. Premultiplied pixels
    /// mix linearly, so edges, opacity and overlaps keep their blend.
    private static func repaint(_ source: NSImage, roles: SkinPreviewRoles) -> NSImage? {
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        func clamped(_ value: SIMD3<Float>) -> SIMD3<Float> { value.clamped(lowerBound: .zero, upperBound: .one) }
        let a = clamped(roles.accent), f = clamped(roles.foreground), q = clamped(roles.quiet)
        let (ar, ag, ab) = (a.x, a.y, a.z)
        let (fr, fg, fb) = (f.x, f.y, f.z)
        let (gr, gg, gb) = (q.x, q.y, q.z)
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let r = Float(pixels[index]), gn = Float(pixels[index + 1]), b = Float(pixels[index + 2])
            let alpha = Float(pixels[index + 3])
            pixels[index] = UInt8(min(alpha, (r * ar + gn * fr + b * gr).rounded()))
            pixels[index + 1] = UInt8(min(alpha, (r * ag + gn * fg + b * gg).rounded()))
            pixels[index + 2] = UInt8(min(alpha, (r * ab + gn * fb + b * gb).rounded()))
        }
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: source.size)
    }
}
