//
//  PromptDefaults.swift
//  kmgccc_player
//
//  The preferences domain that holds prompt state.
//

import Foundation

/// Where install history, What's New, tip budgets and discovery progress live.
///
/// Release builds always use the standard domain. A debug run started with
/// `KMGCCC_DEBUG_PROMPTS_SANDBOX=<name>` keeps all of it in a separate domain,
/// so upgrade and fresh-install scenarios can be replayed without touching the
/// real prompt state.
enum PromptDefaults {
    static let store: UserDefaults = {
        #if DEBUG
        if let suiteName = PromptDebugLaunchOptions.current.sandboxSuiteName,
           let sandbox = UserDefaults(suiteName: suiteName) {
            Log.info("[PromptDebug] prompt state sandbox: \(suiteName)", category: .ui)
            return sandbox
        }
        #endif
        return .standard
    }()
}
