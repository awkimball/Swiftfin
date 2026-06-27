//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVKit
import Combine
import CoreMedia
import Factory
import JellyfinAPI
import Logging
import SwiftUI
import Transmission
import UIKit

// TODO: remove

struct NativeVideoPlayer: View {

    @Environment(\.presentationCoordinator)
    private var presentationCoordinator

    @InjectedObject(\.mediaPlayerManager)
    private var manager: MediaPlayerManager

    @LazyState
    private var proxy: AVMediaPlayerProxy

    @Router
    private var router

    init() {
        self._proxy = .init(wrappedValue: AVMediaPlayerProxy())
    }

    var body: some View {
        ZStack {

            Color.black

            switch manager.state {
            case .playback:
                NativeVideoPlayerView(proxy: proxy, manager: manager)
            default:
                ProgressView()
            }
        }
        .onAppear {
            manager.proxy = proxy
            manager.start()
        }
        .prefersStatusBarHidden()
        .backport
        .onChange(of: presentationCoordinator.isPresented) { _, isPresented in
            Container.shared.mediaPlayerManager.reset()
            guard !isPresented else { return }
            manager.stop()
        }
        .alert(
            L10n.error,
            isPresented: .constant(manager.error != nil)
        ) {
            Button(L10n.close, role: .cancel) {
                Container.shared.mediaPlayerManager.reset()
                router.dismiss()
            }
        } message: {
            Text(L10n.unableToLoadThisItem)
        }
        .onFinalDisappear {
            manager.stop()
        }
    }
}

extension NativeVideoPlayer {

    private struct NativeVideoPlayerView: UIViewControllerRepresentable {

        let proxy: AVMediaPlayerProxy
        let manager: MediaPlayerManager

        func makeUIViewController(context: Context) -> UINativeVideoPlayerViewController {
            UINativeVideoPlayerViewController(proxy: proxy, manager: manager)
        }

        func updateUIViewController(_ uiViewController: UINativeVideoPlayerViewController, context: Context) {}
    }

    private class UINativeVideoPlayerViewController: AVPlayerViewController {

        private let proxy: AVMediaPlayerProxy
        private let manager: MediaPlayerManager
        private var itemStatusObserver: NSKeyValueObservation?
        private var playbackInfoController: UIViewController?
        private var playbackInfoModel: PlaybackInfoModel?

        init(proxy: AVMediaPlayerProxy, manager: MediaPlayerManager) {
            self.proxy = proxy
            self.manager = manager

            super.init(nibName: nil, bundle: nil)

            player = proxy.player

            player?.allowsExternalPlayback = true
            player?.appliesMediaSelectionCriteriaAutomatically = false
            player?.usesExternalPlaybackWhileExternalScreenIsActive = true
            allowsPictureInPicturePlayback = true

            #if os(tvOS)
            appliesPreferredDisplayCriteriaAutomatically = true

            itemStatusObserver = player?.observe(
                \.currentItem?.status,
                options: [.initial, .new]
            ) { [weak self] player, _ in
                if player.currentItem?.status == .failed {
                    // Live fallback: a spliced/corrupt live source can't be direct-streamed
                    // into an fMP4 HLS track AVPlayer will decode. Rebuild forcing a server-side
                    // re-encode (no-ops for non-live or if already tried).
                    if let manager = self?.manager {
                        Task { @MainActor in
                            manager.fallbackToVideoTranscode()
                        }
                    }
                }
                guard player.currentItem?.status == .readyToPlay else { return }
                Task { @MainActor in
                    self?.rebuildTransportBarMenus()
                    self?.updateExternalMetadata()
                }
            }
            #endif

            #if !os(tvOS)
            updatesNowPlayingInfoCenter = false
            #endif
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        #if os(tvOS)

        @MainActor
        private func rebuildTransportBarMenus() {
            transportBarCustomMenuItems = [settingsMenu()]
        }

        @MainActor
        private func settingsMenu() -> UIMenu {
            let current = manager.playbackItem?.requestedBitrate ?? .max

            let qualityActions = PlaybackBitrate.allCases.map { bitrate in
                UIAction(
                    title: bitrate.displayTitle,
                    state: bitrate == current ? .on : .off
                ) { [weak self] _ in
                    self?.manager.setBitrate(bitrate: bitrate)
                }
            }

            let qualityMenu = UIMenu(
                title: "Quality",
                image: UIImage(systemName: "slider.horizontal.3"),
                children: qualityActions
            )

            let infoAction = UIAction(
                title: "Playback Information",
                image: UIImage(systemName: "info.circle"),
                state: playbackInfoController != nil ? .on : .off
            ) { [weak self] _ in
                self?.togglePlaybackInfo()
            }

            return UIMenu(
                title: "Settings",
                image: UIImage(systemName: "gearshape"),
                children: [
                    qualityMenu,
                    UIMenu(options: .displayInline, children: [infoAction]),
                ]
            )
        }

        @MainActor
        private func togglePlaybackInfo() {
            if let playbackInfoController {
                playbackInfoModel?.stop()
                playbackInfoModel = nil
                playbackInfoController.willMove(toParent: nil)
                playbackInfoController.view.removeFromSuperview()
                playbackInfoController.removeFromParent()
                self.playbackInfoController = nil
            } else if let contentOverlayView {
                let model = PlaybackInfoModel(player: player, item: manager.playbackItem)
                let host = UIHostingController(rootView: PlaybackInfoOverlay(model: model))
                host.view.backgroundColor = .clear

                addChild(host)
                contentOverlayView.addSubview(host.view)
                host.view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    host.view.leadingAnchor.constraint(
                        equalTo: contentOverlayView.safeAreaLayoutGuide.leadingAnchor,
                        constant: 50
                    ),
                    host.view.topAnchor.constraint(
                        equalTo: contentOverlayView.safeAreaLayoutGuide.topAnchor,
                        constant: 50
                    ),
                ])
                host.didMove(toParent: self)

                playbackInfoController = host
                playbackInfoModel = model
            }

            rebuildTransportBarMenus()
        }

        @MainActor
        private func updateExternalMetadata() {
            guard let posterURL = manager.item.imageSource(.primary, maxWidth: 600).url else { return }

            Task { @MainActor [weak self] in
                guard let self,
                      let (data, _) = try? await URLSession.shared.data(from: posterURL),
                      let currentItem = self.player?.currentItem
                else { return }

                var updated = currentItem.externalMetadata
                    .filter { $0.identifier != .commonIdentifierArtwork }
                updated.append(self.artworkMetadataItem(data: data))
                currentItem.externalMetadata = updated
            }
        }

        private func artworkMetadataItem(data: Data) -> AVMetadataItem {
            let metadataItem = AVMutableMetadataItem()
            metadataItem.identifier = .commonIdentifierArtwork
            metadataItem.value = data as NSData
            metadataItem.dataType = kCMMetadataBaseDataType_JPEG as String
            metadataItem.extendedLanguageTag = "und"
            return metadataItem
        }
        #endif
    }
}

#if os(tvOS)

@MainActor
private final class PlaybackInfoModel: ObservableObject {

    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }

    @Published
    private(set) var title: String = ""
    @Published
    private(set) var streamRows: [Row] = []
    @Published
    private(set) var sourceRows: [Row] = []
    @Published
    private(set) var transcodeRows: [Row] = []

    private weak var player: AVPlayer?
    private let item: MediaPlayerItem?
    private let sessionProvider: PlaybackInformationProvider?
    private var timer: Timer?
    private var sessionCancellable: AnyCancellable?

    init(player: AVPlayer?, item: MediaPlayerItem?) {
        self.player = player
        self.item = item
        self.title = item?.baseItem.displayTitle ?? ""

        if let itemID = item?.baseItem.id {
            let provider = PlaybackInformationProvider(itemID: itemID)
            self.sessionProvider = provider
            self.sessionCancellable = provider.$currentSession
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
        } else {
            self.sessionProvider = nil
        }

        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sessionCancellable = nil
    }

    private func refresh() {
        guard let item else { return }
        streamRows = buildStreamRows(item)
        sourceRows = buildSourceRows(item)
        transcodeRows = buildTranscodeRows()
    }

    private func buildStreamRows(_ item: MediaPlayerItem) -> [Row] {
        var rows: [Row] = []

        let method = sessionProvider?.currentSession?.playMethodDisplayTitle
            ?? (item.mediaSource.transcodingURL != nil ? "Transcode" : "Direct Play")
        rows.append(Row(label: "Method", value: method))

        if let container = item.mediaSource.transcodingContainer ?? item.mediaSource.container {
            rows.append(Row(label: "Container", value: container.uppercased()))
        }

        if let event = player?.currentItem?.accessLog()?.events.last {
            if event.indicatedBitrate > 0 {
                rows.append(Row(label: "Bitrate", value: Int(event.indicatedBitrate).formatted(.bitRate)))
            }
            if event.observedBitrate > 0 {
                rows.append(Row(label: "Network Rate", value: Int(event.observedBitrate).formatted(.bitRate)))
            }
        }

        return rows
    }

    private func buildSourceRows(_ item: MediaPlayerItem) -> [Row] {
        let video = item.videoStreams.first
        let audio = item.audioStreams.first { $0.index == item.selectedAudioStreamIndex } ?? item.audioStreams.first
        var rows: [Row] = []

        if let codec = video?.codec {
            let value = video?.profile.map { "\(codec.uppercased()) \($0)" } ?? codec.uppercased()
            rows.append(Row(label: "Video", value: value))
        }

        if let width = video?.width, let height = video?.height {
            rows.append(Row(label: "Resolution", value: "\(width)x\(height)"))
        }

        if let bitRate = video?.bitRate {
            rows.append(Row(label: "Video Bitrate", value: bitRate.formatted(.bitRate)))
        }

        if let range = video?.videoRangeType {
            rows.append(Row(label: "Range", value: range.rawValue))
        }

        if let codec = audio?.codec {
            rows.append(Row(label: "Audio", value: codec.uppercased()))
        }

        if let layout = audio?.channelLayout {
            rows.append(Row(label: "Channels", value: layout))
        } else if let channels = audio?.channels {
            rows.append(Row(label: "Channels", value: channels.description))
        }

        if let bitRate = audio?.bitRate {
            rows.append(Row(label: "Audio Bitrate", value: bitRate.formatted(.bitRate)))
        }

        if let sampleRate = audio?.sampleRate {
            rows.append(Row(label: "Sample Rate", value: "\(sampleRate) Hz"))
        }

        return rows
    }

    private func buildTranscodeRows() -> [Row] {
        guard let info = sessionProvider?.currentSession?.transcodingInfo else { return [] }
        var rows: [Row] = []

        if let codec = info.videoCodec {
            let value = info.isVideoDirect == true ? "\(codec.uppercased()) (Direct)" : codec.uppercased()
            rows.append(Row(label: "Video", value: value))
        }

        if let width = info.width, let height = info.height {
            rows.append(Row(label: "Resolution", value: "\(width)x\(height)"))
        }

        if let bitrate = info.bitrate {
            rows.append(Row(label: "Bitrate", value: bitrate.formatted(.bitRate)))
        }

        if let framerate = info.framerate {
            rows.append(Row(label: "Frame Rate", value: "\(Double(framerate).formatted(.number.precision(.fractionLength(0 ... 3)))) fps"))
        }

        if let codec = info.audioCodec {
            let value = info.isAudioDirect == true ? "\(codec.uppercased()) (Direct)" : codec.uppercased()
            rows.append(Row(label: "Audio", value: value))
        }

        if let channels = info.audioChannels {
            rows.append(Row(label: "Channels", value: channels.description))
        }

        rows.append(Row(label: "Acceleration", value: accelerationDescription(info)))

        return rows
    }

    private func accelerationDescription(_ info: TranscodingInfo) -> String {
        if info.isVideoDirect == true, info.isAudioDirect == true {
            return "None (Remux)"
        }

        guard let type = info.hardwareAccelerationType else { return "Unknown" }

        switch type {
        case .none:
            return "Software (CPU)"
        case .videotoolbox:
            return "VideoToolbox (Hardware)"
        default:
            return "\(type.rawValue.uppercased()) (Hardware)"
        }
    }
}

private struct PlaybackInfoOverlay: View {

    @ObservedObject
    var model: PlaybackInfoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.title.isEmpty {
                Text(model.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }

            section("Stream", model.streamRows)
            section("Source", model.sourceRows)
            section("Transcode", model.transcodeRows)
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [PlaybackInfoModel.Row]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 20)
                        Text(row.value)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption2)
                }
            }
        }
    }
}

#endif
