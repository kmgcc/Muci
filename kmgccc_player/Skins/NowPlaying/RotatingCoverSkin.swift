//
//  RotatingCoverSkin.swift
//  myPlayer2
//
//  kmgccc_player - Rotating Cover Skin
//

import AppKit
import Combine
import CoreImage
import CryptoKit
import MotionKit
import SwiftUI

struct RotatingCoverSkin: NowPlayingSkin {
    static let id: String = "rotatingCover"

    let descriptor = SkinDescriptor(
        id: RotatingCoverSkin.id,
        name: NSLocalizedString("skin.rotating_cover.name", comment: ""),
        detail: NSLocalizedString("skin.rotating_cover.detail", comment: ""),
        systemImage: "record.circle",
        audio: SkinAudioDefaults(window: .miniPlayerSpectrum, fullscreen: .miniPlayerSpectrum),
        artwork: SkinArtworkDefaults(scale: 1.1, maximumScale: 1.35),
        fullscreenTypography: SkinDescriptor.coverTypography,
        legacy: SkinLegacySettings(
            visualizerNamespace: "skin.rotatingCover",
            visualizerActivationKind: .spectrum,
            entryBooleanKey: "skin.rotatingCover.cdMode"
        )
    )

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(RotatingCoverArtwork(context: context))
    }

    var settingsView: AnyView? {
        AnyView(RotatingCoverSkinNormalSettingsView())
    }

    var fullscreenSettingsView: AnyView? {
        AnyView(RotatingCoverSkinFullscreenSettingsView())
    }
}

private enum RotatingCoverLayout {
    private static let classicWindowScaleFactor: CGFloat = 0.5
    private static let classicFullscreenScaleFactor: CGFloat = 0.6
    private static let classicWindowMaxSize: CGFloat = 360
    private static let classicFullscreenMaxSize: CGFloat = 480
    private static let classicMinSize: CGFloat = 180
    private static let classicFullscreenArtworkBoost: CGFloat = 1.22
    private static let classicFullscreenVisualScale: CGFloat = 1.2
    private static let baseExpansionRatio: CGFloat = 1.12
    private static let fullscreenSharedBaseXOffset: CGFloat = -8
    private static let embeddedFullscreenYOffset: CGFloat = 12

    static let discToBaseRatio: CGFloat = 0.75
    /// CD 的透明外缘很窄：封面圆几乎铺满玻璃底座，只留一圈细玻璃边。
    static let cdDiscToBaseRatio: CGFloat = 0.97
    /// 封面环的内径：往里是一圈精致适度的透明盘心。
    static let cdLabelInnerToBaseRatio: CGFloat = 0.31
    /// 中心孔径，适度呈现精致真实的光碟结构。
    static let cdHoleToBaseRatio: CGFloat = 0.14
    static let yOffsetWindow: CGFloat = 0
    static let yOffsetFullscreen: CGFloat = 32

    struct Metrics {
        let discSize: CGFloat
        let baseSize: CGFloat
        let xOffset: CGFloat
        let yOffset: CGFloat
    }

    static func metrics(for context: SkinContext, isFullscreen: Bool, discRatio: CGFloat) -> Metrics {
        let baseSize = expandedBaseVisualSize(for: context, isFullscreen: isFullscreen)
        let discSize = baseSize * discRatio
        let xOffset = FullscreenCoverHorizontalOffset.artworkOffsetX(
            for: context,
            baseOffset: fullscreenSharedBaseXOffset
        )
        let yOffset: CGFloat
        if isFullscreen {
            yOffset = context.fullscreenHostMode == .embeddedWindow
                ? embeddedFullscreenYOffset
                : yOffsetFullscreen
        } else {
            yOffset = yOffsetWindow
        }
        return Metrics(
            discSize: discSize,
            baseSize: baseSize,
            xOffset: xOffset,
            yOffset: yOffset
        )
    }

    private static func classicArtworkVisualSize(for context: SkinContext, isFullscreen: Bool) -> CGFloat {
        let contentSize = context.contentSize
        let artworkBoost = isFullscreen ? classicFullscreenArtworkBoost : 1.0
        let scaleFactor = isFullscreen ? classicFullscreenScaleFactor : classicWindowScaleFactor
        let maxSizeBase = isFullscreen ? classicFullscreenMaxSize : classicWindowMaxSize
        let maxSize = maxSizeBase * artworkBoost
        let maxArtwork = min(
            contentSize.width * scaleFactor,
            contentSize.height * scaleFactor,
            maxSize
        )
        let artworkSize = max(classicMinSize * artworkBoost, maxArtwork)
        let visualScale = isFullscreen ? classicFullscreenVisualScale : 1.0
        return artworkSize * visualScale
    }

    private static func expandedBaseVisualSize(for context: SkinContext, isFullscreen: Bool) -> CGFloat {
        let classicVisualSize = classicArtworkVisualSize(for: context, isFullscreen: isFullscreen)
        let contentSize = context.contentSize
        let absoluteCap = min(
            contentSize.width * (isFullscreen ? 0.84 : 0.68),
            contentSize.height * (isFullscreen ? 0.84 : 0.68)
        )
        return min(classicVisualSize * baseExpansionRatio, absoluteCap)
    }
}

private struct RotationProfile {
    let maxSpeed: Double
    let startTau: Double
    let stopTau: Double
}

private enum RotatingCoverDiscMode {
    case vinyl
    case cd

    var profile: RotationProfile {
        switch self {
        case .vinyl:
            return RotationProfile(
                maxSpeed: 12.0,
                startTau: 0.50,
                stopTau: 1.20
            )
        case .cd:
            return RotationProfile(
                maxSpeed: 3100.0,
                startTau: 0.40,
                stopTau: 0.68
            )
        }
    }
}

@MainActor
private final class RotatingCoverRotation: ObservableObject {
    let anglePublisher = CurrentValueSubject<Double, Never>(0)
    let speedRatioPublisher = CurrentValueSubject<Double, Never>(0)

    private var velocity: Double = 0
    private var targetVelocity: Double = 0
    private var lastTime: TimeInterval = 0
    private var motionEnabled: Bool = true
    /// App-level visibility (any window with `.visible` occlusion). While the
    /// app is fully in the background the 60Hz ticker is pure waste, so it
    /// hard-stops; resuming restarts the spin from the preserved angle.
    private var isAppVisible: Bool = true
    private var isPlaying: Bool = false
    private var timerCancellable: AnyCancellable?
    private var profile: RotationProfile = RotatingCoverDiscMode.vinyl.profile
    private var angle: Double = 0

    private let restEpsilon: Double = 0.05

    func setPlaying(_ isPlaying: Bool) {
        self.isPlaying = isPlaying
        targetVelocity = motionTargetVelocity()
        updateTickerState()
    }

    func setMode(_ mode: RotatingCoverDiscMode, isPlaying: Bool) {
        profile = mode.profile
        self.isPlaying = isPlaying
        targetVelocity = motionTargetVelocity()
        updateTickerState()
    }

    func setMotionEnabled(_ isEnabled: Bool, isPlaying: Bool) {
        self.isPlaying = isPlaying
        guard motionEnabled != isEnabled else {
            targetVelocity = motionTargetVelocity()
            updateTickerState()
            return
        }

        motionEnabled = isEnabled
        if motionEnabled {
            lastTime = 0
            targetVelocity = motionTargetVelocity()
            updateTickerState()
        } else {
            targetVelocity = 0
            velocity = 0
            lastTime = 0
            speedRatioPublisher.send(0)
            stopTicker()
        }
    }

    func setAppVisible(_ visible: Bool) {
        guard isAppVisible != visible else { return }
        isAppVisible = visible
        if visible {
            lastTime = 0
            targetVelocity = motionTargetVelocity()
        } else {
            // Hard-stop: an invisible spin-down wastes the full stopTau window.
            targetVelocity = 0
            velocity = 0
            speedRatioPublisher.send(0)
        }
        updateTickerState()
    }

    private func motionTargetVelocity() -> Double {
        (motionEnabled && isAppVisible && isPlaying) ? profile.maxSpeed : 0
    }

    func reset() {
        angle = 0
        anglePublisher.send(angle)
        velocity = 0
        targetVelocity = 0
        lastTime = 0
        speedRatioPublisher.send(0)
        stopTicker()
    }

    func suspend() {
        lastTime = 0
        stopTicker()
    }

    func tick(at date: Date) {
        guard motionEnabled else { return }

        let now = date.timeIntervalSinceReferenceDate

        // First tick init
        if lastTime == 0 {
            lastTime = now
            return
        }

        var dt = now - lastTime
        lastTime = now
        if dt > 0.1 { dt = 1.0 / 60.0 }  // Prevent jumps on resume

        let tau = targetVelocity > velocity ? profile.startTau : profile.stopTau
        let decay = exp(-dt / tau)
        velocity = targetVelocity + (velocity - targetVelocity) * decay
        if abs(velocity - targetVelocity) < restEpsilon {
            velocity = targetVelocity
        }

        if velocity == 0, targetVelocity == 0 {
            speedRatioPublisher.send(0)
            stopTicker()
            return
        }

        angle += velocity * dt

        angle.formTruncatingRemainder(dividingBy: 360)
        if angle < 0 {
            angle += 360
        }
        anglePublisher.send(angle)
        speedRatioPublisher.send(min(abs(velocity) / max(profile.maxSpeed, 0.001), 1))
    }

    private func updateTickerState() {
        guard motionEnabled else {
            stopTicker()
            return
        }

        let shouldTick = targetVelocity != 0 || abs(velocity) > restEpsilon
        if shouldTick {
            startTickerIfNeeded()
        } else {
            velocity = 0
            lastTime = 0
            stopTicker()
        }
    }

    private func startTickerIfNeeded() {
        guard timerCancellable == nil else { return }
        timerCancellable = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.tick(at: date)
            }
    }

    private func stopTicker() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }
}

@MainActor
private final class RotatingCoverCDMotionBlurCache: ObservableObject {
    @Published private(set) var blurredImage: NSImage?

    private static let blurVersion = 6
    private static let maxRenderPixelSize = 480
    private static let minRenderableDiscSize: CGFloat = 24

    private struct CacheKey: Equatable, Sendable {
        let artworkSignature: String
        let pixelSize: Int
        let version: Int
    }

    private var currentKey: CacheKey?
    private var renderTask: Task<Void, Never>?

    deinit {
        renderTask?.cancel()
    }

    func update(
        artworkImage: NSImage?,
        artworkSignature: String?,
        discSize: CGFloat,
        enabled: Bool
    ) {
        guard
            enabled,
            discSize.isFinite,
            discSize >= Self.minRenderableDiscSize,
            let artworkImage,
            let artworkSignature,
            let sourceImage = artworkImage.cgImageSnapshot()
        else {
            clear()
            return
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let quantizedSize = quantizedPixelSize(for: discSize * scale)
        guard quantizedSize > 0 else {
            clear()
            return
        }
        let pixelSize = max(min(quantizedSize, Self.maxRenderPixelSize), 96)
        let key = CacheKey(
            artworkSignature: artworkSignature,
            pixelSize: pixelSize,
            version: Self.blurVersion
        )
        let previousKey = currentKey

        guard currentKey != key else { return }
        currentKey = key

        renderTask?.cancel()
        if previousKey?.artworkSignature != key.artworkSignature {
            blurredImage = nil
        }

        let targetDiscSize = discSize
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let rendered = autoreleasepool {
                guard !Task.isCancelled else { return nil as CGImage? }
                return RotatingCoverCDMotionBlurRenderer.render(
                    sourceImage: sourceImage,
                    pixelSize: pixelSize
                )
            }
            guard !Task.isCancelled, let rendered else { return }
            await MainActor.run {
                guard let self, self.currentKey == key else { return }
                self.blurredImage = NSImage(
                    cgImage: rendered,
                    size: NSSize(width: targetDiscSize, height: targetDiscSize)
                )
            }
        }
    }

    func clear() {
        renderTask?.cancel()
        renderTask = nil
        currentKey = nil
        blurredImage = nil
    }

    private func quantizedPixelSize(for rawPixelSize: CGFloat) -> Int {
        guard rawPixelSize.isFinite, rawPixelSize > 0 else { return 0 }
        let bucket: CGFloat = 12
        return Int((rawPixelSize / bucket).rounded(.toNearestOrAwayFromZero) * bucket)
    }
}

// MARK: - CD motion blur renderer (fully nonisolated)
//
// All rendering work runs off the main actor on a detached Task. Members are
// declared `nonisolated` so the closure captured by Task.detached cannot
// inherit any actor isolation from the caller — that inheritance was the
// remaining cause of `_dispatch_assert_queue_fail` after the previous patch.
private enum RotatingCoverCDMotionBlurRenderer {
    private nonisolated static func currentCIContext() -> CIContext {
        SharedCoreImageContext.context
    }

    nonisolated private static let angularBlurRadiusDegrees: CGFloat = 180
    nonisolated private static let angularSampleStepDegrees: CGFloat = 0.75
    nonisolated private static let angularBlurAccumulationAlpha: CGFloat = 24.0

    nonisolated static func render(sourceImage: CGImage, pixelSize: Int) -> CGImage? {
        guard
            pixelSize > 1,
            sourceImage.width > 0,
            sourceImage.height > 0
        else {
            return nil
        }

        let bounds = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        let sampleOffsets = stride(
            from: -angularBlurRadiusDegrees,
            through: angularBlurRadiusDegrees,
            by: angularSampleStepDegrees
        ).map(CGFloat.init)
        let maxOffset = angularBlurRadiusDegrees
        let sampleWeights = sampleOffsets.map { angle in
            let normalizedDistance = abs(angle) / maxOffset
            return 0.62 + pow(1 - normalizedDistance, 0.55) * 0.86
        }
        let weightSum = sampleWeights.reduce(0, +)
        let drawRect = aspectFillRect(
            sourceSize: CGSize(width: sourceImage.width, height: sourceImage.height),
            targetRect: bounds
        )

        context.interpolationQuality = .high
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.addEllipse(in: CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: bounds.width, height: bounds.height))
        context.clip()

        for (index, pair) in zip(sampleOffsets, sampleWeights).enumerated() {
            if index.isMultiple(of: 8), Task.isCancelled {
                return nil
            }
            let (angle, weight) = pair
            context.saveGState()
            context.rotate(by: angle * .pi / 180)
            context.setAlpha(weight / weightSum * angularBlurAccumulationAlpha)
            context.draw(
                sourceImage,
                in: CGRect(
                    x: drawRect.origin.x - bounds.midX,
                    y: drawRect.origin.y - bounds.midY,
                    width: drawRect.width,
                    height: drawRect.height
                )
            )
            context.restoreGState()
        }
        context.restoreGState()

        guard let compositedImage = context.makeImage() else { return nil }
        guard !Task.isCancelled else { return nil }
        guard let lightlyBlurred = lightlyBlurredImage(from: compositedImage, pixelSize: pixelSize) else {
            return compositedImage
        }
        guard !Task.isCancelled else { return nil }
        return densifiedOpaqueBlurImage(from: lightlyBlurred, pixelSize: pixelSize, colorSpace: colorSpace)
    }

    nonisolated private static func lightlyBlurredImage(from image: CGImage, pixelSize: Int) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        let blurred = CIImage(cgImage: image)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4.0])
            .cropped(to: bounds)
        return currentCIContext().createCGImage(blurred, from: bounds)
    }

    nonisolated private static func densifiedOpaqueBlurImage(
        from image: CGImage,
        pixelSize: Int,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        guard let fillColor = averageFillColor(from: image, colorSpace: colorSpace) else {
            return image
        }
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.addEllipse(in: bounds)
        context.clip()
        context.setFillColor(fillColor)
        context.fill(bounds)

        // Re-composite the finished blur image over an opaque disc fill so
        // the motion layer itself covers the artwork/background instead of
        // relying on reducing the base artwork layer.
        context.setBlendMode(.normal)
        context.setAlpha(1.0)
        context.draw(image, in: bounds)
        context.setAlpha(1.0)
        context.draw(image, in: bounds)
        context.setAlpha(0.86)
        context.draw(image, in: bounds)

        return context.makeImage()
    }

    nonisolated private static func averageFillColor(
        from image: CGImage,
        colorSpace: CGColorSpace
    ) -> CGColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let didDraw = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard didDraw else { return nil }
        let alpha = max(CGFloat(pixel[3]) / 255, 0.001)
        let red = min(1, CGFloat(pixel[0]) / 255 / alpha)
        let green = min(1, CGFloat(pixel[1]) / 255 / alpha)
        let blue = min(1, CGFloat(pixel[2]) / 255 / alpha)
        return CGColor(colorSpace: colorSpace, components: [red, green, blue, 1])
    }
}

private nonisolated func aspectFillRect(sourceSize: CGSize, targetRect: CGRect) -> CGRect {
    guard
        sourceSize.width.isFinite,
        sourceSize.height.isFinite,
        sourceSize.width > 0,
        sourceSize.height > 0
    else {
        return targetRect
    }
    let scale = max(targetRect.width / sourceSize.width, targetRect.height / sourceSize.height)
    let scaledSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    return CGRect(
        x: targetRect.midX - scaledSize.width / 2,
        y: targetRect.midY - scaledSize.height / 2,
        width: scaledSize.width,
        height: scaledSize.height
    )
}

private extension NSImage {
    func cgImageSnapshot() -> CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func blurCacheSignature(trackID: UUID?, checksum: UInt64 = 0) -> String {
        if let trackID {
            return "track:\(trackID.uuidString)-art:\(checksum)-\(self.hash)"
        }
        return "size:\(Int(size.width))x\(Int(size.height))-\(self.hash)"
    }
}

/// 圆环：外圆减去同心内圆，内径按外径比例给出。
nonisolated private struct RotatingCoverRingShape: Shape {
    let innerDiameterRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect)
        let ratio = max(0, min(innerDiameterRatio, 1))
        guard ratio > 0 else { return path }
        let inset = rect.width * (1 - ratio) / 2
        path.addEllipse(in: rect.insetBy(dx: inset, dy: inset))
        return path
    }
}

private struct RotatingCoverDiscStack<DiscView: View>: View {
    let context: SkinContext
    let baseSize: CGFloat
    /// CD 中心孔径占底座直径的比例；nil 时底座为实心圆。
    let holeRatio: CGFloat?
    let discView: DiscView

    init(
        context: SkinContext,
        baseSize: CGFloat,
        holeRatio: CGFloat? = nil,
        @ViewBuilder discView: () -> DiscView
    ) {
        self.context = context
        self.baseSize = baseSize
        self.holeRatio = holeRatio
        self.discView = discView()
    }

    var body: some View {
        ZStack(alignment: .center) {
            glassBase

            discView
                .frame(width: baseSize, height: baseSize, alignment: .center)
        }
        .frame(width: baseSize, height: baseSize, alignment: .center)
    }

    @ViewBuilder
    private var glassBase: some View {
        let glass = Circle()
            .frame(width: baseSize, height: baseSize)
            .liquidGlassCircle(
                colorScheme: context.theme.colorScheme,
                isFloating: false
            )
        if let holeRatio, holeRatio > 0 {
            let holeSize = baseSize * holeRatio
            glass
                .mask {
                    RotatingCoverRingShape(innerDiameterRatio: holeRatio)
                        .fill(style: FillStyle(eoFill: true))
                }
                .overlay {
                    Circle()
                        .strokeBorder(
                            GlassStyleTokens.glassBorderColor(for: context.theme.colorScheme),
                            lineWidth: GlassStyleTokens.hairlineWidth
                        )
                        .frame(width: holeSize, height: holeSize)
                        .allowsHitTesting(false)
                }
        } else {
            glass
        }
    }
}

private struct RotatingDiscLayerView<Content: View>: NSViewRepresentable {
    let rotation: RotatingCoverRotation
    let baseSize: CGFloat
    let discSize: CGFloat
    let rasterizesContent: Bool
    let content: Content

    init(
        rotation: RotatingCoverRotation,
        baseSize: CGFloat,
        discSize: CGFloat,
        rasterizesContent: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.rotation = rotation
        self.baseSize = baseSize
        self.discSize = discSize
        self.rasterizesContent = rasterizesContent
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rotation: rotation)
    }

    func makeNSView(context: Context) -> RotatingDiscHostView<Content> {
        let view = RotatingDiscHostView(rootView: content, discSize: discSize, rasterizesContent: rasterizesContent)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: RotatingDiscHostView<Content>, context: Context) {
        nsView.setRootView(content)
        nsView.updateDiscSize(discSize, rasterizesContent: rasterizesContent)
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: RotatingDiscHostView<Content>, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private let rotation: RotatingCoverRotation
        private var angleCancellable: AnyCancellable?
        private weak var hostView: RotatingDiscHostView<Content>?

        init(rotation: RotatingCoverRotation) {
            self.rotation = rotation
        }

        func attach(to view: RotatingDiscHostView<Content>) {
            guard hostView !== view else { return }
            hostView = view
            angleCancellable?.cancel()
            angleCancellable = rotation.anglePublisher
                .sink { [weak view] angle in
                    view?.setRotationAngle(angle)
                }
        }

        func detach() {
            angleCancellable?.cancel()
            angleCancellable = nil
            hostView = nil
        }
    }
}

private final class RotatingDiscHostView<Content: View>: NSView {
    private let hostingView: NSHostingView<Content>
    private let widthConstraint: NSLayoutConstraint
    private let heightConstraint: NSLayoutConstraint

    init(rootView: Content, discSize: CGFloat, rasterizesContent: Bool) {
        hostingView = NSHostingView(rootView: rootView)
        let safeDiscSize = Self.sanitizedDiscSize(discSize)
        widthConstraint = hostingView.widthAnchor.constraint(equalToConstant: safeDiscSize)
        heightConstraint = hostingView.heightAnchor.constraint(equalToConstant: safeDiscSize)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        hostingView.layer?.shouldRasterize = rasterizesContent
        hostingView.layer?.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2

        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.centerXAnchor.constraint(equalTo: centerXAnchor),
            hostingView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthConstraint,
            heightConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRootView(_ rootView: Content) {
        hostingView.rootView = rootView
    }

    func updateDiscSize(_ discSize: CGFloat, rasterizesContent: Bool) {
        let safeDiscSize = Self.sanitizedDiscSize(discSize)
        widthConstraint.constant = safeDiscSize
        heightConstraint.constant = safeDiscSize
        hostingView.layer?.shouldRasterize = rasterizesContent
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateRotationAnchor()
    }

    func setRotationAngle(_ angle: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateRotationAnchor()
        hostingView.layer?.transform = CATransform3DMakeRotation(CGFloat(-angle * .pi / 180), 0, 0, 1)
        CATransaction.commit()
    }

    private func updateRotationAnchor() {
        guard let layer = hostingView.layer else { return }
        let position = CGPoint(x: bounds.midX, y: bounds.midY)
        guard position.x.isFinite, position.y.isFinite else { return }
        if layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
        if layer.position != position {
            layer.position = position
        }
    }

    private static func sanitizedDiscSize(_ discSize: CGFloat) -> CGFloat {
        guard discSize.isFinite, discSize > 0 else { return 0 }
        return discSize
    }
}

private enum RotatingCoverCDHubRenderer {
    struct HubImages {
        let crisp: CGImage
        let blurred: CGImage
    }

    static func formatMatrixText(title: String, artist: String, album: String) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        var parts: [String] = []
        if !cleanTitle.isEmpty { parts.append(cleanTitle) }
        if !cleanArtist.isEmpty { parts.append(cleanArtist) }
        if !cleanAlbum.isEmpty && cleanAlbum != cleanTitle { parts.append(cleanAlbum) }
        parts.append("COMPACT DISC DIGITAL AUDIO")

        return parts.joined(separator: "  •  ") + "  •  "
    }

    static func renderHubImages(
        baseSize: CGFloat,
        holeRatio: CGFloat,
        labelInnerRatio: CGFloat,
        title: String,
        artist: String,
        album: String,
        scale: CGFloat
    ) -> HubImages? {
        guard let crisp = renderHubImage(
            baseSize: baseSize,
            holeRatio: holeRatio,
            labelInnerRatio: labelInnerRatio,
            title: title,
            artist: artist,
            album: album,
            scale: scale
        ) else {
            return nil
        }

        let pixelSize = max(16, Int((baseSize * scale).rounded()))
        let blurred = renderBlurredHub(from: crisp, pixelSize: pixelSize) ?? crisp
        return HubImages(crisp: crisp, blurred: blurred)
    }

    static func renderHubImage(
        baseSize: CGFloat,
        holeRatio: CGFloat,
        labelInnerRatio: CGFloat,
        title: String,
        artist: String,
        album: String,
        scale: CGFloat
    ) -> CGImage? {
        guard baseSize.isFinite, baseSize > 10 else { return nil }

        let pixelSize = max(16, Int((baseSize * scale).rounded()))
        guard pixelSize > 0 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelSize,
                  height: pixelSize,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        let nsCtx = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let center = CGPoint(x: CGFloat(pixelSize) / 2, y: CGFloat(pixelSize) / 2)
        let s = scale

        // Radii in pixels
        let holeRadius = (baseSize * holeRatio / 2) * s
        let labelInnerRadius = (baseSize * labelInnerRatio / 2) * s
        guard labelInnerRadius > holeRadius + 4 else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }

        // 1. Spindle hole rim (transparent inside, fine highlight ring on rim)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.24).cgColor)
        context.setLineWidth(1.0 * s)
        context.addEllipse(in: CGRect(
            x: center.x - holeRadius,
            y: center.y - holeRadius,
            width: holeRadius * 2,
            height: holeRadius * 2
        ))
        context.strokePath()

        // 2. Clamping ring (堆叠环 / 模具成型环)
        let clampInnerRadius = holeRadius + (labelInnerRadius - holeRadius) * 0.26
        let clampOuterRadius = holeRadius + (labelInnerRadius - holeRadius) * 0.38

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        context.setLineWidth(0.75 * s)
        context.addEllipse(in: CGRect(
            x: center.x - clampInnerRadius,
            y: center.y - clampInnerRadius,
            width: clampInnerRadius * 2,
            height: clampInnerRadius * 2
        ))
        context.strokePath()

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        context.setLineWidth(0.5 * s)
        context.addEllipse(in: CGRect(
            x: center.x - clampOuterRadius,
            y: center.y - clampOuterRadius,
            width: clampOuterRadius * 2,
            height: clampOuterRadius * 2
        ))
        context.strokePath()

        // 3. Mirror band boundary grooves (just inside the artwork label edge)
        let grooveRadius = labelInnerRadius - 4 * s
        let grooveRadius2 = labelInnerRadius - 1.5 * s

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        context.setLineWidth(0.75 * s)
        context.addEllipse(in: CGRect(
            x: center.x - grooveRadius,
            y: center.y - grooveRadius,
            width: grooveRadius * 2,
            height: grooveRadius * 2
        ))
        context.strokePath()

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        context.setLineWidth(0.5 * s)
        context.addEllipse(in: CGRect(
            x: center.x - grooveRadius2,
            y: center.y - grooveRadius2,
            width: grooveRadius2 * 2,
            height: grooveRadius2 * 2
        ))
        context.strokePath()

        // 4. Circular matrix text
        let textRadius = (clampOuterRadius + grooveRadius) / 2
        let textCircumference = 2 * CGFloat.pi * textRadius
        let fontSize = max(5.5, min(8.0, baseSize * 0.018)) * s
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.34)
        ]

        let baseText = formatMatrixText(title: title, artist: artist, album: album)
        drawCircularText(
            in: context,
            baseText: baseText,
            center: center,
            radius: textRadius,
            circumference: textCircumference,
            font: font,
            attributes: attrs
        )

        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func drawCircularText(
        in context: CGContext,
        baseText: String,
        center: CGPoint,
        radius: CGFloat,
        circumference: CGFloat,
        font: NSFont,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let baseWidth = (baseText as NSString).size(withAttributes: attributes).width
        guard baseWidth > 0, circumference > 0 else { return }

        var fullString = baseText
        while (fullString as NSString).size(withAttributes: attributes).width + baseWidth <= circumference {
            fullString += baseText
        }

        let totalTextWidth = (fullString as NSString).size(withAttributes: attributes).width
        let extraSpacing = (circumference - totalTextWidth) / CGFloat(fullString.count)

        var currentAngle: CGFloat = 0
        let capHeight = font.capHeight

        for c in fullString {
            let str = String(c) as NSString
            let charWidth = str.size(withAttributes: attributes).width
            let adv = charWidth + extraSpacing
            let angleDelta = adv / radius
            let midAngle = currentAngle + angleDelta / 2

            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: -midAngle)
            context.translateBy(x: 0, y: radius)

            let point = CGPoint(x: -charWidth / 2, y: -capHeight / 2)
            str.draw(at: point, withAttributes: attributes)

            context.restoreGState()
            currentAngle += angleDelta
        }
    }

    private static func renderBlurredHub(from crisp: CGImage, pixelSize: Int) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelSize,
                  height: pixelSize,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        let bounds = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        let sampleOffsets = stride(from: CGFloat(-24), through: CGFloat(24), by: CGFloat(1.5)).map { $0 }
        let maxOffset: CGFloat = 24.0
        let sampleWeights = sampleOffsets.map { angle in
            let norm = abs(angle) / maxOffset
            return 0.55 + pow(1 - norm, 0.6) * 0.85
        }
        let weightSum = sampleWeights.reduce(0, +)

        context.interpolationQuality = .high
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)

        let drawRect = CGRect(
            x: -bounds.width / 2,
            y: -bounds.height / 2,
            width: bounds.width,
            height: bounds.height
        )

        for (angle, weight) in zip(sampleOffsets, sampleWeights) {
            context.saveGState()
            context.rotate(by: angle * .pi / 180)
            context.setAlpha(weight / weightSum * 1.8)
            context.draw(crisp, in: drawRect)
            context.restoreGState()
        }
        context.restoreGState()

        return context.makeImage()
    }
}

private struct RotatingCDDiscLayerView: NSViewRepresentable {
    let rotation: RotatingCoverRotation
    let baseSize: CGFloat
    let discSize: CGFloat
    let artworkImage: NSImage?
    let blurredImage: NSImage?
    let trackTitle: String
    let artistName: String
    let albumName: String

    func makeCoordinator() -> Coordinator {
        Coordinator(rotation: rotation)
    }

    private var labelInnerDiameter: CGFloat {
        baseSize * RotatingCoverLayout.cdLabelInnerToBaseRatio
    }

    private var holeDiameter: CGFloat {
        baseSize * RotatingCoverLayout.cdHoleToBaseRatio
    }

    func makeNSView(context: Context) -> RotatingCDDiscHostView {
        let view = RotatingCDDiscHostView()
        view.updateGeometry(
            baseSize: baseSize,
            discSize: discSize,
            labelInnerDiameter: labelInnerDiameter,
            holeDiameter: holeDiameter
        )
        view.updateTrackMetadata(title: trackTitle, artist: artistName, album: albumName)
        view.updateImages(artworkImage: artworkImage, blurredImage: blurredImage)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: RotatingCDDiscHostView, context: Context) {
        nsView.updateGeometry(
            baseSize: baseSize,
            discSize: discSize,
            labelInnerDiameter: labelInnerDiameter,
            holeDiameter: holeDiameter
        )
        nsView.updateTrackMetadata(title: trackTitle, artist: artistName, album: albumName)
        nsView.updateImages(artworkImage: artworkImage, blurredImage: blurredImage)
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: RotatingCDDiscHostView, coordinator: Coordinator) {
        coordinator.detach()
        nsView.dismantle()
    }

    final class Coordinator {
        private let rotation: RotatingCoverRotation
        private var angleCancellable: AnyCancellable?
        private var speedCancellable: AnyCancellable?
        private weak var hostView: RotatingCDDiscHostView?

        init(rotation: RotatingCoverRotation) {
            self.rotation = rotation
        }

        func attach(to view: RotatingCDDiscHostView) {
            guard hostView !== view else { return }
            hostView = view
            angleCancellable?.cancel()
            speedCancellable?.cancel()

            angleCancellable = rotation.anglePublisher
                .sink { [weak view] angle in
                    view?.setRotationAngle(angle)
                }

            speedCancellable = rotation.speedRatioPublisher
                .sink { [weak view] ratio in
                    view?.setBlurStrength(ratio)
                }

            view.setRotationAngle(rotation.anglePublisher.value)
            view.setBlurStrength(rotation.speedRatioPublisher.value)
        }

        func detach() {
            angleCancellable?.cancel()
            angleCancellable = nil
            speedCancellable?.cancel()
            speedCancellable = nil
            hostView = nil
        }
    }
}

private final class RotatingCDDiscHostView: NSView {
    private let discRootLayer = CALayer()
    private let artworkContainerLayer = CALayer()
    private let blurLayer = CALayer()
    private let artworkLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private let artworkMaskLayer = CAShapeLayer()
    private let hubCrispLayer = CALayer()
    private let hubBlurLayer = CALayer()

    private var baseSize: CGFloat = 0
    private var discSize: CGFloat = 0
    private var labelInnerDiameter: CGFloat = 0
    private var holeDiameter: CGFloat = 0
    private var currentBlurCoverage: Float = 0

    private struct HubKey: Equatable {
        let baseSize: CGFloat
        let title: String
        let artist: String
        let album: String
        let scale: CGFloat
    }
    private var currentHubKey: HubKey?
    private var trackTitle: String = ""
    private var artistName: String = ""
    private var albumName: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(discRootLayer)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        discRootLayer.masksToBounds = false
        discRootLayer.contentsScale = scale

        artworkContainerLayer.masksToBounds = false
        artworkMaskLayer.fillRule = .evenOdd
        artworkMaskLayer.fillColor = NSColor.black.cgColor
        artworkContainerLayer.mask = artworkMaskLayer

        blurLayer.contentsGravity = .resizeAspectFill
        blurLayer.masksToBounds = true
        blurLayer.isOpaque = true
        blurLayer.opacity = 0
        blurLayer.minificationFilter = .trilinear
        blurLayer.magnificationFilter = .trilinear

        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.masksToBounds = true
        artworkLayer.isOpaque = true
        artworkLayer.minificationFilter = .trilinear
        artworkLayer.magnificationFilter = .trilinear

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        borderLayer.lineWidth = 1

        artworkContainerLayer.addSublayer(artworkLayer)
        artworkContainerLayer.addSublayer(blurLayer)
        artworkContainerLayer.addSublayer(borderLayer)

        hubCrispLayer.contentsGravity = .resizeAspectFill
        hubCrispLayer.masksToBounds = false
        hubCrispLayer.contentsScale = scale
        hubCrispLayer.opacity = 1.0

        hubBlurLayer.contentsGravity = .resizeAspectFill
        hubBlurLayer.masksToBounds = false
        hubBlurLayer.contentsScale = scale
        hubBlurLayer.opacity = 0.0

        discRootLayer.addSublayer(artworkContainerLayer)
        discRootLayer.addSublayer(hubCrispLayer)
        discRootLayer.addSublayer(hubBlurLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard discSize.isFinite, discSize > 1, baseSize.isFinite, baseSize > 1 else {
            discRootLayer.bounds = .zero
            artworkContainerLayer.frame = .zero
            blurLayer.frame = .zero
            artworkLayer.frame = .zero
            borderLayer.frame = .zero
            borderLayer.path = nil
            artworkMaskLayer.frame = .zero
            artworkMaskLayer.path = nil
            hubCrispLayer.frame = .zero
            hubBlurLayer.frame = .zero
            return
        }

        let baseBounds = CGRect(origin: .zero, size: CGSize(width: baseSize, height: baseSize))
        let discBounds = CGRect(origin: .zero, size: CGSize(width: discSize, height: discSize))
        discRootLayer.bounds = baseBounds

        artworkContainerLayer.bounds = discBounds
        artworkContainerLayer.position = CGPoint(x: baseBounds.midX, y: baseBounds.midY)
        blurLayer.frame = discBounds
        artworkLayer.frame = discBounds
        blurLayer.cornerRadius = discBounds.width / 2
        artworkLayer.cornerRadius = discBounds.width / 2

        // 封面只占外环；内径以内露出底座的透明盘心。
        let innerDiameter = min(labelInnerDiameter, discSize)
        let innerInset = (discSize - innerDiameter) / 2
        let innerBounds = discBounds.insetBy(dx: innerInset, dy: innerInset)
        let ringPath = CGMutablePath()
        ringPath.addEllipse(in: discBounds)
        let borderPath = CGMutablePath()
        borderPath.addEllipse(in: discBounds.insetBy(dx: 0.5, dy: 0.5))
        if innerDiameter > 1 {
            ringPath.addEllipse(in: innerBounds)
            borderPath.addEllipse(in: innerBounds.insetBy(dx: -0.5, dy: -0.5))
        }
        artworkMaskLayer.frame = discBounds
        artworkMaskLayer.path = ringPath
        borderLayer.frame = discBounds
        borderLayer.path = borderPath

        hubCrispLayer.frame = baseBounds
        hubBlurLayer.frame = baseBounds

        updateRotationAnchor()
        updateHubImageIfNeeded()
    }

    func updateGeometry(
        baseSize: CGFloat,
        discSize: CGFloat,
        labelInnerDiameter: CGFloat,
        holeDiameter: CGFloat
    ) {
        self.baseSize = baseSize.isFinite && baseSize > 0 ? baseSize : 0
        self.discSize = discSize.isFinite && discSize > 0 ? discSize : 0
        self.labelInnerDiameter = labelInnerDiameter.isFinite && labelInnerDiameter > 0 ? labelInnerDiameter : 0
        self.holeDiameter = holeDiameter.isFinite && holeDiameter > 0 ? holeDiameter : 0
        needsLayout = true
    }

    func updateTrackMetadata(title: String, artist: String, album: String) {
        if trackTitle != title || artistName != artist || albumName != album {
            trackTitle = title
            artistName = artist
            albumName = album
            currentHubKey = nil
            updateHubImageIfNeeded()
        }
    }

    private func updateHubImageIfNeeded() {
        guard baseSize > 10 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = HubKey(
            baseSize: baseSize,
            title: trackTitle,
            artist: artistName,
            album: albumName,
            scale: scale
        )
        guard currentHubKey != key else { return }
        currentHubKey = key

        let images = RotatingCoverCDHubRenderer.renderHubImages(
            baseSize: baseSize,
            holeRatio: RotatingCoverLayout.cdHoleToBaseRatio,
            labelInnerRatio: RotatingCoverLayout.cdLabelInnerToBaseRatio,
            title: trackTitle,
            artist: artistName,
            album: albumName,
            scale: scale
        )
        hubCrispLayer.contents = images?.crisp
        hubCrispLayer.contentsScale = scale
        hubBlurLayer.contents = images?.blurred
        hubBlurLayer.contentsScale = scale
    }

    func updateImages(artworkImage: NSImage?, blurredImage: NSImage?) {
        if let artworkImage {
            artworkLayer.contents = artworkImage.cgImageSnapshot()
        } else {
            artworkLayer.contents = nil
        }
        artworkLayer.opacity = 1
        blurLayer.contents = blurredImage?.cgImageSnapshot()
        blurLayer.isHidden = (blurredImage == nil)
        if blurredImage == nil {
            blurLayer.opacity = 0
        } else {
            blurLayer.opacity = currentBlurCoverage
        }
    }

    func dismantle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        discRootLayer.removeAllAnimations()
        blurLayer.removeAllAnimations()
        artworkLayer.removeAllAnimations()
        borderLayer.removeAllAnimations()
        hubCrispLayer.removeAllAnimations()
        hubBlurLayer.removeAllAnimations()
        blurLayer.contents = nil
        artworkLayer.contents = nil
        hubCrispLayer.contents = nil
        hubBlurLayer.contents = nil
        blurLayer.opacity = 0
        currentHubKey = nil
        CATransaction.commit()
    }

    func setRotationAngle(_ angle: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateRotationAnchor()
        discRootLayer.transform = CATransform3DMakeRotation(CGFloat(-angle * .pi / 180), 0, 0, 1)
        CATransaction.commit()
    }

    func setBlurStrength(_ ratio: Double) {
        // Smooth fade with no cutoff. At playback speed the CD blur layer is
        // fully opaque; the base artwork layer must remain opaque too.
        let clamped = max(0, min(ratio, 1))
        let smoothed = clamped * clamped * (3 - 2 * clamped)
        let baseCoverage = smoothed > 0 ? pow(smoothed, 0.16) : 0
        let coverage: Double
        if smoothed > 0.20 {
            coverage = 1.0
        } else if smoothed > 0.04 {
            coverage = max(baseCoverage, 0.96)
        } else {
            coverage = baseCoverage
        }
        currentBlurCoverage = Float(coverage)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if blurLayer.contents != nil {
            blurLayer.opacity = currentBlurCoverage
        } else {
            blurLayer.opacity = 0
        }
        artworkLayer.opacity = 1
        hubBlurLayer.opacity = currentBlurCoverage
        hubCrispLayer.opacity = 1.0 - currentBlurCoverage
        CATransaction.commit()
    }

    private func updateRotationAnchor() {
        let position = CGPoint(x: bounds.midX, y: bounds.midY)
        guard position.x.isFinite, position.y.isFinite else { return }
        if discRootLayer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            discRootLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
        if discRootLayer.position != position {
            discRootLayer.position = position
        }
    }
}

struct SkinRotatingDiscPart: View {
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration
    var body: some View {
        GeometryReader { proxy in
            RotatingCoverArtwork(context: snapshot.context.withComponentBounds(proxy.size))
                .environment(\.skinComponentConfiguration, .init(values: configuration.values.merging(["visualizerMode": .text("off"), "fillsFrame": .boolean(true)]) { _, new in new }))
        }
    }
}

private struct RotatingCoverArtwork: View {
    let context: SkinContext
    @Environment(\.skinSceneIsActive) private var skinSceneIsActive
    @StateObject private var rotation = RotatingCoverRotation()
    @StateObject private var cdMotionBlurCache = RotatingCoverCDMotionBlurCache()

    private let windowCoverScaleEffect: CGFloat = 1.08

    @AppStorage("skin.rotatingCover.cdMode") private var savedCDMode: Bool = true
    @Environment(\.skinComponentConfiguration) private var componentConfiguration
    private var cdMode: Bool { componentConfiguration.boolean("cdMode", fallback: savedCDMode) }
    @AppStorage("skin.rotatingCover.visualizerMode") private var normalVisualizerMode: String = "off"
    @AppStorage("skin.rotatingCover.fullscreen.visualizerMode") private var fullscreenVisualizerMode: String = "led"

    @State private var lastTrackID: UUID? = nil

    private var discMode: RotatingCoverDiscMode {
        cdMode ? .cd : .vinyl
    }

    private var currentArtworkImage: NSImage? {
        guard let track = context.track else { return nil }
        if let displayedArtworkID = track.displayedArtworkID, displayedArtworkID != track.id {
            return nil
        }
        return track.artworkImage
    }

    private var artworkSignature: String? {
        guard let track = context.track, let image = currentArtworkImage else { return nil }
        return image.blurCacheSignature(trackID: track.id, checksum: track.artworkChecksum)
    }

    var body: some View {
        let usesFullscreenLayout = context.usesFullscreenPlayerLayout
        let fillsFrame = componentConfiguration.boolean("fillsFrame", fallback: false)
        let side = min(context.contentSize.width, context.contentSize.height)
        let discRatio = discMode == .cd
            ? RotatingCoverLayout.cdDiscToBaseRatio
            : RotatingCoverLayout.discToBaseRatio
        let layout = fillsFrame
            ? RotatingCoverLayout.Metrics(discSize: side * discRatio, baseSize: side, xOffset: 0, yOffset: 0)
            : RotatingCoverLayout.metrics(for: context, isFullscreen: usesFullscreenLayout, discRatio: discRatio)
        let visualizerMode = componentConfiguration.text("visualizerMode", fallback: usesFullscreenLayout ? fullscreenVisualizerMode : normalVisualizerMode)
        let motionEnabled = context.motionPolicy == .full

        VStack(spacing: 32) {
            RotatingCoverDiscStack(
                context: context,
                baseSize: layout.baseSize,
                holeRatio: discMode == .cd ? RotatingCoverLayout.cdHoleToBaseRatio : nil
            ) {
                if discMode == .cd {
                    RotatingCDDiscLayerView(
                        rotation: rotation,
                        baseSize: layout.baseSize,
                        discSize: layout.discSize,
                        artworkImage: currentArtworkImage,
                        blurredImage: cdMotionBlurCache.blurredImage,
                        trackTitle: context.track?.title ?? "",
                        artistName: context.track?.artist ?? "",
                        albumName: context.track?.album ?? ""
                    )
                    .frame(width: layout.baseSize, height: layout.baseSize)
                } else {
                    RotatingDiscLayerView(
                        rotation: rotation,
                        baseSize: layout.baseSize,
                        discSize: layout.discSize,
                        rasterizesContent: true
                    ) {
                        artworkView(size: layout.discSize)
                    }
                    .frame(width: layout.baseSize, height: layout.baseSize)
                }
            }
            .motionArtworkFullscreenSource(
                context: context,
                cornerRadius: layout.baseSize * 0.5,
                insetScale: 0.90,
                handoffStyle: .maskedCrossfade
            )

            if visualizerMode == "led" {
                let usesFullscreen = usesFullscreenLayout
                LiveLedMeterView(
                    dotSize: usesFullscreen ? 16 : 14,
                    spacing: usesFullscreen ? 10 : 8,
                    pillTint: context.theme.artworkAccentColor,
                    isPlaying: context.playback.isPlaying,
                    forceBrightLEDColors: context.theme.artBackgroundIsUltraDark,
                    levelToneVariant: .skinLight
                )
            } else if visualizerMode == "spectrum" {
                PillSpectrumView(
                    context: context,
                    dotSize: 12,
                    spacing: 8,
                    pillTint: context.theme.artworkAccentColor,
                    isFullscreen: usesFullscreenLayout
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(usesFullscreenLayout || fillsFrame ? 1.0 : windowCoverScaleEffect)
        .offset(x: layout.xOffset, y: layout.yOffset)
        .onAppear {
            lastTrackID = context.track?.id
            rotation.setMode(discMode, isPlaying: context.playback.isPlaying)
            rotation.setMotionEnabled(motionEnabled, isPlaying: context.playback.isPlaying)
            updateCDMotionBlurCache(discSize: layout.discSize)
        }
        .onChange(of: context.playback.isPlaying) { _, isPlaying in
            rotation.setPlaying(isPlaying)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
        ) { _ in
            // Background playback: hard-stop the 60Hz ticker while no window
            // is actually visible (app hidden / covered / miniaturized).
            rotation.setAppVisible(
                NSApp.windows.contains { $0.occlusionState.contains(.visible) }
            )
        }
        .onChange(of: cdMode) { _, _ in
            rotation.setMode(discMode, isPlaying: context.playback.isPlaying)
            updateCDMotionBlurCache(discSize: layout.discSize)
        }
        .onChange(of: motionEnabled) { _, isEnabled in
            rotation.setMotionEnabled(isEnabled, isPlaying: context.playback.isPlaying)
        }
        .onChange(of: Int(layout.discSize.rounded())) { _, _ in
            updateCDMotionBlurCache(discSize: layout.discSize)
        }
        .onChange(of: artworkSignature) { _, _ in
            updateCDMotionBlurCache(discSize: layout.discSize)
        }
        .onChange(of: currentArtworkImage) { _, _ in
            updateCDMotionBlurCache(discSize: layout.discSize)
        }
        .onChange(of: context.track?.displayedArtworkID) { _, _ in
            updateCDMotionBlurCache(discSize: layout.discSize)
        }
        .onChange(of: context.track?.preferredMotionArtwork) { _, _ in
            updateCDMotionBlurCache(discSize: layout.discSize)
        }
        .onChange(of: context.track?.id) { _, newID in
            if newID != lastTrackID {
                lastTrackID = newID
                cdMotionBlurCache.clear()
                rotation.reset()
                rotation.setMode(discMode, isPlaying: context.playback.isPlaying)
                updateCDMotionBlurCache(discSize: layout.discSize)
            }
        }
        .onDisappear {
            rotation.suspend()
            cdMotionBlurCache.clear()
        }
    }

    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        Group {
            if let image = currentArtworkImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ArtworkPlaceholderView.nowPlaying(size: size, cornerRadius: 0, isCircle: true)
            }
        }
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func updateCDMotionBlurCache(discSize: CGFloat) {
        cdMotionBlurCache.update(
            artworkImage: currentArtworkImage,
            artworkSignature: artworkSignature,
            discSize: discSize,
            enabled: discMode == .cd
        )
    }
}
private struct RotatingCoverSkinNormalSettingsView: View {
    @AppStorage("skin.rotatingCover.cdMode") private var cdMode: Bool = true
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @State private var visualizationPreferences = AudioVisualizationPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSwitchRow(title: "CD 模式", isOn: $cdMode)

            AudioVisualizationSelectorRow(
                title: "音频可视化",
                selection: Binding(
                    get: {
                        visualizationPreferences.selection(
                            for: RotatingCoverSkin.id,
                            scope: .window
                        ).skinKind
                    },
                    set: { kind in
                        visualizationPreferences.setSkinKind(kind, for: RotatingCoverSkin.id, scope: .window)
                        if kind != .led { ledMeterProvider.releaseNowPlayingResources() }
                    }
                )
            )
        }
    }
}

private struct RotatingCoverSkinFullscreenSettingsView: View {
    @AppStorage("skin.rotatingCover.cdMode") private var cdMode: Bool = true
    @AppStorage("fullscreenArtBackgroundEnabled") private var fullscreenArtBackgroundEnabled: Bool = true
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            SettingsSwitchRow(
                title: "启用艺术背景",
                isOn: $fullscreenArtBackgroundEnabled,
                titleFont: presentationStyle.rowLabelFont,
                titleColor: presentationStyle.settingsPrimaryTextColor(appColors: appColors)
            )

            SettingsSwitchRow(
                title: "CD 模式",
                isOn: $cdMode,
                titleFont: presentationStyle.rowLabelFont,
                titleColor: presentationStyle.settingsPrimaryTextColor(appColors: appColors)
            )

            AudioVisualizationSelectorRow(
                title: "音频可视化",
                selection: Binding(
                    get: { FullscreenPresentationCoordinator.shared.skinVisualizerKind },
                    set: { FullscreenPresentationCoordinator.shared.setSkinVisualizer($0) }
                )
            )
        }
    }
}

private struct PillSpectrumView: View {
    let context: SkinContext
    let dotSize: CGFloat
    let spacing: CGFloat
    let pillTint: Color?
    let isFullscreen: Bool
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(SkinSpectrumBandCount.storageKey)
    private var storedBandCount = SkinSpectrumBandCount.defaultValue
    private var bandCount: Int { SkinSpectrumBandCount.clamped(storedBandCount) }
    private var capsuleCount: CGFloat { CGFloat(bandCount) }
    private let capsuleWidth: CGFloat = 7
    // Keep the capsule size unchanged while tightening the gaps so the
    // spectrum reads as one continuous waveform.
    private let capsuleSpacing: CGFloat = 4
    private let horizontalPadding: CGFloat = 28
    private let contentHeight: CGFloat = 36  // Spectrum bars height
    private let pillContentHeight: CGFloat = 52  // Glass pill height, independent of the bars
    private var verticalPadding: CGFloat {
        isFullscreen ? 1 : 2  // Fullscreen shell gets one final compacting pass
    }

    private var contentWidth: CGFloat {
        capsuleCount * capsuleWidth + (capsuleCount - 1) * capsuleSpacing
    }

    private var backgroundWidth: CGFloat {
        contentWidth + horizontalPadding * 2
    }

    private var backgroundHeight: CGFloat {
        pillContentHeight + verticalPadding * 2
    }

    var body: some View {
        PillSpectrumContainer(
            isPlaying: context.playback.isPlaying,
            usesDarkForeground: context.theme.spectrumUsesDarkForeground,
            // App light mode: darken fill + give the outline its own milder dark
            // treatment so the in-skin spectrum reads against the light glass.
            lightModeDarkening: colorScheme == .light,
            artworkColors: context.theme.spectrumArtworkColors,
            artworkAccentColor: NSColor(pillTint ?? .white),
            capsuleWidth: capsuleWidth,
            capsuleSpacing: capsuleSpacing,
            bandCount: bandCount
        )
        .frame(width: contentWidth, height: contentHeight)
        .background(
            Capsule()
                .fill(Color.clear)
                .frame(width: backgroundWidth, height: backgroundHeight)
                .liquidGlassPill(
                    colorScheme: colorScheme,
                    accentColor: pillTint,
                    prominence: pillTint != nil ? .prominent : .standard,
                    isFloating: false
                )
        )
    }
}

private struct PillSpectrumContainer: NSViewRepresentable {

    let isPlaying: Bool
    let usesDarkForeground: Bool
    var lightModeDarkening: Bool = false
    let artworkColors: [NSColor]
    let artworkAccentColor: NSColor
    let capsuleWidth: CGFloat
    let capsuleSpacing: CGFloat
    let bandCount: Int

    func makeNSView(context: Context) -> CapsuleSpectrumHostView {
        let view = CapsuleSpectrumHostView(configuration: makeConfiguration())
        applyColors(to: view)
        view.start()
        view.setPlayback(isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ nsView: CapsuleSpectrumHostView, context: Context) {
        let newHash = currentIdentityHash
        if nsView.pillSpectrumIdentityHash == newHash { return }
        nsView.pillSpectrumIdentityHash = newHash
        nsView.configure(makeConfiguration())
        applyColors(to: nsView)
        nsView.setPlayback(isPlaying: isPlaying)
    }

    static func dismantleNSView(_ nsView: CapsuleSpectrumHostView, coordinator: ()) {
        nsView.stop()
    }

    private var currentIdentityHash: Int {
        var hasher = Hasher()
        hasher.combine(isPlaying)
        hasher.combine(usesDarkForeground)
        hasher.combine(lightModeDarkening)
        hasher.combine(capsuleWidth)
        hasher.combine(capsuleSpacing)
        hasher.combine(bandCount)
        hasher.combine(SpectrumColorResolver.colorSignature(
            artworkColors: artworkColors,
            accentColor: artworkAccentColor,
            usesDarkForeground: usesDarkForeground,
            lightModeDarkening: lightModeDarkening,
            capsuleCount: bandCount
        ))
        return hasher.finalize()
    }

    private func makeConfiguration() -> CapsuleSpectrumConfiguration {
        .centeredBars(
            capsuleCount: bandCount,
            capsuleWidth: capsuleWidth,
            capsuleSpacing: capsuleSpacing,
            strokeWidth: 0.5,
            usesExactBands: true
        )
    }

    private func applyColors(to view: CapsuleSpectrumHostView) {
        let signature = SpectrumColorResolver.colorSignature(
            artworkColors: artworkColors,
            accentColor: artworkAccentColor,
            usesDarkForeground: usesDarkForeground,
            lightModeDarkening: lightModeDarkening,
            capsuleCount: bandCount
        )
        view.updateColors(signature: signature) {
            let resolved = SpectrumColorResolver.resolveArtworkFaithfulColors(
                from: artworkColors,
                fallback: artworkAccentColor,
                usesDarkForeground: usesDarkForeground,
                lightModeDarkening: lightModeDarkening,
                capsuleCount: bandCount
            )
            return (resolved.fillColors, resolved.strokeColors)
        }
    }
}
