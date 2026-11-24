//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

struct EPGView: View {

    @AdaptiveLayout
    private var viewLayout

    @AppTheme
    private var theme

    @PlayMedia
    private var playMedia

    @Router
    private var router

    @State
    private var focusedChannel: BaseItemDto?
    @State
    private var focusedBlock: ProgramBlock?
    @State
    private var viewModel = EPGViewModel()

    private var activeSelection: (channel: BaseItemDto?, block: ProgramBlock?) {
        if focusedChannel != nil || focusedBlock != nil {
            return (focusedChannel, focusedBlock)
        }

        guard let firstChannel = viewModel.channels.first?.snapshot else {
            return (nil, nil)
        }

        let blocks = firstChannel.id.flatMap { viewModel.programs[$0] } ?? []
        let current = blocks.first { $0.isAiring(at: viewModel.now) } ?? blocks.first
        return (firstChannel, current)
    }

    @ContentBuilder
    private var contentView: some View {
        VStack(spacing: 0) {
            if viewLayout.isLarge {
                let selection = activeSelection

                HStack(alignment: .top, spacing: 28) {
                    EPGProgramSummaryHeader(
                        channel: selection.channel,
                        block: selection.block,
                        now: viewModel.now,
                        accentColor: theme.accentColor
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    EPGDateMenu(viewModel: viewModel)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 40)
                .padding(.top, 22)
                .padding(.bottom, 16)

                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 6)
            }

            EPGContentView(
                viewModel: viewModel,
                onFocus: { channel, block in
                    focusedChannel = channel
                    focusedBlock = block
                }
            ) { item in
                if [.channel, .liveTvChannel, .tvChannel].contains(item.type),
                   let intent = item.getPlaybackIntent(userSession: viewModel.userSession) {
                    playMedia(intent: intent)
                } else {
                    router.route(to: .item(item: item))
                }
            }
            .if(viewLayout.isLarge) { view in
                view.padding(.horizontal, 36)
            }
        }
    }

    @ContentBuilder
    var body: some View {
        EPGLoadableView(viewModel: viewModel) {
            contentView
        }
        #if os(tvOS)
        .background {
                LinearGradient(
                    colors: [
                        Color(white: 0.08),
                        Color(white: 0.04),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        #endif
            .onFirstAppear {
            viewModel.refresh(startDate: nil)
        }
        .onChange(of: viewModel.startDate) { _, _ in
            focusedChannel = nil
            focusedBlock = nil
        }
        .refreshable {
            await viewModel.refresh(startDate: nil)
        }
        .onSceneWillEnterForeground {
            Task {
                await viewModel.refresh(startDate: nil)
            }
        }
        #if os(iOS)
        .topBarTrailing {
            EPGDateMenu(viewModel: viewModel)
        }
        .navigationTitle(L10n.guide)
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .ignoresSafeArea(edges: viewLayout.scrollContentEdges(extendsTop: false))
    }
}

private struct EPGProgramSummaryHeader: View {

    let channel: BaseItemDto?
    let block: ProgramBlock?
    let now: Date
    let accentColor: Color

    private var program: BaseItemDto? {
        block?.programs.first
    }

    private var channelLabel: String? {
        guard let channel else { return nil }

        if let number = channel.channelNumber?.nilIfBlank {
            return "\(number)  \(channel.displayTitle)"
        }

        return channel.displayTitle
    }

    private var timeRangeLabel: String? {
        block?.timeRangeLabel
    }

    private var airingProgress: Double? {
        guard let block,
              block.isAiring(at: now),
              let program,
              let progress = program.programProgress(relativeTo: now)
        else { return nil }

        return clamp(progress, min: 0, max: 1)
    }

    private var titleText: String {
        block?.title ?? channel?.displayTitle ?? L10n.guide
    }

    private var overviewText: String? {
        if let block, block.isGroup {
            return block.programs
                .map(\.displayTitle)
                .joined(separator: " \(String.bullet) ")
        }

        let rawOverview = program?.overview?.nilIfBlank
        if let episodeHeadline = block?.episodeHeadline, let rawOverview {
            return "\(episodeHeadline) — \(rawOverview)"
        }

        return rawOverview ?? block?.episodeHeadline
    }

    private var categoryText: String? {
        block?.categoryLabel
    }

    @ContentBuilder
    private func badgePill(_ text: String, fill: Color = Color.white.opacity(0.10), foreground: Color = .white.opacity(0.85)) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ContentBuilder
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                if let channelLabel {
                    Text(channelLabel)
                        .font(.system(size: 23, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.92))
                }

                if let timeRangeLabel {
                    Text(String.bullet)
                        .foregroundStyle(.white.opacity(0.40))

                    Text(timeRangeLabel)
                        .font(.system(size: 23, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.70))
                }

                if let airingProgress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.16))

                            Capsule()
                                .fill(accentColor)
                                .frame(width: max(4, geo.size.width * airingProgress))
                        }
                    }
                    .frame(width: 150, height: 6)
                }

                if program?.isLive == true {
                    badgePill(L10n.live.uppercased(), fill: Color(uiColor: .systemRed), foreground: .white)
                }

                if block?.hasTimer == true {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(uiColor: .systemRed))
                            .frame(width: 9, height: 9)

                        Text(L10n.recording)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                if let rating = program?.officialRating?.nilIfBlank {
                    badgePill(rating)
                }

                if program?.isHD == true {
                    // swiftlint:disable:next hard_coded_display_string
                    badgePill("HD")
                }

                if let categoryText {
                    Text(categoryText)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.white.opacity(0.60))
                        .lineLimit(1)
                }
            }
            .lineLimit(1)

            Text(titleText)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(overviewText ?? " ")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(2)
                .frame(maxWidth: 1360, minHeight: 64, alignment: .topLeading)
        }
    }
}
