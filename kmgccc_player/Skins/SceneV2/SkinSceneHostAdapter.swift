import AppKit
import SwiftUI

/// Everything a scene takes from the App that hosts it. The engine names no App service: the
/// host installs its adapter on the scene's environment, and a scene without one (previews,
/// author tools) runs on whatever its caller feeds `SkinSceneData` directly.
protocol SkinSceneHostAdapter {
    /// An invisible view that keeps `request.data` current from the host's own sources.
    func feeds(_ request: SkinSceneFeedRequest) -> AnyView
    /// Wraps the whole scene once. When `enabled`, it prepares what adaptive nodes read.
    func backdrop(_ scene: AnyView, snapshot: SkinSceneSnapshot, size: CGSize, enabled: Bool) -> AnyView
    /// `adaptive: true` on a node: chooses ink for what lies beneath it and writes it to `reading`.
    func adaptive(_ node: AnyView, reading: Binding<SkinBackdropReading?>) -> AnyView
    /// `artwork` with a `track`: that track's artwork, wherever it is in the library.
    func trackArtwork(id: UUID, fills: Bool) -> AnyView
}

struct SkinSceneFeedRequest {
    let data: SkinSceneData
    let program: SkinSceneProgram
    let snapshot: SkinSceneSnapshot
    let viewport: SkinViewport
    let parameters: [String: SkinParameterValue]
}

/// The coordinate space a scene's nodes measure themselves in.
enum SkinSceneSpace {
    nonisolated static let name = "skinScene"
}

/// The ink an adaptive node chose for what lies beneath it.
struct SkinBackdropReading: Equatable {
    let usesDarkForeground: Bool
    let primaryColor: NSColor
    let secondaryColor: NSColor
    var primary: Color { Color(nsColor: primaryColor) }
    var secondary: Color { Color(nsColor: secondaryColor) }

    var value: SkinValue {
        .record(["backdrop": .text(usesDarkForeground ? "light" : "dark"),
                 "foreground": .color(OKLCHColor(primaryColor)), "secondaryForeground": .color(OKLCHColor(secondaryColor))])
    }
}

extension EnvironmentValues {
    @Entry var skinSceneHost: (any SkinSceneHostAdapter)?
    @Entry var skinBackdropReading: SkinBackdropReading?
}
