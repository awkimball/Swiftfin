//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Factory
import JellyfinAPI
import SwiftUI

// TODO: background refresh for programs with timer?

// Note: there are some unsafe first element accesses, but `ChannelProgram` data should always have a single program

struct ProgramsView: View {

    private enum LiveTVSection: Hashable {
        case channels
        case guide
        case onNow
    }

    @Router
    private var router

    @Injected(\.currentUserSession)
    private var userSession

    @StateObject
    private var programsViewModel = ProgramsViewModel()

    @State
    private var selectedSection: LiveTVSection = .guide

    private let channelGridColumns = [GridItem](repeating: GridItem(.flexible(), spacing: 24), count: 5)

    @ViewBuilder
    private var liveTVNavigation: some View {
        HStack(spacing: 20) {
            liveTVNavigationButton(
                title: "Guide",
                systemImage: "list.bullet.rectangle",
                isSelected: selectedSection == .guide
            ) {
                selectedSection = .guide
            }

            liveTVNavigationButton(
                title: "Programs",
                systemImage: "play.rectangle.on.rectangle",
                isSelected: selectedSection == .onNow
            ) {
                selectedSection = .onNow
            }

            liveTVNavigationButton(
                title: L10n.channels,
                systemImage: "play.square.stack",
                isSelected: selectedSection == .channels
            ) {
                selectedSection = .channels
            }

            liveTVNavigationButton(
                title: "Multi-View",
                systemImage: "rectangle.split.2x1"
            ) {
                router.route(to: .multiView())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 50)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private func liveTVNavigationButton(
        title: String,
        systemImage: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))

                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LiveTVNavigationButtonStyle())
        .isSelected(isSelected)
    }

    @ViewBuilder
    private var contentView: some View {
        VStack(spacing: 0) {
            liveTVNavigation

            switch selectedSection {
            case .channels:
                channelsContentView
            case .guide:
                guideContentView
            case .onNow:
                onNowContentView
            }
        }
    }

    @ViewBuilder
    private var channelsContentView: some View {
        if programsViewModel.channelPrograms.isNotEmpty {
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: channelGridColumns, spacing: 24) {
                    ForEach(programsViewModel.channelPrograms) { channelProgram in
                        channelGridButton(channelProgram.channel)
                    }
                }
                .padding(.horizontal, 50)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        } else {
            ContentUnavailableView(L10n.noPrograms.localizedCapitalized, systemImage: "tv")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func channelGridButton(_ channel: BaseItemDto) -> some View {
        Button {
            guard let userSession else { return }

            router.route(
                to: .videoPlayer(
                    provider: channel.getPlaybackItemProvider(userSession: userSession)
                )
            )
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ImageView(channel.imageSource(.primary, maxWidth: 120))
                    .image { image in
                        image
                            .aspectRatio(contentMode: .fit)
                    }
                    .failure {
                        Image(systemName: "tv")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 88)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 3) {
                    if let channelNumber = channel.channelNumber, channelNumber.isNotEmpty {
                        Text(channelNumber)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Text(channel.displayTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
            .frame(height: 178, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LightweightChannelGridButtonStyle())
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var guideContentView: some View {
        if programsViewModel.channelPrograms.isNotEmpty {
            TVGuideGrid(channelPrograms: programsViewModel.channelPrograms)
                .clipped()
        } else {
            ContentUnavailableView(L10n.noPrograms.localizedCapitalized, systemImage: "tv")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var onNowContentView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                if programsViewModel.hasNoResults {
                    ContentUnavailableView(L10n.noPrograms.localizedCapitalized, systemImage: "tv")
                }

                if programsViewModel.recommended.isNotEmpty {
                    programsSection(title: L10n.onNow, keyPath: \.recommended)
                }

                if programsViewModel.series.isNotEmpty {
                    programsSection(title: L10n.series, keyPath: \.series)
                }

                if programsViewModel.movies.isNotEmpty {
                    programsSection(title: L10n.movies, keyPath: \.movies)
                }

                if programsViewModel.kids.isNotEmpty {
                    programsSection(title: L10n.kids, keyPath: \.kids)
                }

                if programsViewModel.sports.isNotEmpty {
                    programsSection(title: L10n.sports, keyPath: \.sports)
                }

                if programsViewModel.news.isNotEmpty {
                    programsSection(title: L10n.news, keyPath: \.news)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func programsSection(
        title: String,
        keyPath: KeyPath<ProgramsViewModel, [BaseItemDto]>
    ) -> some View {
        PosterHStack(
            title: title,
            type: .landscape,
            items: programsViewModel[keyPath: keyPath]
        ) { _ in
//            guard let mediaSource = channelProgram.channel.mediaSources?.first else { return }
//            router.route(
//                to: \.liveVideoPlayer,
//                LiveVideoPlayerManager(item: channelProgram.channel, mediaSource: mediaSource)
//            )
        } label: {
            ProgramButtonContent(program: $0)
        }
        .posterOverlay(for: BaseItemDto.self) {
            ProgramProgressOverlay(program: $0)
        }
    }

    var body: some View {
        ZStack {
            switch programsViewModel.state {
            case .content:
                contentView
            case let .error(error):
                ErrorView(error: error)
            case .initial, .refreshing:
                ProgressView()
            }
        }
        .animation(.linear(duration: 0.1), value: programsViewModel.state)
        .ignoresSafeArea(edges: [.bottom, .horizontal])
        .refreshable {
            programsViewModel.send(.refresh)
        }
        .onFirstAppear {
            if programsViewModel.state == .initial {
                programsViewModel.send(.refresh)
            }
        }
    }
}

private struct LiveTVNavigationButtonStyle: ButtonStyle {

    @Environment(\.isFocused)
    private var isFocused
    @Environment(\.isSelected)
    private var isSelected

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(tvOS 26.0, *) {
            glassBody(configuration)
        } else {
            legacyBody(configuration)
        }
    }

    private func baseLabel(_ configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .frame(width: 268, height: 58)
            .contentShape(Capsule())
    }

    @available(tvOS 26.0, *)
    private func glassBody(_ configuration: Configuration) -> some View {
        baseLabel(configuration)
            .glassEffect(
                .regular
                    .tint(isSelected ? Color.accentColor.opacity(0.35) : nil)
                    .interactive(isFocused),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(.white.opacity(isFocused || isSelected ? 0.24 : 0.08), lineWidth: 1)
            }
            .brightness(isFocused ? 0.08 : 0)
            .animation(.easeInOut(duration: 0.12), value: isFocused)
            .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private func legacyBody(_ configuration: Configuration) -> some View {
        baseLabel(configuration)
            .background {
                Capsule()
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(isFocused ? 0.9 : 0.65)
                            : Color.white.opacity(isFocused ? 0.22 : 0.12)
                    )
            }
            .overlay {
                Capsule()
                    .stroke(.white.opacity(isFocused || isSelected ? 0.24 : 0.08), lineWidth: 1)
            }
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.12), value: isFocused)
            .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}

private struct LightweightChannelGridButtonStyle: ButtonStyle {

    @Environment(\.isFocused)
    private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(.white.opacity(isFocused ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
