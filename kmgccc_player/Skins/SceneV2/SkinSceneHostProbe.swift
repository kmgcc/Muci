import AppKit
import SwiftUI

/// Reads the actual hosting window instead of guessing from the frontmost display.
struct SkinSceneHostProbe: NSViewRepresentable {
    let data: SkinSceneData
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.data = data; view.publish() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }
    final class Probe: NSView {
        weak var data: SkinSceneData?
        private var tracking: NSTrackingArea?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: SkinHoverLatch.presenceChanged, object: nil)
            updateTrackingAreas(); publish()
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { data?.updateHostFacts(["host.pointerInside": .boolean(true)]); moved(event) }
        override func mouseExited(with event: NSEvent) { data?.updateHostFacts(["host.pointerInside": .boolean(false)]); moved(nil) }
        override func mouseMoved(with event: NSEvent) { moved(event) }
        private func moved(_ event: NSEvent?) {
            data?.pointerMoved()
            guard let event, bounds.height > 0 else { return }
            // A pointer already inside when the probe appears reports itself only by moving.
            let point = convert(event.locationInWindow, from: nil)
            let y = isFlipped ? point.y : bounds.height - point.y
            let step = bounds.height / 24
            data?.updateHostFacts([
                "host.pointerInside": .boolean(bounds.contains(point)),
                "host.pointerY": .number(Double((y / step).rounded(.down) * step)),
            ])
        }
        @objc private func changed() { publish() }
        func publish() {
            guard let window, let data else { return }
            data.updateHostFacts(["host.isKeyWindow": .boolean(window.isKeyWindow),
                                  "host.popoutOpen": .boolean(SkinHoverLatch.isExclusiveOpen)])
            let inset = safeAreaInsets
            data.updateViewportFacts([
                "viewport.maximumRefreshRate": .number(Double(window.screen?.maximumFramesPerSecond ?? 60)),
                "viewport.safeArea": .record(["top": .number(inset.top), "leading": .number(inset.left), "bottom": .number(inset.bottom), "trailing": .number(inset.right)])
            ])
        }
        func stop() {
            NotificationCenter.default.removeObserver(self)
            if let tracking { removeTrackingArea(tracking) }; tracking = nil
        }
    }
}
