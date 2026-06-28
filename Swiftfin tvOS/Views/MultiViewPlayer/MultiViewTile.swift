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
        ZStack {
            Color.black

            if model.channel != nil {
                PlayerLayerView(proxy: model.proxy)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 60))
                    Text("Add Channel")
                        .font(.headline)
                }
                .foregroundStyle(.white.opacity(0.8))
            }

            // Audio indicator + channel label
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: isActiveAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    if let title = model.channel?.displayTitle {
                        Text(title)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.45))
                .opacity(model.channel == nil ? 0 : (isFocused || isActiveAudio ? 1 : 0))
            }
        }
        .contentShape(Rectangle())
        .focusable(true) { focused in
            isFocused = focused
            onFocusChange(focused)
        }
        .focusEffectDisabled()
        .onTapGesture(perform: onSelect)
        .overlay {
            // Only the focused tile draws a ring, inset so adjacent tiles don't
            // stack their borders into a seam down the center. Active-audio state
            // is conveyed by the speaker chip instead.
            if isFocused {
                Rectangle()
                    .inset(by: 3)
                    .strokeBorder(Color.accentColor, lineWidth: 6)
            }
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
