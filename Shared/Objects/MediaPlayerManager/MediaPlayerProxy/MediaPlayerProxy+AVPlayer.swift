//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Combine
import Defaults
import Foundation
@preconcurrency import JellyfinAPI
import SwiftUI

// TODO: After NativeVideoPlayer is removed, can move bindings and
//       observers to AVPlayerView, like the VLC delegate
//       - wouldn't need to have MediaPlayerProxy: MediaPlayerObserver
// TODO: report playback information, see VLCUI.PlaybackInformation (dropped frames, etc.)
// TODO: report buffering state
// TODO: have set seconds with completion handler

@MainActor
class AVMediaPlayerProxy: VideoMediaPlayerProxy {

    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)
    var isScrubbing: Binding<Bool> = .constant(false)
    var scrubbedSeconds: Binding<Duration> = .constant(.zero)
    var videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)
    let droppedFrames: PublishedBox<Int> = .init(initialValue: 0)
    let corruptedFrames: PublishedBox<Int> = .init(initialValue: 0)

    let avPlayerLayer: AVPlayerLayer
    let player: AVPlayer

//    private var rateObserver: NSKeyValueObservation!
    private var statusObserver: NSKeyValueObservation!
    private var timeControlStatusObserver: NSKeyValueObservation!
    private var timeObserver: Any!
    private var managerItemObserver: AnyCancellable?
    private var managerStateObserver: AnyCancellable?

    private var playlistRewriter: HLSPlaylistRewriter?

    private var currentLiveItem: MediaPlayerItem?

    // One-shot startup watchdog: a non-forced live source that AVPlayer can't start
    // (decode failure or silent spin) escalates once to a forced server-side re-encode.
    private var liveStartupWatchdog: Task<Void, Never>?

    // A live transcode needs a few seconds to produce its first segments; AVPlayer can
    // fail the item while the variant playlist still 404s. Reload the same URL (keeping
    // the play session / live stream alive) a few times before escalating to a rebuild.
    private var liveReloadAttempts = 0
    private let maxLiveReloadAttempts = 8
    private let liveReloadDelay: TimeInterval = 1

    weak var manager: MediaPlayerManager? {
        didSet {
            for var o in observers {
                o.manager = manager
            }

            if let manager {
                managerItemObserver = manager.$playbackItem
                    .sink { [weak self] playbackItem in
                        if let playbackItem {
                            self?.playNew(item: playbackItem)
                        }
                    }

                managerStateObserver = manager.$state
                    .sink { [weak self] state in
                        switch state {
                        case .stopped:
                            self?.playbackStopped()
                        default: break
                        }
                    }
            } else {
                managerItemObserver?.cancel()
                managerStateObserver?.cancel()
            }
        }
    }

    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]

    init() {
        self.player = AVPlayer()
        self.avPlayerLayer = AVPlayerLayer(player: player)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] newTime in
            guard let self else { return }
            let newSeconds = Duration.seconds(newTime.seconds)

            if !self.isScrubbing.wrappedValue {
                self.scrubbedSeconds.wrappedValue = newSeconds
            }

            self.manager?.seconds = newSeconds
        }
    }

    deinit {
        liveStartupWatchdog?.cancel()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        statusObserver?.invalidate()
        timeControlStatusObserver?.invalidate()
        player.replaceCurrentItem(with: nil)
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
    }

    func jumpForward(_ seconds: Duration) {
        let currentTime = player.currentTime()
        let newTime = currentTime + CMTime(seconds: seconds.seconds, preferredTimescale: 1)
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func jumpBackward(_ seconds: Duration) {
        let currentTime = player.currentTime()
        let newTime = max(.zero, currentTime - CMTime(seconds: seconds.seconds, preferredTimescale: 1))
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setSeconds(_ seconds: Duration) {
        let time = CMTime(seconds: seconds.seconds, preferredTimescale: 1)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // TODO: complete
    func setRate(_ rate: Float) {}
    func setAudioStream(_ stream: MediaStream) {}
    func setSubtitleStream(_ stream: MediaStream) {}

    func setAspectFill(_ aspectFill: Bool) {
        avPlayerLayer.videoGravity = aspectFill ? .resizeAspectFill : .resizeAspect
    }

    var videoPlayerBody: some View {
        AVPlayerView()
            .environmentObject(self)
    }
}

extension AVMediaPlayerProxy {

    private func playbackStopped() {
        player.pause()

        liveStartupWatchdog?.cancel()
        liveStartupWatchdog = nil
        currentLiveItem = nil

        if let timeObserver {
            DispatchQueue.main.async {
                self.player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
        }

        if let statusObserver {
            statusObserver.invalidate()
            self.statusObserver = nil
        }

        if let timeControlStatusObserver {
            timeControlStatusObserver.invalidate()
            self.timeControlStatusObserver = nil
        }
    }

    private func makeAVPlayerItem(for item: MediaPlayerItem) -> AVPlayerItem {
        let newAVPlayerItem: AVPlayerItem
        if let (asset, rewriter) = HLSPlaylistRewriter.makeAsset(for: item) {
            playlistRewriter = rewriter
            newAVPlayerItem = AVPlayerItem(asset: asset)
        } else {
            playlistRewriter = nil
            newAVPlayerItem = AVPlayerItem(url: item.url)
        }
        newAVPlayerItem.externalMetadata = item.baseItem.avMetadata

        return newAVPlayerItem
    }

    private func armLiveStartupWatchdog() {
        liveStartupWatchdog?.cancel()
        liveStartupWatchdog = nil
        guard currentLiveItem != nil else { return }

        liveStartupWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.player.timeControlStatus != .playing else { return }
                self.manager?.fallbackToVideoTranscode()
            }
        }
    }

    private func handleLiveFailure() {
        guard let liveItem = currentLiveItem else {
            manager?.fallbackToVideoTranscode()
            return
        }

        // -12927 = AVPlayer can't decode the media (e.g. an HDR or MPEG-2 copy); that needs
        // a forced server re-encode. Other failures during live transcode startup are
        // transient (the variant playlist/segments briefly 404 while ffmpeg warms up), so
        // reload the same URL to keep the play session and live stream alive rather than
        // rebuilding, which would tear the live stream down and starve the transcode.
        let errorCode = (player.currentItem?.error as NSError?)?.code

        if errorCode != -12927, liveReloadAttempts < maxLiveReloadAttempts {
            liveReloadAttempts += 1
            liveStartupWatchdog?.cancel()
            liveStartupWatchdog = nil

            DispatchQueue.main.asyncAfter(deadline: .now() + liveReloadDelay) { [weak self] in
                guard let self, self.currentLiveItem === liveItem else { return }
                self.player.replaceCurrentItem(with: self.makeAVPlayerItem(for: liveItem))
                self.armLiveStartupWatchdog()
                self.play()
            }
        } else {
            manager?.fallbackToVideoTranscode()
        }
    }

    private func playNew(item: MediaPlayerItem) {
        let baseItem = item.baseItem
        let isLiveStream = baseItem.isLiveStream == true

        currentLiveItem = isLiveStream ? item : nil
        liveReloadAttempts = 0

        let newAVPlayerItem = makeAVPlayerItem(for: item)

        player.replaceCurrentItem(with: newAVPlayerItem)

        armLiveStartupWatchdog()

//        rateObserver = player.observe(\.rate, options: [.new, .initial]) { _, value in
//            DispatchQueue.main.async {
//                self.manager?.set(rate: value.newValue ?? 1.0)
//            }
//        }

        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new, .initial]) { player, _ in
            let timeControlStatus = player.timeControlStatus

            DispatchQueue.main.async { [weak self] in
                switch timeControlStatus {
                case .paused:
                    self?.manager?.setPlaybackRequestStatus(status: .paused)
                case .waitingToPlayAtSpecifiedRate: ()
                // TODO: buffering
                case .playing:
                    self?.liveStartupWatchdog?.cancel()
                    self?.liveStartupWatchdog = nil
                    self?.liveReloadAttempts = 0
                    self?.manager?.setPlaybackRequestStatus(status: .playing)
                @unknown default: ()
                }
            }
        }

        // TODO: proper handling of none/unknown states
        statusObserver = player.observe(\.currentItem?.status, options: [.new, .initial]) { [weak self] _, value in
            guard let self, let newValue = value.newValue else { return }
            switch newValue {
            case .failed:
                // Live failures route through the proxy's recovery: a transient startup
                // failure (transcode still warming up) reloads the same URL; a decode
                // failure escalates to a forced server-side re-encode.
                if baseItem.isLiveStream == true {
                    DispatchQueue.main.async {
                        self.handleLiveFailure()
                    }
                    return
                }
                if let error = self.player.error {
                    DispatchQueue.main.async {
                        self.manager?.error(ErrorMessage("AVPlayer error: \(error.localizedDescription)"))
                    }
                }
            case .none, .readyToPlay, .unknown:
                let startSeconds = max(.zero, (baseItem.startSeconds ?? .zero) - Duration.seconds(Defaults[.VideoPlayer.resumeOffset]))

                self.player.seek(
                    to: CMTimeMake(
                        value: startSeconds.components.seconds,
                        timescale: 1
                    ),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero,
                    completionHandler: { _ in
                        self.play()
                    }
                )
            @unknown default: ()
            }
        }
    }
}

// MARK: - AVPlayerView

extension AVMediaPlayerProxy {

    struct AVPlayerView: UIViewRepresentable {

        @EnvironmentObject
        private var proxy: AVMediaPlayerProxy
        @EnvironmentObject
        private var scrubbedSeconds: PublishedBox<Duration>

        func makeUIView(context: Context) -> UIView {
//            proxy.isScrubbing = context.environment.isScrubbing
//            proxy.scrubbedSeconds = $scrubbedSeconds.value
            UIAVPlayerView(proxy: proxy)
        }

        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    private class UIAVPlayerView: UIView {

        let proxy: AVMediaPlayerProxy

        init(proxy: AVMediaPlayerProxy) {
            self.proxy = proxy
            super.init(frame: .zero)
            layer.addSublayer(proxy.avPlayerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            proxy.avPlayerLayer.frame = bounds
        }
    }
}
