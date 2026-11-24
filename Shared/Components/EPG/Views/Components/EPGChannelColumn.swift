//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI
@_spi(Advanced) import SwiftUIIntrospect

struct EPGChannelColumn: View {

    @AdaptiveLayout
    private var viewLayout

    @AppTheme
    private var theme

    @FocusState
    private var isNowButtonFocused: Bool

    let bottomInset: CGFloat
    let proxy: EPGScrollProxy
    let selectedChannelID: String?
    let viewModel: EPGViewModel
    var onFocusChannel: ((BaseItemDto) -> Void)?
    let action: (BaseItemDto) -> Void

    @ContentBuilder
    var body: some View {
        let layout = EPGLayout(viewLayout: viewLayout)

        VStack(spacing: 0) {
            ZStack(alignment: viewLayout.isLarge ? .leading : .center) {
                if viewModel.now >= viewModel.startDate, viewModel.now <= viewModel.endDate {
                    Button {
                        proxy.scrollTo(
                            centering: layout.width(from: viewModel.startDate, to: viewModel.now)
                        )
                    } label: {
                        HStack(spacing: viewLayout.isLarge ? 10 : 5) {
                            Circle()
                                .fill(Color(uiColor: .systemRed))
                                .frame(width: viewLayout.isLarge ? 10 : 6, height: viewLayout.isLarge ? 10 : 6)

                            Text(L10n.onNow)
                                .font(.system(size: viewLayout.isLarge ? 22 : 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, viewLayout.isLarge ? 20 : 10)
                        .padding(.vertical, viewLayout.isLarge ? 9 : 5)
                        .backport
                        .glassEffect(
                            .regular.selection(
                                tint: isNowButtonFocused ? .white : nil,
                                foregroundColor: isNowButtonFocused ? .black : .primary
                            )
                            .interactive(),
                            in: .capsule
                        )
                    }
                    .buttonStyle(EPGButtonStyle())
                    .focused($isNowButtonFocused)
                    .padding(.leading, viewLayout.isLarge ? 4 : 0)
                }
            }
            .frame(width: layout.channelColumnWidth, height: layout.rulerHeight)

            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.channels) { channel in
                        EPGChannelButton(
                            channel: channel.snapshot,
                            onFocus: { onFocusChannel?(channel.snapshot) },
                            action: { action(channel.snapshot) }
                        )
                        .isSelected(channel.itemID == selectedChannelID)
                    }
                }
                .tint(theme.accentColor)
                .padding(.bottom, bottomInset)
            }
            .scrollIndicators(.hidden)
            .introspect(.scrollView, on: .iOS(.v18...), .tvOS(.v18...)) { scrollView in
                scrollView.contentInsetAdjustmentBehavior = viewLayout.isLarge ? .never : .automatic

                proxy.registerVertical(scrollView)
            }
        }
        .frame(width: layout.channelColumnWidth)
        .focusSection()
    }
}
