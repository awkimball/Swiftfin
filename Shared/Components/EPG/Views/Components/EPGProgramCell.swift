//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import JellyfinAPI
import SwiftUI

struct EPGProgramCell: View {

    @State
    private var stickyOffset: CGFloat

    let scrollState: EPGScrollState
    let cellWidth: CGFloat
    let isLarge: Bool
    let isCurrent: Bool
    let isPast: Bool
    let isFocused: Bool
    let accentColor: Color
    let action: () -> Void

    private let leadingOffset: CGFloat
    private let block: ProgramBlock
    private var presentation: ProgramCellPresentation {
        ProgramCellPresentation(block: block)
    }

    init(
        scrollState: EPGScrollState,
        block: ProgramBlock,
        leadingOffset: CGFloat,
        cellWidth: CGFloat,
        isLarge: Bool,
        isCurrent: Bool,
        isPast: Bool = false,
        isFocused: Bool,
        accentColor: Color,
        action: @escaping () -> Void
    ) {
        self.scrollState = scrollState
        self.cellWidth = cellWidth
        self.isLarge = isLarge
        self.isCurrent = isCurrent
        self.isPast = isPast
        self.isFocused = isFocused
        self.accentColor = accentColor
        self.action = action
        self.leadingOffset = leadingOffset
        self.block = block
        self._stickyOffset = State(
            initialValue: max(0, scrollState.visibleLeadingOffset - leadingOffset)
        )
    }

    private var backgroundColor: Color {
        if isFocused {
            isCurrent ? accentColor.opacity(0.38) : Color.primary.opacity(0.20)
        } else if isCurrent {
            accentColor.opacity(0.18)
        } else if isPast {
            Color.secondarySystemFill.opacity(0.28)
        } else {
            Color.secondarySystemFill.opacity(0.55)
        }
    }

    private var borderColor: Color {
        if isFocused {
            Color.primary.opacity(0.92)
        } else if isCurrent {
            accentColor.opacity(0.42)
        } else if isPast {
            Color.primary.opacity(0.05)
        } else {
            Color.primary.opacity(0.10)
        }
    }

    private var borderWidth: CGFloat {
        isFocused ? 2.5 : 1
    }

    private var primaryColor: Color {
        isFocused ? .primary : (isPast ? .primary.opacity(0.45) : .primary)
    }

    private var secondaryColor: Color {
        if isFocused {
            .primary.opacity(0.82)
        } else if isPast {
            .secondary.opacity(0.55)
        } else {
            .secondary
        }
    }

    private var stickyOffsetPublisher: AnyPublisher<CGFloat, Never> {
        scrollState.visibleLeadingOffsetPublisher
            .map { max(0, $0 - leadingOffset) }
            .removeDuplicates { abs($0 - $1) <= 0.5 }
            .eraseToAnyPublisher()
    }

    @ContentBuilder
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let showsSubtitle = isLarge
            ? (cellWidth >= 170 && presentation.subtitle != nil)
            : cellWidth >= 90

        Button(action: action) {
            StickyProgramContentLayout(
                stickyOffset: stickyOffset,
                horizontalPadding: isLarge ? 20 : 10
            ) {
                VStack(alignment: .leading, spacing: isLarge ? 6 : 2) {
                    HStack(spacing: isLarge ? 8 : 6) {
                        if presentation.isLive, cellWidth >= 150 {
                            Text(L10n.live.uppercased())
                                .font(isLarge ? .system(size: 15, weight: .bold) : .caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, isLarge ? 8 : 6)
                                .padding(.vertical, isLarge ? 3 : 2)
                                .background(Color(uiColor: .systemRed), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }

                        Text(presentation.title)
                            .font(isLarge ? .system(size: 28, weight: .semibold) : .footnote.weight(isCurrent ? .semibold : .medium))
                            .foregroundStyle(primaryColor)

                        if presentation.hasTimer, cellWidth >= 130 {
                            Circle()
                                .fill(Color(uiColor: .systemRed))
                                .frame(width: isLarge ? 10 : 6, height: isLarge ? 10 : 6)
                        }
                    }

                    if showsSubtitle {
                        Text(isLarge ? (presentation.subtitle ?? "") : presentation.time)
                            .font(isLarge ? .system(size: 22, weight: .medium) : .caption2)
                            .foregroundStyle(secondaryColor)
                    }
                }
                .lineLimit(1)
            }
            .background(backgroundColor, in: shape)
            .overlay {
                shape
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            }
            .padding(.trailing, isLarge ? 8 : 4)
            .padding(.vertical, isLarge ? 5 : 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(EPGButtonStyle())
        .accessibilityValue(isCurrent ? L10n.onNow : "")
        .onReceive(stickyOffsetPublisher) { stickyOffset in
            self.stickyOffset = stickyOffset
        }
    }
}

private struct ProgramCellPresentation {

    let title: String
    let time: String
    let subtitle: String?
    let isLive: Bool
    let hasTimer: Bool

    @MainActor
    init(block: ProgramBlock) {
        self.title = block.title
        self.time = block.timeRangeLabel ?? ""
        self.isLive = !block.isGroup && block.programs.first?.isLive == true
        self.hasTimer = block.hasTimer

        if block.isGroup {
            self.subtitle = block.start.formatted(date: .omitted, time: .shortened)
        } else if let episodeHeadline = block.episodeHeadline {
            self.subtitle = episodeHeadline
        } else {
            let parts = [
                block.categoryLabel,
                block.programs.first?.officialRating?.nilIfBlank,
            ].compactMap(\.self)
            self.subtitle = parts.isEmpty ? nil : parts.joined(separator: " \(String.bullet) ")
        }
    }
}

private struct StickyProgramContentLayout: Layout {

    let stickyOffset: CGFloat
    var horizontalPadding: CGFloat = 12

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else { return }

        let contentSize = content.sizeThatFits(.unspecified)
        let maximumShift = max(0, bounds.width - contentSize.width - horizontalPadding * 2)
        let shift = clamp(
            stickyOffset,
            min: 0,
            max: maximumShift
        )
        let verticalOffset = max(0, (bounds.height - contentSize.height) / 2)

        content.place(
            at: CGPoint(
                x: bounds.minX + horizontalPadding + shift,
                y: bounds.minY + verticalOffset
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: min(
                    contentSize.width,
                    max(0, bounds.width - horizontalPadding * 2 - shift)
                ),
                height: contentSize.height
            )
        )
    }
}
