import AppKit
import SwiftUI

/// Observes only scrolls inside this scene node; ordinary control clicks pass through.
struct SkinSceneScrollRegion: NSViewRepresentable {
    /// Deltas as AppKit reports them; `precise` is true for a trackpad's point deltas, false for a wheel's lines.
    let onScroll: (Double, Double, Bool) -> Void
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: RegionView, coordinator: ()) { view.stop() }
    final class RegionView: NSView {
        var onScroll: ((Double, Double, Bool) -> Void)?
        private var monitor: Any?
        /// Mounted regions, so the host's scroll volume can yield to them whichever monitor runs first.
        private static let mounted = NSHashTable<RegionView>.weakObjects()
        static func claims(_ event: NSEvent) -> Bool { mounted.allObjects.contains { $0.takes(event) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            Self.mounted.add(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.takes(event) else { return event }
                self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
                return nil
            }
        }
        private func takes(_ event: NSEvent) -> Bool {
            window === event.window && !isHiddenOrHasHiddenAncestor
                && bounds.contains(convert(event.locationInWindow, from: nil))
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; Self.mounted.remove(self) }
    }
}

/// Observes trackpad pinches inside this scene node; `magnification` is the change since the
/// last event (positive spreads the fingers). Clicks pass through.
struct SkinSceneMagnifyRegion: NSViewRepresentable {
    let onMagnify: (Double) -> Void
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) { view.onMagnify = onMagnify }
    static func dismantleNSView(_ view: RegionView, coordinator: ()) { view.stop() }
    final class RegionView: NSView {
        var onMagnify: ((Double) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                guard let self, self.window === event.window, !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.onMagnify?(event.magnification)
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

/// Marks a panel that scrolls on its own (the play queue), so the host's scroll volume leaves
/// wheel events over it alone. It takes no events itself.
struct SkinScrollYieldRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> YieldView { YieldView() }
    func updateNSView(_ view: YieldView, context: Context) {}
    final class YieldView: NSView {
        private static let mounted = NSHashTable<YieldView>.weakObjects()
        static func claims(_ event: NSEvent) -> Bool {
            mounted.allObjects.contains { view in
                view.window === event.window && !view.isHiddenOrHasHiddenAncestor
                    && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { Self.mounted.add(self) } else { Self.mounted.remove(self) }
        }
    }
}

struct SkinSceneCursorRegion: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) { view.name = name; view.window?.invalidateCursorRects(for: view) }
    final class CursorView: NSView {
        var name = "arrow"
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() {
            let cursor: NSCursor
            switch name {
            case "pointingHand": cursor = .pointingHand
            case "openHand": cursor = .openHand
            case "closedHand": cursor = .closedHand
            case "crosshair": cursor = .crosshair
            case "resizeLeftRight": cursor = .resizeLeftRight
            case "resizeUpDown": cursor = .resizeUpDown
            case "ibeam": cursor = .iBeam
            default: cursor = .arrow
            }
            addCursorRect(bounds, cursor: cursor)
        }
    }
}
