//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVKit
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
            transportBarCustomMenuItems = [qualityMenu()]
        }

        @MainActor
        private func qualityMenu() -> UIMenu {
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
                image: UIImage(systemName: "dial.medium"),
                children: qualityActions
            )

            return UIMenu(
                title: "Settings",
                image: UIImage(systemName: "gearshape"),
                children: [qualityMenu]
            )
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
