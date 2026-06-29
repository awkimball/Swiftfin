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
import Logging
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

    private static let logger = Logger.swiftfin()

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
    private var forcedLiveWarmReload: Task<Void, Never>?

    // A live transcode needs a few seconds to produce its first segments; AVPlayer can
    // fail the item while the variant playlist still 404s. Reload the same URL (keeping
    // the play session / live stream alive) rather than rebuilding, which would tear the
    // live stream down and starve the transcode.
    private let liveReloadDelay: TimeInterval = 1
    private let liveStartupTimeout: TimeInterval = 8
    private let liveReloadTimeout: TimeInterval = 4

    // Total wall-clock budget to get a live source playing before escalating to a forced
    // server-side re-encode. A healthy direct-stream copy with a slow segment cold-start
    // plays within this window via warm reloads; an undecodable copy (e.g. HDR/DoVi HEVC)
    // that silently stalls without ever emitting a .failed error falls back promptly
    // instead of reloading for tens of seconds.
    private let liveRecoveryBudget: TimeInterval = 8
    private let forcedLiveRecoveryBudget: TimeInterval = 20
    private var liveRecoveryDeadline: Date?

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

    // tvOS uses AVPlayerViewController, which manages MPNowPlayingInfoCenter and the
    // Siri-remote transport natively (we feed it AVPlayerItem.externalMetadata). Running
    // NowPlayableObserver there double-writes Now Playing info, so AVKit re-overrides it
    // several times a second — flooding the console with warnings and churning the main
    // thread. Only attach it where we drive Now Playing ourselves (non-tvOS).
    #if os(tvOS)
    var observers: [any MediaPlayerObserver] = []
    #else
    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]
    #endif

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
        forcedLiveWarmReload?.cancel()
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

    func prepareForLiveFallback() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        liveStartupWatchdog?.cancel()
        liveStartupWatchdog = nil
        forcedLiveWarmReload?.cancel()
        forcedLiveWarmReload = nil
        liveRecoveryDeadline = nil
        currentLiveItem = nil
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
        forcedLiveWarmReload?.cancel()
        forcedLiveWarmReload = nil
        liveRecoveryDeadline = nil
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

    private func armLiveStartupWatchdog(timeout: TimeInterval) {
        liveStartupWatchdog?.cancel()
        liveStartupWatchdog = nil
        guard currentLiveItem != nil else { return }

        liveStartupWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.player.timeControlStatus != .playing else { return }

                // A healthy live source (e.g. a direct-stream copy) can still be producing
                // its first segments here, so AVPlayer just hasn't reached the live edge yet.
                // Reload the now-warm URL while we're still within the recovery budget; once
                // it elapses, an undecodable copy that silently stalls (no .failed error) is
                // downgraded to a forced server re-encode rather than reloading indefinitely.
                if self.canAttemptLiveRecovery || self.currentLiveItem?.forcedVideoReencode == true {
                    if self.currentLiveItem?.forcedVideoReencode == true, !self.canAttemptLiveRecovery {
                        Self.logger.info(
                            "Reloading warmed forced live transcode after recovery budget",
                            metadata: self.liveFailureMetadata()
                        )
                    }
                    self.reloadLiveItem(rearmTimeout: self.liveReloadTimeout)
                } else {
                    self.manager?.fallbackToVideoTranscode()
                }
            }
        }
    }

    private func handleLiveFailure() {
        guard currentLiveItem != nil else {
            Self.logger.warning("AVPlayer live failure with no current live item", metadata: liveFailureMetadata())
            manager?.fallbackToVideoTranscode()
            return
        }

        Self.logger.warning("AVPlayer live failure", metadata: liveFailureMetadata())

        // Live HLS can fail or stall before the server has produced enough initial fMP4
        // segments. Prefer reloading the same warmed URL during the recovery window so we
        // keep one play session and one server job alive; only escalate after the budget.
        if canAttemptLiveRecovery || currentLiveItem?.forcedVideoReencode == true {
            Self.logger.info("Reloading live item during recovery window", metadata: liveFailureMetadata())
            reloadLiveItem(rearmTimeout: liveReloadTimeout)
        } else {
            Self.logger.warning("Live recovery budget exhausted; falling back to forced video transcode", metadata: liveFailureMetadata())
            manager?.fallbackToVideoTranscode()
        }
    }

    private func liveFailureMetadata() -> Logger.Metadata {
        let itemError = player.currentItem?.error as NSError?
        let playerError = player.error as NSError?
        let lastErrorEvent = player.currentItem?.errorLog()?.events.last

        return [
            "itemStatus": "\(player.currentItem?.status.rawValue ?? -1)",
            "timeControlStatus": "\(player.timeControlStatus.rawValue)",
            "itemErrorDomain": "\(itemError?.domain ?? "nil")",
            "itemErrorCode": "\(itemError?.code ?? 0)",
            "itemErrorDescription": "\(itemError?.localizedDescription ?? "nil")",
            "playerErrorDomain": "\(playerError?.domain ?? "nil")",
            "playerErrorCode": "\(playerError?.code ?? 0)",
            "errorLogDomain": "\(lastErrorEvent?.errorDomain ?? "nil")",
            "errorLogCode": "\(lastErrorEvent?.errorStatusCode ?? 0)",
            "errorLogComment": "\(lastErrorEvent?.errorComment ?? "nil")",
            "uri": "\(lastErrorEvent?.uri ?? "nil")",
            "canAttemptLiveRecovery": "\(canAttemptLiveRecovery)"
        ]
    }

    /// Whether there is still time in the live startup recovery budget to attempt another
    /// warm reload before escalating to a forced server-side re-encode.
    private var canAttemptLiveRecovery: Bool {
        guard let deadline = liveRecoveryDeadline else { return false }
        return Date() < deadline
    }

    /// Reload the current live URL (now warm) to recover from a transient startup stall,
    /// keeping the play session / live stream alive.
    private func reloadLiveItem(rearmTimeout: TimeInterval) {
        guard let liveItem = currentLiveItem else { return }

        liveStartupWatchdog?.cancel()
        liveStartupWatchdog = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + liveReloadDelay) { [weak self] in
            guard let self, self.currentLiveItem === liveItem else { return }
            self.player.replaceCurrentItem(with: self.makeAVPlayerItem(for: liveItem))
            self.armLiveStartupWatchdog(timeout: rearmTimeout)
            self.play()
        }
    }

    private func armForcedLiveWarmReloadIfNeeded(for item: MediaPlayerItem) {
        forcedLiveWarmReload?.cancel()
        forcedLiveWarmReload = nil

        guard item.baseItem.isLiveStream == true, item.forcedVideoReencode else { return }

        forcedLiveWarmReload = Task { [weak self, weak item] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, let item, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.currentLiveItem === item,
                      self.player.timeControlStatus != .playing
                else { return }

                Self.logger.info("Reloading warmed forced live transcode")
                self.player.replaceCurrentItem(with: self.makeAVPlayerItem(for: item))
                self.armLiveStartupWatchdog(timeout: self.liveReloadTimeout)
                self.play()
            }
        }
    }

    private func playNew(item: MediaPlayerItem) {
        let baseItem = item.baseItem
        let isLiveStream = baseItem.isLiveStream == true

        currentLiveItem = isLiveStream ? item : nil
        liveRecoveryDeadline = isLiveStream
            ? Date().addingTimeInterval(item.forcedVideoReencode ? forcedLiveRecoveryBudget : liveRecoveryBudget)
            : nil

        let newAVPlayerItem = makeAVPlayerItem(for: item)

        player.replaceCurrentItem(with: newAVPlayerItem)

        armLiveStartupWatchdog(timeout: liveStartupTimeout)
        armForcedLiveWarmReloadIfNeeded(for: item)

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
                    self?.forcedLiveWarmReload?.cancel()
                    self?.forcedLiveWarmReload = nil
                    self?.liveRecoveryDeadline = nil
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
