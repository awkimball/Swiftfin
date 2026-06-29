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
        private static let logger = Logger.swiftfin()
        private var selectedSubtitleRenditionOffset: Int?
        private var playbackInfoController: UIViewController?
        private var playbackInfoModel: PlaybackInfoModel?
        #if !os(tvOS)
        private var menuButton: UIButton?
        private var overflowButton: UIButton?
        private var customMenuItems: [UIMenuElement] = []
        private var didObserveOverflowMenu = false
        private var didAttachMenuButton = false
        private static let customMenuIdentifier = UIMenu.Identifier("dev.addison.swiftfin.nativePlayerMenu")
        private static let overflowMenuKVOContext = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        #endif

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
            #else
            updatesNowPlayingInfoCenter = false
            #endif

            itemStatusObserver = player?.observe(
                \.currentItem?.status,
                options: [.initial, .new]
            ) { [weak self] player, _ in
                guard player.currentItem?.status == .readyToPlay else { return }
                Task { @MainActor in
                    self?.rebuildTransportBarMenus()
                    #if os(tvOS)
                    self?.updateExternalMetadata()
                    #endif
                }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        #if !os(tvOS)
        deinit {
            if didObserveOverflowMenu {
                overflowButton?.removeObserver(self, forKeyPath: "menu", context: Self.overflowMenuKVOContext)
            }
        }

        /// AVKit owns the overflow button and rebuilds its `menu` whenever its state changes (tracks
        /// load, route/PiP changes, controls re-show), which drops our injected items. Observing the
        /// `menu` property lets us re-inject whenever AVKit replaces it. `injectIntoOverflowMenu` is
        /// idempotent (skips when our items are already present), so restoring after AVKit's rebuild
        /// can't loop against our own update.
        override nonisolated func observeValue(
            forKeyPath keyPath: String?,
            of object: Any?,
            change: [NSKeyValueChangeKey: Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            guard context == Self.overflowMenuKVOContext else {
                super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.injectIntoOverflowMenu(force: false)
            }
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            setupMenuButton()
            rebuildTransportBarMenus()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attachMenuButtonToControls()
        }

        /// iOS `AVPlayerViewController` has no transport-bar custom menu API (that's tvOS only),
        /// so the shared audio/subtitle/settings `UIMenu`s are hosted on an overlay gear button
        /// that we splice into the native controls next to the "•••" overflow menu.
        private func setupMenuButton() {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            button.setImage(
                UIImage(systemName: "gearshape.fill", withConfiguration: symbolConfiguration),
                for: .normal
            )
            button.tintColor = .white
            button.showsMenuAsPrimaryAction = true
            menuButton = button
        }

        /// Splices the gear button into the native controls. `AVPlayerViewController` exposes no
        /// controls API on iOS, but the controls' auxiliary row (`AVMobileAuxiliaryControlsView`,
        /// which holds the "•••" overflow button) is a stack view. Inserting the gear as a real
        /// arranged control makes the row grow to include it, so it fades with the chrome, stays
        /// hit-testable (a button merely placed beside the content-sized row would fall outside its
        /// bounds and receive no touches), and sits natively next to the "•••". If the row isn't a
        /// stack view (e.g. a future iOS reworks it), the custom items are folded into the native
        /// "•••" overflow menu instead. The row may not exist on the first pass, so this retries.
        private func attachMenuButtonToControls(attempt: Int = 0) {
            guard !didAttachMenuButton, let button = menuButton else { return }

            guard let auxiliaryRow = Self.findView(in: view, classNameContains: "AuxiliaryControlsView") else {
                if attempt < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.attachMenuButtonToControls(attempt: attempt + 1)
                    }
                } else {
                    Self.logger.warning("Native iOS player: auxiliary controls row not found; gear button omitted")
                }
                return
            }

            didAttachMenuButton = true

            if let stack = auxiliaryRow as? UIStackView {
                stack.insertArrangedSubview(button, at: 0)
                NSLayoutConstraint.activate([
                    button.widthAnchor.constraint(equalToConstant: 23),
                    button.heightAnchor.constraint(equalToConstant: 23),
                ])
                rebuildTransportBarMenus()
            } else if let overflow = Self.findOverflowButton(in: auxiliaryRow) {
                // The gear can't be hosted as a real control, so fold our items into the native
                // "•••" menu (preserving its existing entries like Playback Speed) instead, and observe
                // the button so we can re-inject when AVKit rebuilds its menu.
                menuButton = nil
                overflowButton = overflow
                overflow.addObserver(self, forKeyPath: "menu", options: [.new], context: Self.overflowMenuKVOContext)
                didObserveOverflowMenu = true
                rebuildTransportBarMenus()
                Self.logger.info("Native iOS player: folded custom menu into the ••• overflow control (auto re-injecting)")
            } else {
                Self.logger.warning("Native iOS player: could not host custom menu")
            }
        }

        /// Applies the built menu to whichever host is active: the gear button when it was spliced
        /// into the controls, or the native "•••" overflow button when we fell back to it.
        private func applyMenu(_ items: [UIMenuElement]) {
            customMenuItems = items
            menuButton?.menu = UIMenu(title: "", children: items)
            if overflowButton != nil {
                injectIntoOverflowMenu(force: true)
            }
        }

        /// Folds the custom items into the native "•••" overflow menu, after AVKit's own entries.
        /// Reads the button's CURRENT children live (rather than a stale snapshot) so AVKit's dynamic
        /// entries — including any deferred track lists — stay intact, then strips any previously
        /// injected copy of ours (matched by identifier) and re-appends the latest items. When
        /// `force` is false it no-ops if our items are already present, so the KVO re-injection is
        /// safe to call repeatedly without looping.
        private func injectIntoOverflowMenu(force: Bool) {
            guard let overflowButton, !customMenuItems.isEmpty else { return }

            let currentChildren = overflowButton.menu?.children ?? []
            let alreadyPresent = currentChildren.contains { ($0 as? UIMenu)?.identifier == Self.customMenuIdentifier }
            guard force || !alreadyPresent else { return }

            let nativeChildren = currentChildren.filter { ($0 as? UIMenu)?.identifier != Self.customMenuIdentifier }
            let customMenu = UIMenu(
                title: "",
                image: nil,
                identifier: Self.customMenuIdentifier,
                options: .displayInline,
                children: customMenuItems
            )
            overflowButton.menu = UIMenu(title: "", children: nativeChildren + [customMenu])
        }

        /// Recursively searches a view subtree for the first descendant whose class name contains
        /// the given substring.
        private static func findView(in view: UIView, classNameContains needle: String) -> UIView? {
            if String(describing: type(of: view)).contains(needle) {
                return view
            }
            for subview in view.subviews {
                if let found = findView(in: subview, classNameContains: needle) {
                    return found
                }
            }
            return nil
        }

        /// Recursively searches for the native "•••" overflow button (`AVControlOverflowButton`).
        private static func findOverflowButton(in view: UIView) -> UIButton? {
            if let button = view as? UIButton, String(describing: type(of: view)).contains("OverflowButton") {
                return button
            }
            for subview in view.subviews {
                if let found = findOverflowButton(in: subview) {
                    return found
                }
            }
            return nil
        }
        #endif

        @MainActor
        private func rebuildTransportBarMenus() {
            var items: [UIMenuElement] = []
            if let audioMenu = audioMenu() {
                items.append(audioMenu)
            }
            if let subtitleMenu = subtitleMenu() {
                items.append(subtitleMenu)
            }
            items.append(settingsMenu())

            #if os(tvOS)
            transportBarCustomMenuItems = items
            #else
            applyMenu(items)
            #endif
        }

        /// Lists the source's audio tracks. Selecting one drives the existing track-change path,
        /// which for a transcoded stream rebuilds the item with the new AudioStreamIndex (the server
        /// muxes a single audio track, so an in-place switch isn't possible) while preserving position.
        @MainActor
        private func audioMenu() -> UIMenu? {
            guard let item = manager.playbackItem else { return nil }

            let audioStreams = item.audioStreams
            guard audioStreams.count > 1 else { return nil }

            let current = item.selectedAudioStreamIndex
            let actions = audioStreams.compactMap { stream -> UIAction? in
                guard let index = stream.index else { return nil }
                return UIAction(
                    title: stream.displayTitle ?? stream.language ?? "Audio \(index)",
                    state: index == current ? .on : .off
                ) { [weak self] _ in
                    self?.manager.playbackItem?.selectedAudioStreamIndex = index
                }
            }

            return UIMenu(
                title: "Audio",
                image: UIImage(systemName: "waveform"),
                children: actions
            )
        }

        /// Lists the source's text subtitle tracks plus an "Off" entry. AVKit's native picker labels every
        /// option by LANGUAGE (so the three English tracks all read "English" and collapse into one), but
        /// they are distinct, ordered options in the legible selection group. The server emits one rendition
        /// per text subtitle in stream order, so each menu entry maps positionally to its group option,
        /// reaching tracks the picker hides.
        @MainActor
        private func subtitleMenu() -> UIMenu? {
            guard let item = manager.playbackItem else { return nil }

            let streams = item.subtitleStreams.filter { $0.isTextSubtitleStream == true }
            guard streams.isNotEmpty else { return nil }

            let offAction = UIAction(
                title: "Off",
                state: selectedSubtitleRenditionOffset == nil ? .on : .off
            ) { [weak self] _ in
                self?.selectSubtitle(at: nil)
            }

            let actions = streams.enumerated().map { offset, stream in
                UIAction(
                    title: stream.displayTitle ?? stream.language ?? "Subtitle \(offset + 1)",
                    state: selectedSubtitleRenditionOffset == offset ? .on : .off
                ) { [weak self] _ in
                    self?.selectSubtitle(at: offset)
                }
            }

            return UIMenu(
                title: "Subtitles",
                image: UIImage(systemName: "captions.bubble"),
                children: [offAction] + actions
            )
        }

        /// Selects (or, when `nil`, disables) a subtitle by its position in the legible selection group,
        /// which matches the order the server lists the text subtitle renditions. Position is used because
        /// `AVMediaSelectionOption.displayName` only exposes the language, not the track's full title, so
        /// same-language tracks can't be told apart by name.
        @MainActor
        private func selectSubtitle(at offset: Int?) {
            guard let playerItem = player?.currentItem else { return }

            selectedSubtitleRenditionOffset = offset
            rebuildTransportBarMenus()

            Task { @MainActor in
                guard let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible) else {
                    Self.logger.warning("Subtitle select: no legible media selection group")
                    return
                }

                guard let offset else {
                    playerItem.select(nil, in: group)
                    return
                }

                guard offset < group.options.count else {
                    Self.logger.warning("Subtitle select: offset \(offset) out of range (\(group.options.count) options)")
                    return
                }

                playerItem.select(group.options[offset], in: group)
            }
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
                    host.view.centerYAnchor.constraint(
                        equalTo: contentOverlayView.safeAreaLayoutGuide.centerYAnchor
                    ),
                ])
                host.didMove(toParent: self)

                playbackInfoController = host
                playbackInfoModel = model
            }

            rebuildTransportBarMenus()
        }

        #if os(tvOS)
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

@MainActor
private final class PlaybackInfoModel: ObservableObject {

    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }

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
            // Prefer the actual delivered media bitrate (bytes downloaded per second of
            // media) over indicatedBitrate, which is only the playlist-advertised nominal
            // BANDWIDTH and stays at the requested ceiling even when the encoder (e.g. ICQ
            // HDR passthrough) emits far less.
            if let actual = actualMediaBitrate() {
                rows.append(Row(label: "Bitrate", value: actual.formatted(.bitRate)))
            } else if event.indicatedBitrate > 0 {
                rows.append(Row(label: "Bitrate", value: Int(event.indicatedBitrate).formatted(.bitRate)))
            }
            if event.observedBitrate > 0 {
                rows.append(Row(label: "Network Rate", value: Int(event.observedBitrate).formatted(.bitRate)))
            }
        }

        return rows
    }

    /// The actual delivered media bitrate (bytes of media downloaded per second of media),
    /// reflecting the real transcode/stream output rather than the nominal advertised rate.
    private func actualMediaBitrate() -> Int? {
        guard let event = player?.currentItem?.accessLog()?.events.last,
              event.numberOfBytesTransferred > 0,
              event.segmentsDownloadedDuration > 0.5
        else { return nil }
        return Int(Double(event.numberOfBytesTransferred) * 8 / event.segmentsDownloadedDuration)
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

        // Server-reported target/ceiling; the real output rate is the Stream "Bitrate"
        // computed from the player's access log.
        if let bitrate = info.bitrate {
            rows.append(Row(label: "Max Bitrate", value: bitrate.formatted(.bitRate)))
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
            section("Stream", model.streamRows)
            section("Source", model.sourceRows)
            section("Transcode", model.transcodeRows)
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
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
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
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
