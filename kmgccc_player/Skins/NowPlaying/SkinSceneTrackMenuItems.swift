import SwiftUI

/// The now-playing track's actions in a scene skin's right-click menus: the items the built-in
/// Mini Player offers, plus removal from the playlist the queue was started from.
struct SkinSceneTrackMenuItems: View {
    var showsLike = true
    var showsDislike = false

    @Environment(\.skinSceneActions) private var actions
    @Environment(\.skinSceneSurface) private var surface
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(PlayerViewModel.self) private var player
    @Environment(LibraryViewModel.self) private var library

    var body: some View {
        if let track = playback.stablePresentation.localTrack {
            let playlist = library.queueSourcePlaylist(containing: track, source: player.activeLibraryQueueSource)
            TrackActionMenuContent(
                track: track, onPlay: {}, onEditTrack: { _ in actions.openTrackEdit() },
                onDeleteFromLibraryRequest: { _ in actions.deleteTrack() },
                onRemoveFromCurrentPlaylist: playlist.map { playlist in
                    { track in Task { await library.removeTracksFromPlaylist([track], playlist: playlist) } }
                },
                onShowDetails: { _ in actions.openTrackDetail() },
                showsPlay: false, showsNavigation: surface == .window,
                showsLike: showsLike, showsDislike: showsDislike,
                removeFromPlaylistName: playlist?.name,
                diagnosticSurface: "SkinSceneMenu"
            )
        }
    }
}

extension LibraryViewModel {
    /// The playlist the current queue was started from, when it still holds `track`.
    func queueSourcePlaylist(containing track: Track, source: LibraryQueueSource?) -> Playlist? {
        let prefix = "playlist-"
        guard case .librarySelection(let identity)? = source, identity.hasPrefix(prefix),
              let id = UUID(uuidString: String(identity.dropFirst(prefix.count))),
              let playlist = playlists.first(where: { $0.id == id }),
              playlist.tracks.contains(where: { $0.id == track.id }) else { return nil }
        return playlist
    }
}
