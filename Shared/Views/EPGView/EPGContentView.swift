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

struct EPGLoadableView<Content: View>: View {

    private let content: Content
    private let viewModel: EPGViewModel

    init(
        viewModel: EPGViewModel,
        @ContentBuilder content: () -> Content
    ) {
        self.content = content()
        self.viewModel = viewModel
    }

    @ContentBuilder
    var body: some View {
        switch viewModel.state {
        case .initial, .refreshing:
            ProgressView()

        case .error:
            if let error = viewModel.error {
                ErrorView(error: error)
            }

        case .content:
            if viewModel.channels.isEmpty {
                ContentUnavailableView(L10n.noPrograms, systemImage: "tv")
            } else {
                content
            }
        }
    }
}

struct EPGContentView: View {

    @Namespace
    private var focusScope

    @State
    private var selectedGroup: ProgramBlock?

    @StateObject
    private var proxy = EPGScrollProxy()

    private let action: (BaseItemDto) -> Void
    private let onFocus: ((BaseItemDto?, ProgramBlock?) -> Void)?
    private let selectedChannelID: String?
    private let viewModel: EPGViewModel

    init(
        selectedChannelID: String? = nil,
        viewModel: EPGViewModel,
        onFocus: ((BaseItemDto?, ProgramBlock?) -> Void)? = nil,
        action: @escaping (BaseItemDto) -> Void
    ) {
        self.action = action
        self.onFocus = onFocus
        self.selectedChannelID = selectedChannelID
        self.viewModel = viewModel
    }

    private var isPresentingGroup: Binding<Bool> {
        Binding(
            get: { selectedGroup != nil },
            set: { isPresented in
                if !isPresented {
                    selectedGroup = nil
                }
            }
        )
    }

    // TODO: turn into FormatStyle
    private func programTitle(for program: BaseItemDto) -> String {
        guard let start = program.startDate else { return program.displayTitle }

        return "\(start.formatted(date: .omitted, time: .shortened)) \(String.bullet) \(program.displayTitle)"
    }

    @ContentBuilder
    var body: some View {
        AlternateLayoutView {
            Color.clear
        } content: { frame in
            HStack(spacing: 0) {
                EPGChannelColumn(
                    bottomInset: frame.safeAreaInsets.bottom,
                    proxy: proxy,
                    selectedChannelID: selectedChannelID,
                    viewModel: viewModel,
                    onFocusChannel: { channel in
                        let blocks = channel.id.flatMap { viewModel.programs[$0] } ?? []
                        let current = blocks.first { $0.isAiring(at: viewModel.now) } ?? blocks.first
                        onFocus?(channel, current)
                    }
                ) { item in
                    action(item)
                }

                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        EPGTimeRuler(viewModel: viewModel)
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    .scrollDisabled(true)
                    .introspect(.scrollView, on: .iOS(.v15...), .tvOS(.v15...)) { scrollView in
                        proxy.registerHorizontal(scrollView)
                    }

                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 1)

                    EPGCollectionView(
                        bottomInset: frame.safeAreaInsets.bottom,
                        onFocus: { block in
                            let channel = block.id.channelID.flatMap { id in
                                viewModel.channels.first { $0.itemID == id }?.snapshot
                            }
                            onFocus?(channel, block)
                        },
                        onReachedBottom: {
                            viewModel.getNextPage()
                        },
                        onSelect: {
                            action($0)
                        },
                        onSelectGroup: {
                            selectedGroup = $0
                        },
                        proxy: proxy,
                        viewModel: viewModel
                    )
                    #if os(tvOS)
                    .prefersDefaultFocus(in: focusScope)
                    #endif
                }
            }
            #if os(tvOS)
            .focusScope(focusScope)
            #endif
            .ignoresSafeArea(edges: .bottom)
        }
        .trackingFrame(for: .layoutContainer)
        .confirmationDialog(
            L10n.programs,
            isPresented: isPresentingGroup,
            titleVisibility: .hidden,
            presenting: selectedGroup
        ) { block in
            ForEach(block.programs) { program in
                Button(programTitle(for: program)) {
                    action(program)
                }
            }
        }
        .onDisappear {
            proxy.disconnect()
        }
        .onAppear {
            proxy.connect()
        }
    }
}
