import AppKit
import ImageIO
import MetalKit
import SwiftUI

@MainActor
private enum SkinSceneMetalContext {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
}

private nonisolated final class SkinShaderBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A package's own fragment shader over the node's frame. Draws only when the scene timeline
/// requests a frame; there is no second display loop.
///
/// Inputs: the uniforms below, the artwork, and on the full signature also the spectrum, the
/// waveform, up to 16 `args`, up to 4 package `images` and, with `feedback`, the previous frame.
/// Limits: 1 MB of source; textures at most 2048 pixels on their long side; at most two frames
/// queued on the GPU; a shader that keeps a frame above 25 ms of GPU time is stopped.
struct SkinSceneShader: NSViewRepresentable {
    let values: [String: SkinValue]
    let data: SkinSceneData
    let snapshot: SkinSceneSnapshot
    let now: Double
    @Environment(\.skinPackageResources) private var root
    func makeNSView(context: Context) -> ShaderView { ShaderView() }
    func updateNSView(_ view: ShaderView, context: Context) {
        let path = values["path"]?.textValue ?? ""
        view.update(url: root.flatMap { try? SkinResourceResolver.resolve(path, root: $0) },
                    images: (values["images"]?.listValue ?? []).prefix(4).map { item in root.flatMap { try? SkinResourceResolver.resolve(item.textValue, root: $0) } },
                    values: values, data: data, snapshot: snapshot, now: now)
    }
    static func dismantleNSView(_ view: ShaderView, coordinator: ()) { view.release() }

    struct Uniforms {
        var resolution = SIMD2<Float>(1, 1)
        var time: Float = 0
        var lyricsTime: Float = 0
        var progress: Float = 0
        var bass: Float = 0
        var mid: Float = 0
        var treble: Float = 0
        var accent = SIMD4<Float>(1, 1, 1, 1)
        var deltaTime: Float = 0
        var frame: Float = 0
        var level: Float = 0
        var beat: Float = 0
        var lowMid: Float = 0
        var vocal: Float = 0
        var playing: Float = 0
        var pixelsPerPoint: Float = 1
        var pointer = SIMD2<Float>(0.5, 0.5)
        var pointerInside: Float = 0
        var duration: Float = 0
        var spectrumCount: Int32 = 0
        var waveformCount: Int32 = 0
        var argCount: Int32 = 0
        var imageCount: Int32 = 0
        var averageColor = SIMD4<Float>(0, 0, 0, 1)
        var palette: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    }

    final class ShaderView: NSView, MTKViewDelegate {
        static let maxSpectrum = 256, maxWaveform = 2048, maxArgs = 16
        nonisolated static let maxTextureSide = 2048
        static let spectrumOffset = 0, waveformOffset = 1024, argsOffset = 9216, bufferLength = 9472
        static let budget = 0.025, budgetFrames = 60

        private var metal: MTKView?
        private var pipeline: MTLRenderPipelineState?
        private var copyPipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private var key = ""
        private var feedback = false
        private var resolution: CGFloat = 1
        private var uniforms = Uniforms()
        private var spectrum: [Float] = []
        private var waveform: [Float] = []
        private var args: [SIMD4<Float>] = []
        private var buffers: [MTLBuffer] = []
        private var frameIndex = 0
        private var inFlight = 0
        private var lastNow: Double?
        private var cost = 0.0
        private var overBudget = 0
        private var artwork: MTLTexture?
        private var artworkKey = ""
        private var images: [MTLTexture?] = []
        private var imagesKey = ""
        private var targets: [MTLTexture] = []
        private var targetCleared = false
        private var placeholder: MTLTexture?
        private var tracking: NSTrackingArea?
        private let errorLabel = NSTextField(wrappingLabelWithString: "")
        private var failed = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            assert(MemoryLayout<Uniforms>.stride == 192, "SkinUniforms layout")
            if let device = SkinSceneMetalContext.device {
                let view = MTKView(frame: bounds, device: device)
                view.colorPixelFormat = .bgra8Unorm; view.isPaused = true; view.enableSetNeedsDisplay = true
                view.framebufferOnly = true; view.autoResizeDrawable = false; view.delegate = self
                view.layer?.isOpaque = false
                addSubview(view); metal = view; queue = SkinSceneMetalContext.queue
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
                placeholder = device.makeTexture(descriptor: descriptor)
                var pixel: [UInt8] = [0, 0, 0, 0]
                pixel.withUnsafeMutableBytes { bytes in
                    if let address = bytes.baseAddress { placeholder?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: address, bytesPerRow: 4) }
                }
            }
            errorLabel.isHidden = true; errorLabel.textColor = .secondaryLabelColor
            addSubview(errorLabel)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            metal?.frame = bounds; errorLabel.frame = bounds.insetBy(dx: 16, dy: 16)
            resize()
        }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resize() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // MARK: Pointer

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseMoved(with event: NSEvent) { point(event) }
        override func mouseEntered(with event: NSEvent) { point(event); uniforms.pointerInside = 1 }
        override func mouseExited(with event: NSEvent) { uniforms.pointerInside = 0 }
        private func point(_ event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            guard bounds.width > 0, bounds.height > 0 else { return }
            uniforms.pointer = SIMD2(Float(location.x / bounds.width), Float(1 - location.y / bounds.height))
        }

        // MARK: Update

        func update(url: URL?, images imageURLs: [URL?], values: [String: SkinValue], data: SkinSceneData, snapshot: SkinSceneSnapshot, now: Double) {
            let wantsFeedback = values["feedback"]?.isTruthy == true
            let nextResolution = CGFloat(SkinRenderScale.factor(values["resolution"]?.numberValue ?? 1))
            if nextResolution != resolution { resolution = nextResolution; resize() }
            let function = values["function"]?.textValue ?? "skinFragment"
            let nextKey = "\(url?.path ?? "")#\(function)#\(wantsFeedback)"
            if key != nextKey {
                key = nextKey; feedback = wantsFeedback; pipeline = nil; failed = false; cost = 0; overBudget = 0
                targets = []
                compile(url: url, function: function)
            }
            guard !failed else { return }
            loadArtwork(snapshot)
            loadImages(imageURLs)

            let audio = data.audio
            uniforms.deltaTime = Float(lastNow.map { min(0.25, max(0, now - $0)) } ?? 0); lastNow = now
            uniforms.frame += 1
            uniforms.time = Float(data.time(at: now)); uniforms.lyricsTime = Float(data.clock.lyricsTime(at: now))
            uniforms.duration = Float(data.clock.duration)
            uniforms.progress = Float(data.clock.duration > 0 ? data.clock.position(at: now) / data.clock.duration : 0)
            uniforms.playing = snapshot.playback.isPlaying ? 1 : 0
            uniforms.bass = Float(data.band(lowHz: 20, highHz: 150, now: now)); uniforms.lowMid = Float(data.band(lowHz: 150, highHz: 400, now: now))
            uniforms.mid = Float(data.band(lowHz: 400, highHz: 1200, now: now)); uniforms.vocal = Float(data.band(lowHz: 1000, highHz: 3500, now: now))
            uniforms.treble = Float(data.band(lowHz: 3500, highHz: 16000, now: now))
            uniforms.level = Float(audio.value("audio.level", now: now).number()); uniforms.beat = Float(audio.value("audio.beat", now: now).number())
            uniforms.accent = Self.rgba(NSColor(snapshot.theme.accentColor))
            uniforms.averageColor = Self.rgba(snapshot.theme.artworkAverageColor ?? NSColor.black)
            let palette = snapshot.theme.artworkPalette.map { Self.rgba($0) }
            func swatch(_ index: Int) -> SIMD4<Float> { palette.isEmpty ? uniforms.averageColor : palette[min(index, palette.count - 1)] }
            uniforms.palette = (swatch(0), swatch(1), swatch(2), swatch(3))

            let spectrumCount = min(Self.maxSpectrum, max(0, Int(values["spectrum"]?.numberValue ?? 64)))
            spectrum = spectrumCount > 0 ? data.spectrum(count: spectrumCount, lowHz: 30, highHz: 16_000, now: now).map(Float.init) : []
            let waveformCount = min(Self.maxWaveform, max(0, Int(values["waveform"]?.numberValue ?? 256)))
            waveform = waveformCount > 1 ? data.waveform(count: waveformCount).map(Float.init) : []
            args = (values["args"]?.listValue ?? []).prefix(Self.maxArgs).map(Self.vector)
            uniforms.spectrumCount = Int32(spectrum.count); uniforms.waveformCount = Int32(waveform.count)
            uniforms.argCount = Int32(args.count); uniforms.imageCount = Int32(imageURLs.count)
            metal?.needsDisplay = true
        }

        private func resize() {
            guard let metal else { return }
            let scale = (window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) * resolution
            let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
            uniforms.pixelsPerPoint = Float(scale)
            guard metal.drawableSize != size else { return }
            metal.drawableSize = size
            targets = []
        }

        private func compile(url: URL?, function: String) {
            do {
                guard let url, let device = metal?.device else { throw SkinPackageError.invalidManifest("着色器不可用") }
                let source = try String(contentsOf: url, encoding: .utf8)
                guard source.utf8.count <= 1024 * 1024 else { throw SkinPackageError.invalidManifest("着色器超过大小限制") }
                let full = Self.usesInputs(source, function: function)
                let expectedKey = key
                let format: MTLPixelFormat = feedback ? .rgba16Float : .bgra8Unorm
                device.makeLibrary(source: Self.prelude + "\n" + source + "\n" + Self.entry(function, full: full), options: nil) { [weak self] library, error in
                    Task { @MainActor [weak self] in
                        guard let self, self.key == expectedKey else { return }
                        do {
                            if let error { throw error }
                            guard let library else { throw SkinPackageError.invalidManifest("着色器编译失败") }
                            let descriptor = MTLRenderPipelineDescriptor()
                            descriptor.vertexFunction = library.makeFunction(name: "skinVertex")
                            descriptor.fragmentFunction = library.makeFunction(name: "skinMain")
                            descriptor.colorAttachments[0].pixelFormat = format
                            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                            if self.feedback {
                                let copy = MTLRenderPipelineDescriptor()
                                copy.vertexFunction = library.makeFunction(name: "skinVertex")
                                copy.fragmentFunction = library.makeFunction(name: "skinCopy")
                                copy.colorAttachments[0].pixelFormat = .bgra8Unorm
                                self.copyPipeline = try device.makeRenderPipelineState(descriptor: copy)
                            }
                            self.errorLabel.isHidden = true
                            self.metal?.needsDisplay = true
                        } catch { self.report(error.localizedDescription) }
                    }
                }
            } catch { report(error.localizedDescription) }
        }

        // MARK: Textures

        private func loadArtwork(_ snapshot: SkinSceneSnapshot) {
            let next = "\(snapshot.track?.id.uuidString ?? "")#\(snapshot.track?.artworkChecksum ?? 0)"
            guard artworkKey != next, let device = metal?.device else { return }
            artworkKey = next
            if let data = snapshot.track?.artworkData {
                load(.init(device), source: .init(.data(data))) { [weak self] texture in
                    guard let self, self.artworkKey == next else { return }
                    self.artwork = texture; self.metal?.needsDisplay = true
                }
            } else if let image = snapshot.track?.artworkImage {
                var rect = CGRect(origin: .zero, size: image.size)
                artwork = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                    .flatMap { try? MTKTextureLoader(device: device).newTexture(cgImage: $0, options: Self.textureOptions) }
            } else {
                artwork = nil
            }
        }

        private func loadImages(_ urls: [URL?]) {
            let next = urls.map { $0?.path ?? "" }.joined(separator: "|")
            guard imagesKey != next, let device = metal?.device else { return }
            imagesKey = next
            images = Array(repeating: nil, count: urls.count)
            for (index, url) in urls.enumerated() {
                guard let url else { continue }
                load(.init(device), source: .init(.url(url))) { [weak self] texture in
                    guard let self, self.imagesKey == next, self.images.indices.contains(index) else { return }
                    self.images[index] = texture; self.metal?.needsDisplay = true
                }
            }
        }

        private nonisolated enum TextureSource { case data(Data), url(URL) }

        /// Decodes at most `maxTextureSide` pixels and uploads with mipmaps, off the main thread.
        private func load(_ device: SkinShaderBox<MTLDevice>, source: SkinShaderBox<TextureSource>, done: @escaping @MainActor (MTLTexture?) -> Void) {
            Task { @MainActor in
                let texture = await Task.detached(priority: .userInitiated) { () -> SkinShaderBox<MTLTexture?> in
                    autoreleasepool { SkinShaderBox(Self.makeTexture(device.value, source: source.value)) }
                }.value
                done(texture.value)
            }
        }

        nonisolated private static func makeTexture(_ device: MTLDevice, source: TextureSource) -> MTLTexture? {
            let image: CGImageSource? = switch source {
            case .data(let data): CGImageSourceCreateWithData(data as CFData, nil)
            case .url(let url): CGImageSourceCreateWithURL(url as CFURL, nil)
            }
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                           kCGImageSourceThumbnailMaxPixelSize: maxTextureSide] as CFDictionary
            guard let image, let decoded = CGImageSourceCreateThumbnailAtIndex(image, 0, options) else { return nil }
            return try? MTKTextureLoader(device: device).newTexture(cgImage: decoded, options: textureOptions)
        }

        nonisolated private static var textureOptions: [MTKTextureLoader.Option: Any] {
            [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft, .generateMipmaps: true,
             .textureUsage: MTLTextureUsage.shaderRead.rawValue, .textureStorageMode: MTLStorageMode.private.rawValue]
        }

        private func feedbackTargets(_ size: CGSize, device: MTLDevice) -> [MTLTexture] {
            if targets.count == 2, targets[0].width == Int(size.width), targets[0].height == Int(size.height) { return targets }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Int(size.width), height: Int(size.height), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .private
            targets = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            targetCleared = false
            return targets
        }

        // MARK: Draw

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            // Two frames queued at most: a slow shader lowers its own frame rate instead of
            // making the main thread wait for a drawable.
            guard !failed, inFlight < 2, let pipeline, let device = view.device, let queue,
                  let command = queue.makeCommandBuffer() else { return }
            if buffers.isEmpty {
                buffers = (0..<3).compactMap { _ in device.makeBuffer(length: Self.bufferLength, options: .storageModeShared) }
                guard buffers.count == 3 else { return }
            }
            let buffer = buffers[frameIndex % 3]; frameIndex &+= 1
            let base = buffer.contents()
            func write(_ bytes: UnsafeRawBufferPointer, at offset: Int) {
                if let source = bytes.baseAddress, bytes.count > 0 { base.advanced(by: offset).copyMemory(from: source, byteCount: bytes.count) }
            }
            spectrum.withUnsafeBytes { write($0, at: Self.spectrumOffset) }
            waveform.withUnsafeBytes { write($0, at: Self.waveformOffset) }
            args.withUnsafeBytes { write($0, at: Self.argsOffset) }
            uniforms.resolution = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))

            let fallback = placeholder
            func encode(_ encoder: MTLRenderCommandEncoder, previous: MTLTexture?) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBuffer(buffer, offset: Self.spectrumOffset, index: 1)
                encoder.setFragmentBuffer(buffer, offset: Self.waveformOffset, index: 2)
                encoder.setFragmentBuffer(buffer, offset: Self.argsOffset, index: 3)
                encoder.setFragmentTexture(artwork ?? fallback, index: 0)
                encoder.setFragmentTexture(previous ?? fallback, index: 1)
                for slot in 0..<4 { encoder.setFragmentTexture((images.indices.contains(slot) ? images[slot] : nil) ?? fallback, index: 2 + slot) }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }

            if feedback {
                guard let copyPipeline else { return }
                let pair = feedbackTargets(view.drawableSize, device: device)
                guard pair.count == 2 else { return }
                let current = pair[frameIndex % 2], previous = pair[(frameIndex + 1) % 2]
                if !targetCleared {
                    let clear = MTLRenderPassDescriptor()
                    clear.colorAttachments[0].texture = previous; clear.colorAttachments[0].loadAction = .clear
                    clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                    command.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
                    targetCleared = true
                }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = current; pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
                encode(encoder, previous: previous)
                guard let screen = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                      let copy = command.makeRenderCommandEncoder(descriptor: screen) else { return }
                copy.setRenderPipelineState(copyPipeline)
                copy.setFragmentTexture(current, index: 0)
                copy.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                copy.endEncoding()
                command.present(drawable)
            } else {
                guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                      let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
                encode(encoder, previous: nil)
                command.present(drawable)
            }

            inFlight += 1
            let expectedKey = key
            command.addCompletedHandler { [weak self] buffer in
                let message = buffer.error?.localizedDescription
                let seconds = buffer.gpuEndTime - buffer.gpuStartTime
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.inFlight = max(0, self.inFlight - 1)
                    guard self.key == expectedKey else { return }
                    if let message { self.report(message); return }
                    self.measure(seconds)
                }
            }
            command.commit()
        }

        /// A shader that keeps a frame above the budget for a second is stopped; the scene and
        /// the rest of the App keep their frame rate.
        private func measure(_ seconds: Double) {
            guard seconds.isFinite, seconds > 0 else { return }
            cost = cost == 0 ? seconds : cost * 0.9 + seconds * 0.1
            overBudget = cost > Self.budget ? overBudget + 1 : 0
            if overBudget >= Self.budgetFrames {
                report("每帧耗时 \(Int((cost * 1000).rounded())) 毫秒，超过 \(Int(Self.budget * 1000)) 毫秒，已停用")
            }
        }

        private func report(_ message: String) {
            failed = true; pipeline = nil; copyPipeline = nil
            errorLabel.stringValue = "着色器：\(message)"; errorLabel.isHidden = false
            Log.warning("Skin shader failed: \(message)", category: .ui)
        }

        func release() {
            key = ""; metal?.delegate = nil; metal?.isPaused = true
            artwork = nil; images = []; targets = []; buffers = []; pipeline = nil; copyPipeline = nil; queue = nil
        }

        // MARK: Values

        private static func rgba(_ color: NSColor) -> SIMD4<Float> {
            let color = color.usingColorSpace(.sRGB) ?? .white
            return SIMD4(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent), Float(color.alphaComponent))
        }

        /// A number fills x; a list of up to four numbers fills x to w; a colour is sRGB rgba.
        private static func vector(_ value: SkinValue) -> SIMD4<Float> {
            if value.type == .color, let color = value.colorValue { return rgba(NSColor(color.swiftUIColor)) }
            if value.type == .list {
                let numbers = value.listValue.prefix(4).map { Float($0.number()) }
                return SIMD4((0..<4).map { $0 < numbers.count ? numbers[$0] : 0 })
            }
            return SIMD4(Float(value.number()), 0, 0, 0)
        }

        /// The full signature takes `SkinInputs`; the short one only the artwork.
        private static func usesInputs(_ source: String, function: String) -> Bool {
            guard let pattern = try? NSRegularExpression(pattern: "\\b\(function)\\s*\\(([^)]*)\\)") else { return false }
            let range = NSRange(source.startIndex..., in: source)
            return pattern.matches(in: source, range: range).contains { match in
                Range(match.range(at: 1), in: source).map { source[$0].contains("SkinInputs") } ?? false
            }
        }

        static let prelude = """
        #include <metal_stdlib>
        using namespace metal;
        struct SkinUniforms {
            float2 resolution; float time; float lyricsTime; float progress; float bass; float mid; float treble; float4 accent;
            float deltaTime; float frame; float level; float beat; float lowMid; float vocal; float playing; float pixelsPerPoint;
            float2 pointer; float pointerInside; float duration;
            int spectrumCount; int waveformCount; int argCount; int imageCount;
            float4 averageColor; float4 palette[4];
        };
        struct SkinVertex { float4 position [[position]]; float2 uv; };
        struct SkinInputs {
            texture2d<float> artwork; texture2d<float> previous;
            texture2d<float> image0; texture2d<float> image1; texture2d<float> image2; texture2d<float> image3;
            constant float* spectrumData; constant float* waveformData; constant float4* argData;
            int spectrumCount; int waveformCount; int argCount;
            float2 position;
        };
        constexpr sampler skinLinear(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
        constexpr sampler skinRepeat(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
        static inline float skinSampleData(constant float* data, int count, float x) {
            if (count <= 0) return 0.0;
            float p = clamp(x, 0.0, 1.0) * float(count - 1);
            int i = int(floor(p));
            return mix(data[i], data[min(i + 1, count - 1)], p - float(i));
        }
        static inline float skinSpectrum(SkinInputs in, float x) { return skinSampleData(in.spectrumData, in.spectrumCount, x); }
        static inline float skinWaveform(SkinInputs in, float x) { return skinSampleData(in.waveformData, in.waveformCount, x); }
        static inline float4 skinArg(SkinInputs in, int index) { return index >= 0 && index < in.argCount ? in.argData[index] : float4(0.0); }
        static inline float4 skinArtwork(SkinInputs in, float2 uv, float blur = 0.0) { return in.artwork.sample(skinLinear, uv, level(blur)); }
        static inline float4 skinPrevious(SkinInputs in, float2 uv) { return in.previous.sample(skinLinear, uv); }
        static inline float4 skinImage(SkinInputs in, int index, float2 uv, float blur = 0.0) {
            switch (index) {
                case 0: return in.image0.sample(skinRepeat, uv, level(blur));
                case 1: return in.image1.sample(skinRepeat, uv, level(blur));
                case 2: return in.image2.sample(skinRepeat, uv, level(blur));
                default: return in.image3.sample(skinRepeat, uv, level(blur));
            }
        }
        vertex SkinVertex skinVertex(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            return {float4(p * 2.0 - 1.0, 0, 1), float2(p.x, 1.0 - p.y)};
        }
        fragment float4 skinCopy(SkinVertex in [[stage_in]], texture2d<float> source [[texture(0)]]) {
            return source.sample(skinLinear, in.uv);
        }
        """

        static func entry(_ function: String, full: Bool) -> String {
            """
            fragment float4 skinMain(SkinVertex v [[stage_in]], constant SkinUniforms& u [[buffer(0)]],
                                     constant float* spectrum [[buffer(1)]], constant float* waveform [[buffer(2)]], constant float4* args [[buffer(3)]],
                                     texture2d<float> artwork [[texture(0)]], texture2d<float> previous [[texture(1)]],
                                     texture2d<float> image0 [[texture(2)]], texture2d<float> image1 [[texture(3)]],
                                     texture2d<float> image2 [[texture(4)]], texture2d<float> image3 [[texture(5)]]) {
                \(full
                  ? "SkinInputs in = {artwork, previous, image0, image1, image2, image3, spectrum, waveform, args, u.spectrumCount, u.waveformCount, u.argCount, v.position.xy};\n    return \(function)(v.uv, u, in);"
                  : "return \(function)(v.uv, u, artwork);")
            }
            """
        }
    }
}
