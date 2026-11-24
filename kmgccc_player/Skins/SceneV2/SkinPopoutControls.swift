import AppKit
import MotionKit
import SwiftUI

// MARK: - Playback order labels

/// Titles and symbols of the playback orders, shared by the player menu and the mode stack.
enum SkinPlaybackOrderLabels {
    /// The order the mini player's mode slider uses.
    static let localModes: [PlaybackOrderMode] = [.shuffle, .sequence, .repeatOne, .stopAfterTrack]
    static let externalModes: [AppleMusicPlaybackMode] = [.sequence, .shuffle, .repeatAll, .repeatOne]

    static func title(_ mode: PlaybackOrderMode) -> String {
        switch mode {
        case .shuffle: "随机播放"
        case .sequence: "顺序播放"
        case .repeatOne: "单曲循环"
        case .stopAfterTrack: "播完停止"
        }
    }

    static func symbol(_ mode: PlaybackOrderMode) -> String {
        switch mode {
        case .shuffle: "shuffle"
        case .sequence: "list.bullet"
        case .repeatOne: "repeat.1"
        case .stopAfterTrack: "pause.circle"
        }
    }

    static func title(_ mode: AppleMusicPlaybackMode) -> String {
        switch mode {
        case .sequence: "顺序播放"
        case .shuffle: "随机播放"
        case .repeatAll: "列表循环"
        case .repeatOne: "单曲循环"
        }
    }

    static func symbol(_ mode: AppleMusicPlaybackMode) -> String {
        switch mode {
        case .sequence: "list.bullet"
        case .shuffle: "shuffle"
        case .repeatAll: "repeat"
        case .repeatOne: "repeat.1"
        }
    }
}

// MARK: - Shared pop-out pieces

/// Hover with a short grace period, so the pointer can cross the gaps between popped-out
/// items, or overshoot by a few points, without the stack folding away. A drag holds it open.
/// An exclusive latch closes the open one at once: moving onto another stack folds the last.
@Observable
@MainActor
final class SkinHoverLatch {
    private(set) var isOpen = false
    @ObservationIgnored private let exclusive: Bool
    @ObservationIgnored private var isHovering = false
    @ObservationIgnored private var isHeld = false
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    private static weak var openExclusive: SkinHoverLatch?
    /// Posted when an exclusive stack opens or folds, so the scene can keep its controls up
    /// while the pointer is on items that popped out above them (`host.popoutOpen`).
    static let presenceChanged = Notification.Name("SkinHoverLatch.presenceChanged")
    static var isExclusiveOpen: Bool { openExclusive?.isOpen == true }

    init(exclusive: Bool = false) {
        self.exclusive = exclusive
    }

    func hover(_ inside: Bool, grace: Double) {
        isHovering = inside
        if inside { open() } else { scheduleClose(after: grace) }
    }

    func hold(_ held: Bool, grace: Double) {
        isHeld = held
        if held { cancelClose() } else if !isHovering { scheduleClose(after: grace) }
    }

    func open() {
        cancelClose()
        if exclusive {
            if let other = Self.openExclusive, other !== self { other.close() }
            Self.openExclusive = self
        }
        if !isOpen {
            isOpen = true
            if exclusive { NotificationCenter.default.post(name: Self.presenceChanged, object: nil) }
        }
    }

    func close() {
        cancelClose()
        isHovering = false
        isHeld = false
        let wasOpen = isOpen
        if isOpen { isOpen = false }
        if Self.openExclusive === self { Self.openExclusive = nil }
        if exclusive && wasOpen { NotificationCenter.default.post(name: Self.presenceChanged, object: nil) }
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }

    private func scheduleClose(after grace: Double) {
        guard !isHeld else { return }
        cancelClose()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, grace)))
            guard let self, !Task.isCancelled, !self.isHovering, !self.isHeld else { return }
            self.close()
        }
    }
}

/// MotionKit's control spring with a little bounce, staggered so the items follow one another.
struct SkinPopoutMotion {
    let tokens: MotionTokens
    let policy: MotionPolicy
    let bounce: Double
    let stagger: Double
    var duration: Double?

    /// Opening rises from the trigger outward with the bounce; folding starts at the far end.
    func animation(index: Int = 0, count: Int = 1, opening: Bool) -> Animation? {
        // The skin engine's token retuning keeps the user's motion speed and the token's shape.
        var fields: [String: SkinValue] = ["token": .text("control"), "bounce": .number(opening ? bounce : 0)]
        if let duration { fields["duration"] = .number(opening ? duration : duration * 0.7) }
        let spec = SkinMotion.spec(.record(fields), tokens: tokens)
        let order = opening ? index : max(0, count - 1 - index)
        return policy.animation(for: spec)?.delay(Double(order) * stagger * (opening ? 1 : 0.6))
    }
}

/// One popped-out item: it leaves the trigger and settles `index + 1` rows above it.
struct SkinPopoutItem: ViewModifier {
    let index: Int
    let count: Int
    let rise: CGFloat
    let open: Bool
    let motion: SkinPopoutMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(open ? 1 : 0.5, anchor: .bottom)
            .opacity(open ? 1 : 0)
            .offset(y: open ? -CGFloat(index + 1) * rise : 0)
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
            .animation(motion.animation(index: index, count: count, opening: open), value: open)
    }
}

/// Where a pop-out stack answers the pointer: the trigger while folded; the whole column
/// once open, with a little slack; plus a strip to the leading side of one row.
nonisolated struct SkinPopoutHitShape: Shape {
    var itemSize: CGFloat
    var rise: CGFloat
    var openCount: Int
    var sideRow: Int?
    var sideWidth: CGFloat
    var slack: CGFloat

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let height = itemSize + CGFloat(openCount) * rise
        path.addRect(CGRect(x: rect.maxX - itemSize - slack, y: rect.maxY - height - slack,
                            width: itemSize + slack * 2, height: height + slack * 2))
        if let sideRow {
            let top = rect.maxY - itemSize - CGFloat(sideRow + 1) * rise
            path.addRect(CGRect(x: rect.maxX - itemSize - sideWidth - slack, y: top - slack,
                                width: sideWidth + slack, height: itemSize + slack * 2))
        }
        return path
    }
}

/// A row's own area widened to the leading side, for a track that slides out of it.
nonisolated struct SkinLeadingStripShape: Shape {
    var extra: CGFloat

    nonisolated func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - extra, y: rect.minY, width: rect.width + extra, height: rect.height))
    }
}

/// A bare symbol button that brightens and grows slightly under the pointer.
struct SkinGlyphButton: View {
    let symbol: String
    let size: CGFloat
    let symbolSize: CGFloat
    let color: Color
    var emphasized = false
    var enabled = true
    /// A fixed, leading-aligned width for symbols of varying width, so their shared part stays put.
    var symbolWidth: CGFloat?
    let help: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.motionTokens) private var tokens
    @Environment(\.motionPolicy) private var policy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .semibold))
                .frame(width: symbolWidth, alignment: .leading)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(color.opacity(enabled ? (hovered || emphasized ? 1 : 0.72) : 0.35))
                .scaleEffect(hovered && enabled ? 1.08 : 1)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .onHover { hovered = $0 }
        .animation(policy.resolvedAnimation(for: tokens.microInteraction, accessibilityReduceMotion: reduceMotion), value: hovered)
        .skinControlRegion()
    }
}

/// A thick capsule track; dragging anywhere on it sets the value.
private struct SkinCapsuleTrack: View {
    let value: Double
    let enabled: Bool
    let color: Color
    let thickness: CGFloat
    let onChange: (Double) -> Void
    let onDragging: (Bool) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let filled = CGFloat(min(1, max(0, value)))
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.22))
                Capsule().fill(color.opacity(enabled ? 0.92 : 0.4))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(thickness, width * filled))
                    }
            }
            .frame(height: thickness)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard enabled else { return }
                    if !dragging { dragging = true; onDragging(true) }
                    onChange(Double(min(1, max(0, drag.location.x / width))))
                }
                .onEnded { _ in
                    guard dragging else { return }
                    dragging = false
                    onDragging(false)
                })
        }
        .skinControlRegion()
    }
}

private extension SkinComponentConfiguration {
    func popoutMotion(tokens: MotionTokens, policy: MotionPolicy, reduceMotion: Bool) -> SkinPopoutMotion {
        SkinPopoutMotion(tokens: tokens, policy: policy.resolving(accessibilityReduceMotion: reduceMotion),
                         bounce: number("bounce", fallback: 0.22), stagger: number("stagger", fallback: 0.045),
                         duration: { if case .number(let value) = values["duration"] { value } else { nil } }())
    }
}

// MARK: - control.progressLine

/// A thin progress line that thickens under the pointer, track and fill together, and shows
/// the elapsed time and duration beneath it with the App's numeric text transition.
struct SkinProgressLinePart: View {
    let configuration: SkinComponentConfiguration
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.skinSceneActions) private var actions
    @Environment(\.motionTokens) private var tokens
    @Environment(\.motionPolicy) private var policy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dragging = false
    @State private var position: Double = 0

    var body: some View {
        let presentation = playback.presentation
        let duration = max(0, presentation.duration)
        let time = dragging ? position : playback.playbackProgress.currentTime
        let fraction = CGFloat(duration > 0 ? min(1, max(0, time / duration)) : 0)
        let active = hovering || dragging
        let raised = CGFloat(configuration.number("hoverHeight", fallback: 6))
        let thickness = active ? raised : CGFloat(configuration.number("height", fallback: 2.5))
        let color = configuration.color(fallback: .primary)
        let timeSize = CGFloat(configuration.number("timeSize", fallback: 11))

        VStack(spacing: configuration.number("timeGap", fallback: 2)) {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                // The fill is a whole capsule masked to the played width, so both parts
                // share one thickness and change it in the same animation.
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(configuration.number("trackOpacity", fallback: 0.22)))
                    Capsule().fill(color.opacity(active ? 0.95 : 0.78))
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(thickness, width * fraction))
                        }
                }
                .frame(height: thickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard presentation.isSeekEnabled else { return }
                        if !dragging { dragging = true }
                        position = Double(min(1, max(0, drag.location.x / width))) * duration
                    }
                    .onEnded { _ in
                        guard dragging else { return }
                        actions.seek(position)
                        dragging = false
                    })
                .onHover { hovering = $0 }
            }
            .frame(height: max(raised, CGFloat(configuration.number("hitHeight", fallback: 20))))
            .skinControlRegion()

            HStack(spacing: 0) {
                NumericTimeText(time: time, fontSize: timeSize, fontWeight: .medium, color: color.opacity(0.62))
                Spacer(minLength: 0)
                NumericTimeText(time: duration, fontSize: timeSize, fontWeight: .medium, color: color.opacity(0.62))
            }
            .opacity(active ? 1 : 0)
            .offset(y: active ? 0 : -3)
            .allowsHitTesting(false)
            .accessibilityHidden(!active)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(policy.resolvedAnimation(for: tokens.control, accessibilityReduceMotion: reduceMotion), value: active)
    }
}

// MARK: - control.actionStack

/// The exit button with volume, quick appearance and lyrics popping out above it.
/// The volume track slides out to the leading side while the pointer is on the speaker.
struct SkinActionStackPart: View {
    let configuration: SkinComponentConfiguration
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.skinSceneActions) private var actions
    @Environment(\.skinSceneSurface) private var surface
    @Environment(\.skinNativeControls) private var native
    @Environment(\.motionTokens) private var tokens
    @Environment(\.motionPolicy) private var policy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stack = SkinHoverLatch(exclusive: true)
    @State private var volume = SkinHoverLatch()
    @State private var restoreVolume: Double = 0.5

    private var size: CGFloat { CGFloat(configuration.number("size", fallback: 36)) }
    private var symbolSize: CGFloat { CGFloat(configuration.number("symbolSize", fallback: 17)) }
    private var rise: CGFloat { size + CGFloat(configuration.number("spacing", fallback: 4)) }
    private var grace: Double { configuration.number("grace", fallback: 0.35) }
    private var trackWidth: CGFloat { CGFloat(configuration.number("volumeWidth", fallback: 96)) }
    private let trackGap: CGFloat = 6

    var body: some View {
        let motion = configuration.popoutMotion(tokens: tokens, policy: policy, reduceMotion: reduceMotion)
        let color = configuration.color(fallback: .primary)
        let open = stack.isOpen
        let volumeOpen = open && volume.isOpen
        let lyricsShown = native?.presentation.isShowingLyrics == true
        let motionArtwork = native?.presentation.isMotionArtworkFullscreenActive == true
        let fullscreen = surface == .fullscreen

        ZStack(alignment: .bottomTrailing) {
            SkinGlyphButton(
                symbol: motionArtwork ? "rectangle.compress.vertical" : (lyricsShown ? "quote.bubble.fill" : "quote.bubble"),
                size: size, symbolSize: symbolSize, color: color,
                help: motionArtwork ? "退出视频全屏" : (lyricsShown ? "隐藏歌词" : "显示歌词")
            ) {
                if motionArtwork { native?.actions.exitMotionArtworkFullscreen() } else { actions.toggleLyrics() }
            }
            .modifier(SkinPopoutItem(index: 2, count: 3, rise: rise, open: open, motion: motion))

            SkinGlyphButton(symbol: "paintpalette", size: size, symbolSize: symbolSize, color: color, help: "快速外观") {
                actions.openQuickPanel()
            }
            .modifier(SkinPopoutItem(index: 1, count: 3, rise: rise, open: open, motion: motion))

            volumeRow(color: color, open: volumeOpen, motion: motion)
                .modifier(SkinPopoutItem(index: 0, count: 3, rise: rise, open: open, motion: motion))

            SkinGlyphButton(
                symbol: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                size: size, symbolSize: symbolSize, color: color, emphasized: open,
                help: fullscreen ? "退出全屏" : "全屏播放"
            ) {
                fullscreen ? actions.exit() : actions.enterFullscreen()
            }
        }
        .frame(width: size, height: size)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .contentShape(SkinPopoutHitShape(itemSize: size, rise: rise, openCount: open ? 3 : 0,
                                         sideRow: volumeOpen ? 0 : nil, sideWidth: trackWidth + trackGap,
                                         slack: open ? 10 : 0))
        .onHover { stack.hover($0, grace: grace) }
        .onChange(of: open) { _, isOpen in if !isOpen { volume.close() } }
        .onDisappear { stack.close() }
        .skinProvidesControls([.fullscreen, .lyricsToggle, .quickPanel])
    }

    private func volumeRow(color: Color, open: Bool, motion: SkinPopoutMotion) -> some View {
        let presentation = playback.stablePresentation
        let level = presentation.volume
        let enabled = presentation.isVolumeControlEnabled
        return ZStack(alignment: .trailing) {
            SkinCapsuleTrack(
                value: level, enabled: enabled, color: color,
                thickness: CGFloat(configuration.number("volumeHeight", fallback: 6)),
                onChange: { actions.setVolume($0) },
                onDragging: { held in
                    volume.hold(held, grace: grace)
                    stack.hold(held, grace: grace)
                }
            )
            .frame(width: trackWidth, height: size)
            .scaleEffect(x: open ? 1 : 0.3, y: 1, anchor: .trailing)
            .opacity(open ? 1 : 0)
            .allowsHitTesting(open)
            .offset(x: -(size + trackGap))
            .animation(motion.animation(opening: open), value: open)

            SkinGlyphButton(
                symbol: level <= 0 ? "speaker.slash.fill" : (level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"),
                size: size, symbolSize: symbolSize, color: color, emphasized: open, enabled: enabled,
                symbolWidth: symbolSize * 1.3, help: level <= 0 ? "取消静音" : "静音"
            ) {
                if level > 0 {
                    restoreVolume = level
                    actions.setVolume(0)
                } else {
                    actions.setVolume(max(0.05, restoreVolume))
                }
            }
            .background(SkinSceneScrollRegion { _, y, _ in
                guard enabled else { return }
                actions.setVolume(min(1, max(0, playback.stablePresentation.volume + y * 0.0025)))
            })
        }
        .frame(width: size, height: size, alignment: .trailing)
        .contentShape(SkinLeadingStripShape(extra: open ? trackWidth + trackGap : 0))
        .onHover { volume.hover($0, grace: grace) }
    }
}

// MARK: - control.playbackModeStack

/// The current playback order with the other orders popping out above it. Clicking the
/// current order while the others are out opens the play queue. A chosen order drops into
/// the resident slot and grows a little as it lands; the rest fade where they stand.
struct SkinPlaybackModeStackPart: View {
    let configuration: SkinComponentConfiguration
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettings.self) private var settings
    @Environment(\.skinSceneActions) private var actions
    @Environment(\.motionTokens) private var tokens
    @Environment(\.motionPolicy) private var policy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stack = SkinHoverLatch(exclusive: true)
    /// Each order's row while a choice folds the stack, so the others fade in place.
    @State private var settling: [String: Int]?
    @State private var landing: String?

    private struct Entry {
        let id: String
        let symbol: String
        let select: () -> Void
    }

    /// Every order in a fixed sequence, so each keeps its own view, and the current one's id.
    private var entries: (all: [Entry], current: String) {
        let presentation = playback.stablePresentation
        if presentation.source == .local {
            let mode = presentation.localPlaybackOrderMode ?? settings.playbackOrderMode
            let all = SkinPlaybackOrderLabels.localModes.map { mode in
                Entry(id: SkinPlaybackOrderLabels.title(mode), symbol: SkinPlaybackOrderLabels.symbol(mode)) { actions.setPlaybackOrder(mode) }
            }
            return (all, SkinPlaybackOrderLabels.title(mode))
        }
        let mode = presentation.appleMusicPlaybackMode ?? .sequence
        let all = SkinPlaybackOrderLabels.externalModes.map { mode in
            Entry(id: SkinPlaybackOrderLabels.title(mode), symbol: SkinPlaybackOrderLabels.symbol(mode)) { actions.setExternalPlaybackOrder(mode) }
        }
        return (all, SkinPlaybackOrderLabels.title(mode))
    }

    private struct Phase: Hashable {
        let open: Bool
        let current: Bool
    }

    var body: some View {
        let size = CGFloat(configuration.number("size", fallback: 36))
        let symbolSize = CGFloat(configuration.number("symbolSize", fallback: 16))
        let rise = size + CGFloat(configuration.number("spacing", fallback: 4))
        let grace = configuration.number("grace", fallback: 0.35)
        let motion = configuration.popoutMotion(tokens: tokens, policy: policy, reduceMotion: reduceMotion)
        let color = configuration.color(fallback: .primary)
        let enabled = playback.stablePresentation.isPlaybackModeControlEnabled
        let open = stack.isOpen
        let modes = self.entries
        let others = modes.all.filter { $0.id != modes.current }

        ZStack(alignment: .bottomTrailing) {
            ForEach(modes.all, id: \.id) { entry in
                let current = entry.id == modes.current
                let index = others.firstIndex { $0.id == entry.id } ?? 0
                // Open: the others stand in their rows. Folded by a choice: they fade in the rows
                // they stood in. Folded otherwise: they gather back into the trigger.
                let row = current ? 0 : (open ? index + 1 : (settling?[entry.id] ?? 0))
                let shown = current || open
                SkinGlyphButton(symbol: entry.symbol, size: size, symbolSize: symbolSize, color: color,
                                emphasized: current && open, enabled: current || enabled,
                                help: current ? (open ? "播放队列" : entry.id) : entry.id) {
                    if current {
                        if stack.isOpen { actions.toggleQueue() } else { stack.open() }
                    } else {
                        choose(entry, others: others, current: modes.current)
                    }
                }
                .scaleEffect(landing == entry.id ? 1.16 : 1)
                .animation(motion.animation(opening: true), value: landing == entry.id)
                .scaleEffect(shown || settling != nil ? 1 : 0.5, anchor: .bottom)
                .opacity(shown ? 1 : 0)
                .offset(y: -CGFloat(row) * rise)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
                .zIndex(current ? 1 : 0)
                .animation(current ? motion.animation(opening: true)
                                   : motion.animation(index: index, count: others.count, opening: open),
                           value: Phase(open: open, current: current))
            }
        }
        .frame(width: size, height: size)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .contentShape(SkinPopoutHitShape(itemSize: size, rise: rise, openCount: open ? others.count : 0,
                                         sideRow: nil, sideWidth: 0, slack: open ? 10 : 0))
        .onHover { stack.hover($0, grace: grace) }
        .onChange(of: open) { _, isOpen in if isOpen { settling = nil } }
        .onDisappear { stack.close() }
    }

    private func choose(_ entry: Entry, others: [Entry], current: String) {
        var rows = [current: 0]
        for (index, other) in others.enumerated() { rows[other.id] = index + 1 }
        settling = rows
        entry.select()
        stack.close()
        landing = entry.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.18))
            if landing == entry.id { landing = nil }
            try? await Task.sleep(for: .seconds(0.6))
            if !stack.isOpen { settling = nil }
        }
    }
}
