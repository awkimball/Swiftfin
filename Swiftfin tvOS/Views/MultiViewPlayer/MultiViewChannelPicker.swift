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

/// A simple full-screen channel picker for filling a multi-view tile.
struct MultiViewChannelPicker: View {

    @Environment(\.dismiss)
    private var dismiss

    @Injected(\.currentUserSession)
    private var userSession

    let onSelect: (BaseItemDto) -> Void

    @State
    private var channels: [BaseItemDto] = []
    @State
    private var isLoading = true
    @State
    private var error: Error?

    private let columns = [GridItem](repeating: GridItem(.flexible(), spacing: 30), count: 4)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if let error {
                ErrorView(error: error)
            } else if channels.isEmpty {
                ContentUnavailableView("No Channels", systemImage: "tv")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 30) {
                        ForEach(channels, id: \.id) { channel in
                            Button {
                                onSelect(channel)
                                dismiss()
                            } label: {
                                channelCard(channel)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(50)
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func channelCard(_ channel: BaseItemDto) -> some View {
        VStack(spacing: 12) {
            ImageView(channel.imageSource(.primary, maxWidth: 300))
                .failure {
                    Image(systemName: "tv")
                        .font(.system(size: 50))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 140)

            Text(channel.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
    }

    private func load() async {
        guard let userSession else {
            isLoading = false
            return
        }

        do {
            var parameters = Paths.GetLiveTvChannelsParameters()
            parameters.fields = .MinimumFields
            parameters.enableImages = true
            parameters.sortBy = [.name]
            parameters.userID = userSession.user.id
            parameters.limit = 500

            let request = Paths.getLiveTvChannels(parameters: parameters)
            let response = try await userSession.client.send(request)

            channels = response.value.items ?? []
        } catch {
            self.error = error
        }

        isLoading = false
    }
}
