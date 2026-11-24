//
//  MainWindowModalPresenter.swift
//  kmgccc_player
//
//  An in-window modal layer above the main window's content.
//

import AppKit
import MotionKit
import Observation
import SwiftUI

/// A card shown centered over the main window. It closes only through its
/// own buttons.
struct MainWindowModal: Identifiable {
    let id: String
    let content: AnyView
    /// Return or Enter.
    let onDefaultAction: @MainActor () -> Void
}

/// Owns the one in-window modal of the main window.
///
/// The card lives inside the main window rather than in a sheet, so the
/// embedded fullscreen surface can fade in over it in the same transition.
/// While a modal is up the layer absorbs every click in the window, Return
/// runs the default action, Esc is absorbed, and keyboard focus leaves the
/// content underneath.
@MainActor
@Observable
final class MainWindowModalPresenter {
    static let shared = MainWindowModalPresenter()

    private(set) var modal: MainWindowModal?

    @ObservationIgnored private var keyMonitor: Any?

    var isPresenting: Bool { modal != nil }

    func present(_ modal: MainWindowModal) {
        self.modal = modal
        if let window = AppKitMainSplitWindowController.mainWindow {
            window.makeFirstResponder(nil)
        }
        installKeyMonitor()
    }

    /// Removes the modal `id` if it is still the one shown.
    func dismiss(id: String) {
        guard modal?.id == id else { return }
        modal = nil
        removeKeyMonitor()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let modal = self.modal,
                  let window = AppKitMainSplitWindowController.mainWindow,
                  event.window === window, window.isKeyWindow,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            switch event.keyCode {
            case 36, 76: // Return, keypad Enter
                modal.onDefaultAction()
                return nil
            case 53: // Esc: absorbed, so it reaches nothing underneath.
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}

/// The SwiftUI layer: the card centered on the whole window, toolbar included,
/// floating on a soft shadow. Clicks outside the card land on the hosting
/// view, which absorbs them.
struct MainWindowModalLayer: View {
    let presenter: MainWindowModalPresenter

    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        ZStack {
            if let modal = presenter.modal {
                modal.content
                    .environmentObject(themeStore)
                    // Exception to the no-shadow rule: with no scrim, this
                    // diffuse shadow is what lifts the card off the window.
                    .shadow(color: .black.opacity(0.28), radius: 36, y: 14)
                    .id(modal.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .motionAnimation(.contentReplacement, value: presenter.modal?.id)
    }
}

/// Hosts the modal layer at the top of the main window's root view. It claims
/// every hit while a modal is up and none otherwise, including during the
/// exit fade. Hits outside the card fall back to this view and go nowhere.
@MainActor
final class MainWindowModalHostingView: NSHostingView<MainWindowModalLayer> {
    private let presenter: MainWindowModalPresenter

    init(presenter: MainWindowModalPresenter = .shared) {
        self.presenter = presenter
        super.init(rootView: MainWindowModalLayer(presenter: presenter))
        // Center on the full window; the toolbar's safe area would push the card down.
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init(rootView: MainWindowModalLayer) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard presenter.isPresenting else { return nil }
        return super.hitTest(point) ?? self
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
