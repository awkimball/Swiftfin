//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Factory
import Foundation
import JellyfinAPI

/// Owns a single multi-view tile's playback engine.
///
/// Each tile drives its own `MediaPlayerManager` + `AVMediaPlayerProxy` (reusing the
/// hardened live-startup recovery and tuner-release reporting), but renders only the
/// bare `AVPlayerLayer` so several can be laid out at once in a grid.
@MainActor
final class MultiViewTileModel: ObservableObject, Identifiable {

    nonisolated let id = UUID()

    @Published
    private(set) var channel: BaseItemDto?

    let proxy = AVMediaPlayerProxy()
    private(set) var manager: MediaPlayerManager?

    /// Force each tile to a low, SDR, capped stream so two simultaneous decodes stay well
    /// within the Apple TV's video decode budget. `MaxVideoBitDepth=8` makes the server
    /// tonemap any HDR source down to 8-bit SDR; `MaxWidth/Height` cap to 720p and
    /// `VideoBitrate` caps to ~10 Mbps. The server honors these as HLS query parameters.
    private static let constraints: [String: String] = [
        "MaxWidth": "1280",
        "MaxHeight": "720",
        "VideoBitrate": "10000000",
        "MaxVideoBitDepth": "8",
    ]

    init() {
        // Tiles start muted; the active tile is unmuted by the container.
        proxy.player.isMuted = true
    }

    private func makeProvider(for channel: BaseItemDto) -> MediaPlayerItemProvider {
        MediaPlayerItemProvider(item: channel) { item in
            try await MediaPlayerItem.build(
                for: item,
                videoPlayerType: .native,
                requestedBitrate: .mbps10,
                forceVideoReencode: true,
                additionalTranscodeParameters: Self.constraints
            )
        }
    }

    /// Start (or switch to) playing the given channel in this tile.
    func play(channel: BaseItemDto) {
        self.channel = channel
        let provider = makeProvider(for: channel)

        guard let manager else {
            let manager = MediaPlayerManager(
                item: channel,
                mediaPlayerItemProvider: provider.function
            )
            self.manager = manager
            manager.proxy = proxy
            manager.start()
            return
        }

        // Switching channels on an already-playing tile: release THIS tile's current
        // live stream *before* opening the new one. `playNewItem` otherwise opens the
        // new stream while the old one is still held, so for a moment the tile holds
        // old + new + the other tile's stream. A tuner host with a hard limit (e.g.
        // HDHomeRun's physical tuners) answers the over-budget request with an immediate
        // zero-byte stream, which shows as a permanently black tile. Closing is scoped to
        // this tile's liveStreamID, so the other tile's stream is untouched. We avoid a
        // full `stop()` because its progress observer kills *all* of this device's
        // encodings, tearing down the other tiles too.
        Task { @MainActor in
            await releaseCurrentLiveStream()
            guard self.channel?.id == channel.id else { return }
            await manager.playNewItem(provider: provider)
        }
    }

    /// Close this tile's current server-side live stream to release its tuner, scoped to
    /// the tile's own `liveStreamID` so other tiles keep playing.
    private func releaseCurrentLiveStream() async {
        guard let liveStreamID = manager?.playbackItem?.mediaSource.liveStreamID,
              liveStreamID.isNotEmpty,
              let userSession = Container.shared.currentUserSession()
        else { return }

        let request = Paths.closeLiveStream(liveStreamID: liveStreamID)
        _ = try? await userSession.client.send(request)
    }

    /// Whether this tile is the active audio source.
    func setActiveAudio(_ isActive: Bool) {
        proxy.player.isMuted = !isActive
    }

    /// Fully stop playback and release the tuner. Only call on teardown — this kills all of
    /// this device's encodings via the progress observer.
    func stop() {
        manager?.stop()
        manager = nil
        channel = nil
    }
}
