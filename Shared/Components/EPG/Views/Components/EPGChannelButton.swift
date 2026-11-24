//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

struct EPGChannelButton: View {

    @AdaptiveLayout
    private var viewLayout

    @AppTheme
    private var theme

    @Environment(\.isSelected)
    private var isSelected

    @FocusState
    private var isFocused: Bool

    @SharedBaseItem
    var channel: BaseItemDto
    var onFocus: (() -> Void)?
    let action: () -> Void

    private var hasPrimaryImage: Bool {
        channel.imageTags?[ImageType.primary.rawValue] != nil
    }

    private var cardFill: Color {
        if isFocused {
            Color.primary.opacity(0.20)
        } else if isSelected {
            theme.accentColor.opacity(0.22)
        } else {
            Color.secondarySystemFill.opacity(0.55)
        }
    }

    private var borderColor: Color {
        if isFocused {
            Color.primary.opacity(0.90)
        } else if isSelected {
            theme.accentColor.opacity(0.75)
        } else {
            Color.primary.opacity(0.10)
        }
    }

    private var borderWidth: CGFloat {
        isFocused ? 2.5 : (isSelected ? 1.5 : 1)
    }

    @ContentBuilder
    private var logoView: some View {
        ImageView(channel.imageSource(
            .primary,
            itemID: channel.id,
            environment: ImageSourceOptions(maxWidth: viewLayout.isLarge ? 140 : 100)
        ))
        .image { image in
            image
                .aspectRatio(contentMode: .fit)
        }
        .failure {
            Color.clear
        }
        .placeholder { _ in
            Color.clear
        }
    }

    @ContentBuilder
    private var largeCardContent: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                if let channelNumber = channel.channelNumber, channelNumber.isNotEmpty {
                    Text(channelNumber)
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(isFocused ? 0.85 : 0.52))
                        .lineLimit(1)
                }

                Text(channel.displayTitle)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hasPrimaryImage {
                logoView
                    .frame(width: 72, height: 44)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ContentBuilder
    private var standardCardContent: some View {
        VStack(spacing: 4) {
            if hasPrimaryImage {
                logoView
                    .frame(height: 26)
            }

            HStack(spacing: 4) {
                if let channelNumber = channel.channelNumber, channelNumber.isNotEmpty {
                    Text(channelNumber)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Text(channel.displayTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ContentBuilder
    var body: some View {
        let layout = EPGLayout(viewLayout: viewLayout)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Button(action: action) {
            Group {
                if viewLayout.isLarge {
                    largeCardContent
                } else {
                    standardCardContent
                }
            }
            .background(cardFill, in: shape)
            .overlay {
                shape
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            }
            .padding(.trailing, viewLayout.isLarge ? 10 : 6)
            .padding(.leading, viewLayout.isLarge ? 4 : 4)
            .padding(.vertical, viewLayout.isLarge ? 4 : 3)
            .frame(width: layout.channelColumnWidth, height: layout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(EPGButtonStyle())
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused {
                onFocus?()
            }
        }
    }
}
