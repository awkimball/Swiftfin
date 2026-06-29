//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import SwiftUI

/// A single multi-view tile: the bare player layer plus a focusable overlay used to
/// select the tile, switch its audio focus, or pick a channel.
struct MultiViewTile: View {

    @ObservedObject
    var model: MultiViewTileModel

    let isActiveAudio: Bool
    let onFocusChange: (Bool) -> Void
    let onSelect: () -> Void

    @State
    private var isFocused = false

    var body: some View {
        GeometryReader { geometry in
            let video = videoSize(in: geometry.size)

            ZStack {
                Color.black

                // Full-bleed video, letterboxed within the cell by its true aspect.
                if model.channel != nil {
                    PlayerLayerView(proxy: model.proxy)
                } else {
                    placeholder
                }

                // Channel pill, placed in the letterbox bar so it never covers the picture.
                pill
                    .position(pillCenter(cell: geometry.size, video: video))
            }
        }
        .contentShape(Rectangle())
        .focusable(true) { focused in
            isFocused = focused
            onFocusChange(focused)
        }
        .focusEffectDisabled()
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle")
                .font(.system(size: 60))
            Text("Add Channel")
                .font(.headline)
        }
        .foregroundStyle(.white.opacity(0.8))
    }

    /// A tvOS pill: channel name plus a speaker glyph. The background stays a constant
    /// frosted translucency; the active-audio tile is shown by lighting up the icon, text,
    /// and accent border (with a soft accent glow) rather than a solid fill.
    private var pill: some View {
        HStack(spacing: 10) {
            Image(systemName: isActiveAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundStyle(isActiveAudio ? Color.accentColor : Color.white.opacity(0.45))

            Text(model.channel?.displayTitle ?? "Add Channel")
                .lineLimit(1)
                .foregroundStyle(isActiveAudio ? .white : .white.opacity(0.6))
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    isActiveAudio ? Color.accentColor : Color.white.opacity(0.15),
                    lineWidth: isActiveAudio ? 3 : 1
                )
        }
        .shadow(color: isActiveAudio ? Color.accentColor.opacity(0.6) : .clear, radius: 10)
        .scaleEffect(isActiveAudio ? 1.04 : 1)
        .animation(.easeOut(duration: 0.18), value: isActiveAudio)
    }

    /// The displayed picture size (assumes 16:9 live content) used to locate the letterbox bars.
    private func videoSize(in cell: CGSize) -> CGSize {
        let videoAspect: CGFloat = 16.0 / 9.0
        if cell.width / cell.height > videoAspect {
            // Height-constrained: full height, bars run left/right.
            return CGSize(width: cell.height * videoAspect, height: cell.height)
        } else {
            // Width-constrained: full width, bars run top/bottom.
            return CGSize(width: cell.width, height: cell.width / videoAspect)
        }
    }

    /// Centers the pill in the bottom letterbox bar when one exists (side-by-side / one-larger),
    /// the bottom of a side bar when bars run left/right (stacked), else just inside the bottom edge.
    private func pillCenter(cell: CGSize, video: CGSize) -> CGPoint {
        let bottomBar = (cell.height - video.height) / 2
        let sideBar = (cell.width - video.width) / 2
        let inset: CGFloat = 46

        if bottomBar >= inset {
            return CGPoint(x: cell.width / 2, y: cell.height / 2 + video.height / 2 + bottomBar / 2)
        } else if sideBar >= 80 {
            return CGPoint(x: sideBar / 2, y: cell.height - inset)
        } else {
            return CGPoint(x: cell.width / 2, y: cell.height - inset)
        }
    }
}

/// Renders an `AVPlayerLayer` directly (no transport controls), so several can be tiled.
private struct PlayerLayerView: UIViewRepresentable {

    let proxy: AVMediaPlayerProxy

    func makeUIView(context: Context) -> PlayerLayerUIView {
        PlayerLayerUIView(playerLayer: proxy.avPlayerLayer)
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {}
}

private final class PlayerLayerUIView: UIView {

    private let playerLayer: AVPlayerLayer

    init(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        super.init(frame: .zero)
        // Fill the cell width and letterbox by the video's true aspect; the pill is placed
        // in the resulting bars so it never overlaps the picture.
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
