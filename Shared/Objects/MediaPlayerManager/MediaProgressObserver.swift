//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Factory
import Foundation
import JellyfinAPI

// TODO: respond properly to end of playback
//       - when item changes
// TODO: only send stop on manager stop, not per-item

class MediaProgressObserver: ViewModel, MediaPlayerObserver {

    weak var manager: MediaPlayerManager? {
        didSet {
            if let manager {
                setup(with: manager)
            }
        }
    }

    private let timer = PokeIntervalTimer()
    private var hasSentStart = false
    private var item: MediaPlayerItem?
    private var lastPlaybackRequestStatus: MediaPlayerManager.PlaybackRequestStatus = .playing

    init(item: MediaPlayerItem) {
        self.item = item
        super.init()
    }

    private func sendReport() {
        guard let item else { return }

        switch lastPlaybackRequestStatus {
        case .playing:
            if hasSentStart {
                sendProgressReport(for: item, seconds: manager?.seconds)
            } else {
                sendStartReport(for: item, seconds: manager?.seconds)
            }
        case .paused:
            sendProgressReport(for: item, seconds: manager?.seconds, isPaused: true)
        }
    }

    private func setup(with manager: MediaPlayerManager) {
        cancellables = []

        timer.sink { [weak self] in
            self?.sendReport()
            self?.timer.poke()
        }
        .store(in: &cancellables)

        manager.actions
            .sink { [weak self] in self?.didReceive(action: $0) }
            .store(in: &cancellables)

        manager.$playbackItem
            .sink { [weak self] in self?.playbackItemDidChange($0) }
            .store(in: &cancellables)

        manager.$playbackRequestStatus
            .sink { [weak self] in self?.playbackRequestStatusDidChange($0) }
            .store(in: &cancellables)
    }

    private func playbackItemDidChange(_ newItem: MediaPlayerItem?) {
        timer.poke()

        if let item, newItem !== item {
            // Don't send a stop report when the new item reuses the same live stream
            // (e.g. the live transcode fallback rebuilds the item but keeps the same
            // liveStreamID). Reporting stopped closes the shared live stream on the
            // server, tearing it out from under the new item's transcode.
            let oldLiveStreamID = item.mediaSource.liveStreamID
            let newLiveStreamID = newItem?.mediaSource.liveStreamID
            let liveStreamReused = oldLiveStreamID != nil && oldLiveStreamID == newLiveStreamID

            if !liveStreamReused {
                sendStopReport(for: item, seconds: manager?.seconds)
            }

            self.item = newItem
            self.hasSentStart = false
            sendReport()
        }
    }

    private func playbackRequestStatusDidChange(_ newStatus: MediaPlayerManager.PlaybackRequestStatus) {
        timer.poke()
        lastPlaybackRequestStatus = newStatus
    }

    // TODO: respond to error
    // TODO: respond properly to ended
    private func didReceive(action: MediaPlayerManager._Action) {
        switch action {
        case .stop:
            if let item {
                sendStopReport(for: item, seconds: manager?.seconds)
            }
            // Immediately kill this device's transcodes instead of waiting for the server's
            // ~60s kill timer. Otherwise a lingering live transcode keeps running on the GPU
            // and contends with the next playback on replay (two 4K encodes -> stutter).
            stopActiveEncodings()
            timer.stop()
            cancellables = []
            item = nil
        default: ()
        }
    }

    private func stopActiveEncodings() {
        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        guard let userSession = Container.shared.currentUserSession(),
              let deviceID = try? userSession.client.configuration.deviceID
        else { return }

        Task {
            // An empty play session id stops all of this device's transcodes. The server kills
            // them without closing the underlying live stream, so this is safe for live TV.
            let request = Paths.stopEncodingProcess(deviceID: deviceID, playSessionID: "")
            _ = try? await userSession.client.send(request)
        }
    }

    private func sendStartReport(for item: MediaPlayerItem, seconds: Duration?) {

        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        Task {
            var info = PlaybackStateInfo()
            info.audioStreamIndex = item.selectedAudioStreamIndex
            info.itemID = item.baseItem.id
            info.liveStreamID = item.mediaSource.liveStreamID
            info.mediaSourceID = item.mediaSource.id
            info.playSessionID = item.playSessionID
            info.positionTicks = seconds?.ticks
            info.sessionID = item.playSessionID
            info.subtitleStreamIndex = item.selectedSubtitleStreamIndex

            let request = Paths.reportPlaybackStart(info)
            try await send(request)

            self.hasSentStart = true
        }
    }

    private func sendStopReport(for item: MediaPlayerItem, seconds: Duration?) {

        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        Task {
            var info = PlaybackStopInfo()
            info.itemID = item.baseItem.id
            info.liveStreamID = item.mediaSource.liveStreamID
            info.mediaSourceID = item.mediaSource.id
            info.playSessionID = item.playSessionID
            info.positionTicks = seconds?.ticks
            info.sessionID = item.playSessionID

            let request = Paths.reportPlaybackStopped(info)
            try await send(request)
        }
    }

    private func sendProgressReport(for item: MediaPlayerItem, seconds: Duration?, isPaused: Bool = false) {

        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        Task {
            var info = PlaybackStateInfo()
            info.audioStreamIndex = item.selectedAudioStreamIndex
            info.isPaused = isPaused
            info.itemID = item.baseItem.id
            info.liveStreamID = item.mediaSource.liveStreamID
            info.mediaSourceID = item.mediaSource.id
            info.playSessionID = item.playSessionID
            info.positionTicks = seconds?.ticks
            info.sessionID = item.playSessionID
            info.subtitleStreamIndex = item.selectedSubtitleStreamIndex

            let request = Paths.reportPlaybackProgress(info)
            try await send(request)
        }
    }
}
