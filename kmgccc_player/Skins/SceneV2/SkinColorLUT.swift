import AppKit
import Metal
import Observation
import simd
import SwiftUI

/// The `lut` filter: a colour grade from a `.cube` file, `{ "type": "lut", "file": packageRelativePath, "amount": 0…1 }`.
/// A `render: "gpu"` layer applies it in its last pass, after its defocus, lens and edge blur and
/// before grain. Other nodes apply it as a SwiftUI colour effect in filter order. An empty
/// `file` or an `amount` of 0 leaves the colours untouched.
nonisolated struct SkinColorLUTFilter: Equatable {
    nonisolated struct Resource: Hashable, Sendable {
        let root: URL
        let path: String
    }

    let resource: Resource
    let amount: Double

    @MainActor init?(_ value: SkinValue, root: URL?) {
        let path = value[member: "file"].textValue
        let amount = value[member: "amount"].number(1).clamped01
        guard amount > 0.001, let root, (path as NSString).pathExtension.lowercased() == "cube" else { return nil }
        resource = Resource(root: root, path: path)
        self.amount = amount
    }
}

/// A loaded grade: the GPU layers' 3D lookup, baked for their Display P3 drawables, and the same
/// grade as a strip of blue slices for SwiftUI colour effects, which work in sRGB.
nonisolated final class SkinColorLUT: @unchecked Sendable {
    let size: Int
    let texture: MTLTexture?
    let strip: CGImage

    init(size: Int, texture: MTLTexture?, strip: CGImage) {
        self.size = size
        self.texture = texture
        self.strip = strip
    }

    @MainActor var image: Image { Image(decorative: strip, scale: 1) }

    /// Bound in place of a strip while none is loaded, so a SwiftUI effect keeps its structure.
    @MainActor static let placeholder: Image = {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return Image(decorative: context.makeImage()!, scale: 1)
    }()
}

/// Package grades load off the main thread and keep the most recently used lookups.
@MainActor
@Observable
final class SkinColorLUTLibrary {
    static let shared = SkinColorLUTLibrary()
    private static let keep = 6

    private typealias Resource = SkinColorLUTFilter.Resource
    private var loaded: [Resource: SkinColorLUT] = [:]
    @ObservationIgnored private var recent: [Resource] = []
    @ObservationIgnored private var loading: Set<Resource> = []
    @ObservationIgnored private var failed: Set<Resource> = []

    private init() {}

    func lut(for resource: SkinColorLUTFilter.Resource) -> SkinColorLUT? {
        if let lut = loaded[resource] {
            markRecent(resource)
            return lut
        }
        load(resource)
        return nil
    }

    func isLoading(_ resource: SkinColorLUTFilter.Resource) -> Bool { loading.contains(resource) }

    private func markRecent(_ resource: Resource) {
        guard recent.last != resource else { return }
        recent.removeAll { $0 == resource }
        recent.append(resource)
    }

    private func load(_ resource: Resource) {
        guard !failed.contains(resource), !loading.contains(resource) else { return }
        guard let url = try? SkinResourceResolver.resolve(resource.path, root: resource.root) else {
            failed.insert(resource)
            return
        }
        loading.insert(resource)
        nonisolated(unsafe) let device = SkinGPURenderer.shared?.device
        Task.detached(priority: .userInitiated) {
            let result = Result { try SkinCubeLUT(contentsOf: url).baked(device: device) }
            await MainActor.run {
                let library = SkinColorLUTLibrary.shared
                library.loading.remove(resource)
                switch result {
                case .success(let lut):
                    library.loaded[resource] = lut
                    library.markRecent(resource)
                    if library.recent.count > Self.keep { library.loaded[library.recent.removeFirst()] = nil }
                case .failure(let error):
                    library.failed.insert(resource)
                    Log.warning("skin lut \(url.lastPathComponent) failed: \(error.localizedDescription)", category: .ui)
                }
            }
        }
    }
}

/// A parsed `.cube` file (Adobe and Resolve): a 3D table, or a 1D one per channel, with its
/// domain. Values are sRGB-encoded in and out, as the format is used for Rec. 709 material.
nonisolated struct SkinCubeLUT {
    nonisolated enum Failure: LocalizedError {
        case unreadable, noSize, wrongCount(Int, Int)
        var errorDescription: String? {
            switch self {
            case .unreadable: "无法读取文件"
            case .noSize: "缺少 LUT_3D_SIZE 或 LUT_1D_SIZE"
            case .wrongCount(let found, let expected): "数据 \(found) 行，应为 \(expected) 行"
            }
        }
    }

    /// 3D: `size³` entries, red fastest; 1D: `size` entries per channel.
    let size: Int
    let is3D: Bool
    let values: [SIMD3<Float>]
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>

    init(contentsOf url: URL) throws {
        guard var data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Failure.unreadable }
        data.append(0)
        var size3 = 0, size1 = 0
        var lo = SIMD3<Float>(repeating: 0), hi = SIMD3<Float>(repeating: 1)
        var values: [SIMD3<Float>] = []
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            let end = base + raw.count - 1
            var cursor = base
            while cursor < end {
                // One line: skip leading blanks, then data, a keyword, or a comment.
                while cursor < end, cursor.pointee == 0x20 || cursor.pointee == 0x09 { cursor += 1 }
                let first = UInt8(bitPattern: cursor.pointee)
                var lineEnd = cursor
                while lineEnd < end, lineEnd.pointee != 0x0A, lineEnd.pointee != 0x0D { lineEnd += 1 }
                if (first >= 0x30 && first <= 0x39) || first == 0x2D || first == 0x2E || first == 0x2B {
                    var next: UnsafeMutablePointer<CChar>?
                    var read = cursor
                    var rgb = SIMD3<Float>(repeating: 0)
                    for channel in 0..<3 {
                        rgb[channel] = strtof(read, &next)
                        read = next.map { UnsafePointer($0) } ?? read
                    }
                    values.append(rgb)
                } else if first != 0x23, lineEnd > cursor {
                    let line = String(decoding: UnsafeRawBufferPointer(start: cursor, count: lineEnd - cursor), as: UTF8.self)
                    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    let numbers = parts.dropFirst().compactMap { Float($0) }
                    switch parts.first.map({ $0.uppercased() }) ?? "" {
                    case "LUT_3D_SIZE": size3 = numbers.first.map { Int($0) } ?? 0
                    case "LUT_1D_SIZE": size1 = numbers.first.map { Int($0) } ?? 0
                    case "DOMAIN_MIN" where numbers.count == 3: lo = SIMD3(numbers[0], numbers[1], numbers[2])
                    case "DOMAIN_MAX" where numbers.count == 3: hi = SIMD3(numbers[0], numbers[1], numbers[2])
                    case "LUT_3D_INPUT_RANGE" where numbers.count == 2, "LUT_1D_INPUT_RANGE" where numbers.count == 2:
                        lo = SIMD3(repeating: numbers[0]); hi = SIMD3(repeating: numbers[1])
                    default: break
                    }
                }
                cursor = lineEnd
                while cursor < end, cursor.pointee == 0x0A || cursor.pointee == 0x0D { cursor += 1 }
            }
        }
        if size3 >= 2, size3 <= 256 {
            guard values.count == size3 * size3 * size3 else { throw Failure.wrongCount(values.count, size3 * size3 * size3) }
            size = size3; is3D = true
        } else if size1 >= 2, size1 <= 65536 {
            guard values.count == size1 else { throw Failure.wrongCount(values.count, size1) }
            size = size1; is3D = false
        } else {
            throw Failure.noSize
        }
        self.values = values
        domainMin = lo
        domainMax = simd_max(hi, lo + 1e-6)
    }

    /// The grade of an sRGB-encoded colour in 0…1, interpolated trilinearly (linearly per channel in 1D).
    func sample(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let t = simd_clamp((color - domainMin) / (domainMax - domainMin), SIMD3(repeating: 0), SIMD3(repeating: 1))
        let last = Float(size - 1)
        let p = t * last
        let i0 = SIMD3<Int>(Int(p.x), Int(p.y), Int(p.z))
        let i1 = SIMD3<Int>(Swift.min(i0.x + 1, size - 1), Swift.min(i0.y + 1, size - 1), Swift.min(i0.z + 1, size - 1))
        let f = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
        guard is3D else {
            return SIMD3(values[i0.x].x + (values[i1.x].x - values[i0.x].x) * f.x,
                         values[i0.y].y + (values[i1.y].y - values[i0.y].y) * f.y,
                         values[i0.z].z + (values[i1.z].z - values[i0.z].z) * f.z)
        }
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { values[r + size * (g + size * b)] }
        let c00 = simd_mix(at(i0.x, i0.y, i0.z), at(i1.x, i0.y, i0.z), SIMD3(repeating: f.x))
        let c10 = simd_mix(at(i0.x, i1.y, i0.z), at(i1.x, i1.y, i0.z), SIMD3(repeating: f.x))
        let c01 = simd_mix(at(i0.x, i0.y, i1.z), at(i1.x, i0.y, i1.z), SIMD3(repeating: f.x))
        let c11 = simd_mix(at(i0.x, i1.y, i1.z), at(i1.x, i1.y, i1.z), SIMD3(repeating: f.x))
        let c0 = simd_mix(c00, c10, SIMD3(repeating: f.y)), c1 = simd_mix(c01, c11, SIMD3(repeating: f.y))
        return simd_mix(c0, c1, SIMD3(repeating: f.z))
    }

    /// The grade resampled on a grid of the table's own size (17 to 65 points per side): a 16-bit
    /// 3D texture whose coordinates and values are Display P3 encoded, for the GPU layers, and a
    /// 16-bit sRGB strip for SwiftUI. The conversion to and from sRGB is baked in, so either
    /// shader reads the grade with one lookup.
    func baked(device: MTLDevice?) throws -> SkinColorLUT {
        let n = Swift.max(17, Swift.min(65, is3D ? size : 33))
        let last = Float(n - 1)
        var p3 = [UInt16](repeating: 0, count: n * n * n * 4)
        var strip = [UInt16](repeating: 0, count: n * n * n * 4)
        func pack(_ value: SIMD3<Float>, into buffer: inout [UInt16], at index: Int) {
            let c = simd_clamp(value, SIMD3(repeating: 0), SIMD3(repeating: 1)) * 65535 + 0.5
            buffer[index] = UInt16(c.x); buffer[index + 1] = UInt16(c.y); buffer[index + 2] = UInt16(c.z); buffer[index + 3] = 65535
        }
        // The grid's points in linear light, one axis serving all three channels.
        let linear = (0..<n).map { Self.decode(Float($0) / last) }
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let grid = SIMD3<Float>(Float(r), Float(g), Float(b)) / last
                    // SwiftUI: sRGB in, sRGB out; strip column r + b·n, row g.
                    pack(sample(grid), into: &strip, at: ((g * n * n) + b * n + r) * 4)
                    // GPU layers: Display P3 in, through sRGB, Display P3 out.
                    let p3Linear = SIMD3(linear[r], linear[g], linear[b])
                    let srgb = Self.encode(simd_clamp(Self.p3ToSRGB * p3Linear, SIMD3(repeating: 0), SIMD3(repeating: 1)))
                    let graded = Self.encode(simd_max(Self.srgbToP3 * Self.decode(sample(srgb)), SIMD3(repeating: 0)))
                    pack(graded, into: &p3, at: (r + n * (g + n * b)) * 4)
                }
            }
        }
        var texture: MTLTexture?
        if let device {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = .rgba16Unorm
            descriptor.width = n; descriptor.height = n; descriptor.depth = n
            descriptor.usage = .shaderRead
            texture = device.makeTexture(descriptor: descriptor)
            p3.withUnsafeBytes { bytes in
                texture?.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                                 bytesPerRow: n * 8, bytesPerImage: n * n * 8)
            }
        }
        let width = n * n
        guard let provider = CGDataProvider(data: strip.withUnsafeBytes { Data($0) } as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: n, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure.unreadable
        }
        return SkinColorLUT(size: n, texture: texture, strip: image)
    }

    // The sRGB transfer, which Display P3 shares, and the linear primaries between the two.
    private static func decode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(decode(c.x), decode(c.y), decode(c.z))
    }

    private static func decode(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    private static func encode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(encode(c.x), encode(c.y), encode(c.z))
    }

    private static func encode(_ v: Float) -> Float { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    private static let p3ToSRGB = simd_float3x3(rows: [
        SIMD3(1.2249401, -0.2249404, 0.0000001),
        SIMD3(-0.0420569, 1.0420571, 0.0000000),
        SIMD3(-0.0196376, -0.0786361, 1.0982735),
    ])

    private static let srgbToP3 = simd_float3x3(rows: [
        SIMD3(0.8224621, 0.1775380, 0.0000000),
        SIMD3(0.0331941, 0.9668058, 0.0000000),
        SIMD3(0.0170827, 0.0723974, 0.9105199),
    ])
}
