import SwiftUI

struct SkinPackageManifest: Codable {
    var formatVersion = 2
    var hostAPIVersion = 2
    var version = "1.0.0"
    var descriptor: SkinDescriptor
    /// The optional native preset supplies the existing artwork/background and settings adapters.
    var nativePreset: String?
    var scene: SkinSceneDocument?
    var parameters: [SkinParameterDefinition] = []
    var sceneV2: SkinSceneV2Document?
    var scenePath: String?
    var scenes: [String: SkinSceneV2Document] = [:]
    var requires: [String] = []
    var uses: [String] = []
    var fonts: [String] = []
    /// Named expressions shared by every scene, used as `let.name`.
    var lets: [String: String] = [:]
    /// The author's display name; shown only when `sidebar.showsAuthor` asks for it.
    var author: String?
    /// The side strip on this skin's selection card; absent means no strip.
    var sidebar: SkinCardSidebar?
    /// The author's square card picture; without one the card draws the scene's silhouette.
    var preview: SkinPackagePreview?
}

/// A square picture for the selection card, with an optional dark-appearance version.
/// Written as a path, or as `{"image": path, "dark": path, "themed": true}`.
///
/// A themed picture is a three-colour template: pure red, green and blue stand for the theme's
/// accent, foreground and a quiet neutral, and the card repaints them in the current theme. Opacity and
/// overlaps blend between the roles.
struct SkinPackagePreview: Codable, Equatable {
    static let fileExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]

    var image: String
    var dark: String?
    var themed = false

    private enum CodingKeys: String, CodingKey { case image, dark, themed }

    init(image: String, dark: String? = nil, themed: Bool = false) {
        self.image = image
        self.dark = dark
        self.themed = themed
    }

    init(from decoder: any Decoder) throws {
        if let path = try? decoder.singleValueContainer().decode(String.self) {
            image = path
            return
        }
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        image = try keys.decode(String.self, forKey: .image)
        dark = try keys.decodeIfPresent(String.self, forKey: .dark)
        themed = try keys.decodeIfPresent(Bool.self, forKey: .themed) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        if dark == nil, !themed {
            var single = encoder.singleValueContainer()
            try single.encode(image)
            return
        }
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(image, forKey: .image)
        try keys.encodeIfPresent(dark, forKey: .dark)
        if themed { try keys.encode(true, forKey: .themed) }
    }

    var paths: [String] { [image] + (dark.map { [$0] } ?? []) }
}

/// Author-controlled side strip on a skin's selection card: a short label such as "beta"
/// at the top and, if the author opts in, their name at the bottom, written "-by name" by default.
struct SkinCardSidebar: Codable, Equatable {
    static let authorPrefix = "-by "

    var visible = true
    var label: String?
    var showsAuthor = false
    var showsAuthorPrefix = true

    private enum CodingKeys: String, CodingKey { case visible, label, showsAuthor, showsAuthorPrefix }

    init(visible: Bool = true, label: String? = nil, showsAuthor: Bool = false, showsAuthorPrefix: Bool = true) {
        self.visible = visible
        self.label = label
        self.showsAuthor = showsAuthor
        self.showsAuthorPrefix = showsAuthorPrefix
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        visible = try keys.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        label = try keys.decodeIfPresent(String.self, forKey: .label)
        showsAuthor = try keys.decodeIfPresent(Bool.self, forKey: .showsAuthor) ?? false
        showsAuthorPrefix = try keys.decodeIfPresent(Bool.self, forKey: .showsAuthorPrefix) ?? true
    }
}

enum SkinPackageOrigin {
    case bundled
    case installed(URL)
    case development(URL)
}

/// Built-in and imported definitions use the same adapter; origin only controls management.
struct PackagedSkin: NowPlayingSkin {
    let manifest: SkinPackageManifest
    let origin: SkinPackageOrigin
    let renderer: (any NowPlayingSkin)?
    var programs: [String: SkinSceneProgram] = [:]

    var isExportable: Bool {
        switch origin { case .installed, .development: true; case .bundled: false }
    }

    var descriptor: SkinDescriptor { manifest.descriptor }
    /// Components the compiled scenes mount; settings show the host options these rely on.
    var sceneComponents: Set<String> {
        programs.values.reduce(into: Set<String>()) { $0.formUnion($1.root.componentNames) }
    }
    var lyricsUserSettings: Set<String>? {
        programs.values.lazy.compactMap(\.root.lyricsUserSettings).first
    }
    /// Whether this surface's compiled scene mounts the native lyric surface; nil without one.
    func sceneMountsNativeLyrics(on surface: SkinSurface) -> Bool? {
        guard let program = programs[surface.rawValue] ?? programs["default"] else { return nil }
        return !program.root.componentNames.isDisjoint(with: ["lyrics.native", "lyrics.panel"])
    }
    /// Whether this surface's compiled scene reads the lyric document or timeline; nil without one.
    func sceneReadsLyrics(on surface: SkinSurface) -> Bool? {
        guard let program = programs[surface.rawValue] ?? programs["default"] else { return nil }
        return !program.domains.isDisjoint(with: [.lyrics, .lyricsTimeline])
    }
    var scene: SkinScene? {
        guard !programs.isEmpty else { return manifest.scene?.scene ?? renderer?.scene }
        return SkinScene { snapshot, viewport, components in
            if let program = programs[viewport.surface.rawValue] ?? programs["default"] {
                SkinSceneV2View(program: program, snapshot: snapshot, viewport: viewport, components: components)
            }
        }
    }
    var parameterDefinitions: [SkinParameterDefinition] { manifest.parameters }

    func makeBackground(context: SkinContext) -> AnyView {
        renderer?.makeBackground(context: context) ?? AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        renderer?.makeArtwork(context: context) ?? AnyView(SkinArtworkComponent(snapshot: .init(context: context)))
    }

    func makeOverlay(context: SkinContext) -> AnyView? { renderer?.makeOverlay(context: context) }
    var settingsView: AnyView? { renderer?.settingsView }
    var fullscreenSettingsView: AnyView? { renderer?.fullscreenSettingsView }
    func releaseCachedResources() async { await renderer?.releaseCachedResources() }
}
