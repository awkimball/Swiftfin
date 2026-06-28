//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

/// Plays two live channels at once in a configurable grid.
///
/// Each tile drives its own player; focusing a tile makes it the active audio source.
/// Selecting a tile opens a channel picker to fill or change it.
struct MultiViewPlayer: View {

    @Environment(\.dismiss)
    private var dismiss

    @StateObject
    private var tileA = MultiViewTileModel()
    @StateObject
    private var tileB = MultiViewTileModel()

    @State
    private var layout: MultiViewLayout = .sideBySide
    @State
    private var activeAudioTile: Int = 0
    @State
    private var primaryTile: Int = 0
    @State
    private var pickerTarget: PickerTarget?
    @State
    private var showControls = false

    let initialChannels: [BaseItemDto]

    private struct PickerTarget: Identifiable {
        let id: Int
    }

    private var tiles: [MultiViewTileModel] {
        [tileA, tileB]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                let frames = layout.frames(
                    in: geometry.size,
                    count: tiles.count,
                    primaryIndex: primaryTile
                )

                ZStack(alignment: .topLeading) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, model in
                        MultiViewTile(
                            model: model,
                            isActiveAudio: activeAudioTile == index,
                            onFocusChange: { focused in
                                if focused { setActiveAudio(index) }
                            },
                            onSelect: {
                                pickerTarget = PickerTarget(id: index)
                            }
                        )
                        .frame(width: frames[index].width, height: frames[index].height)
                        .offset(x: frames[index].minX, y: frames[index].minY)
                    }
                }
            }
            .ignoresSafeArea()

            controlsBar
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: loadInitial)
        .onDisappear {
            tileA.stop()
            tileB.stop()
        }
        .onExitCommand {
            withAnimation { showControls.toggle() }
        }
        .fullScreenCover(item: $pickerTarget) { target in
            MultiViewChannelPicker { channel in
                tiles[target.id].play(channel: channel)
                // Newly filled tile becomes the audio source if none is playing yet.
                if tiles.allSatisfy({ $0.channel == nil }) || tiles[activeAudioTile].channel == nil {
                    setActiveAudio(target.id)
                }
            }
        }
    }

    @ViewBuilder
    private var controlsBar: some View {
        HStack(spacing: 24) {
            ForEach(MultiViewLayout.allCases) { option in
                controlButton(
                    title: option.title,
                    systemImage: option.systemImage,
                    isOn: layout == option
                ) {
                    withAnimation { layout = option }
                }
            }

            controlButton(title: "Swap", systemImage: "arrow.left.arrow.right") {
                primaryTile = primaryTile == 0 ? 1 : 0
            }

            controlButton(title: "Close", systemImage: "xmark") {
                dismiss()
            }
        }
        .padding(30)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(.bottom, 50)
        .opacity(showControls ? 1 : 0)
        .animation(.easeInOut, value: showControls)
    }

    @ViewBuilder
    private func controlButton(
        title: String,
        systemImage: String,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(isOn ? Color.accentColor : Color.white.opacity(0.15))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func setActiveAudio(_ index: Int) {
        activeAudioTile = index
        for (i, tile) in tiles.enumerated() {
            tile.setActiveAudio(i == index)
        }
    }

    private func loadInitial() {
        for (index, channel) in initialChannels.prefix(tiles.count).enumerated() {
            tiles[index].play(channel: channel)
        }
        setActiveAudio(0)
    }
}
