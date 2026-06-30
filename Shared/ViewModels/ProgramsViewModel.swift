//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import JellyfinAPI

final class ProgramsViewModel: ViewModel, Stateful {

    enum ProgramSection: CaseIterable {
        case kids
        case movies
        case news
        case recommended
        case series
        case sports
    }

    // MARK: Action

    enum Action: Equatable {
        case error(ErrorMessage)
        case refresh
    }

    // MARK: State

    enum State: Hashable {
        case content
        case error(ErrorMessage)
        case initial
        case refreshing
    }

    @Published
    private(set) var kids: [BaseItemDto] = []
    @Published
    private(set) var movies: [BaseItemDto] = []
    @Published
    private(set) var news: [BaseItemDto] = []
    @Published
    private(set) var recommended: [BaseItemDto] = []
    @Published
    private(set) var series: [BaseItemDto] = []
    @Published
    private(set) var sports: [BaseItemDto] = []
    @Published
    private(set) var channelPrograms: [ChannelProgram] = []

    @Published
    var state: State = .initial

    private var currentRefreshTask: AnyCancellable?

    var hasNoResults: Bool {
        [
            kids,
            movies,
            news,
            recommended,
            series,
            sports,
        ].allSatisfy(\.isEmpty) && channelPrograms.isEmpty
    }

    func respond(to action: Action) -> State {
        switch action {
        case let .error(error):
            return .error(error)
        case .refresh:
            currentRefreshTask?.cancel()

            currentRefreshTask = Task { [weak self] in
                guard let self else { return }

                do {
                    async let sections = getItemSections()
                    async let channelPrograms = getChannelPrograms()

                    let refreshedSections = try await sections
                    let refreshedChannelPrograms = try await channelPrograms

                    guard !Task.isCancelled else { return }

                    await MainActor.run {
                        self.kids = refreshedSections[.kids] ?? []
                        self.movies = refreshedSections[.movies] ?? []
                        self.news = refreshedSections[.news] ?? []
                        self.recommended = refreshedSections[.recommended] ?? []
                        self.series = refreshedSections[.series] ?? []
                        self.sports = refreshedSections[.sports] ?? []
                        self.channelPrograms = refreshedChannelPrograms

                        self.state = .content
                    }
                } catch {
                    guard !Task.isCancelled else { return }

                    await MainActor.run {
                        self.send(.error(.init(error.localizedDescription)))
                    }
                }
            }
            .asAnyCancellable()

            return .refreshing
        }
    }

    private func getItemSections() async throws -> [ProgramSection: [BaseItemDto]] {
        try await withThrowingTaskGroup(
            of: (ProgramSection, [BaseItemDto]).self,
            returning: [ProgramSection: [BaseItemDto]].self
        ) { group in

            // sections
            for section in ProgramSection.allCases {
                group.addTask {
                    let items = try await self.getPrograms(for: section)
                    return (section, items)
                }
            }

            // recommended
            group.addTask {
                let items = try await self.getRecommendedPrograms()
                return (ProgramSection.recommended, items)
            }

            var programs: [ProgramSection: [BaseItemDto]] = [:]

            while let items = try await group.next() {
                programs[items.0] = items.1
            }

            return programs
        }
    }

    private func getRecommendedPrograms() async throws -> [BaseItemDto] {

        var parameters = Paths.GetRecommendedProgramsParameters()
        parameters.fields = .MinimumFields
            .appending(.channelInfo)
        parameters.isAiring = true
        parameters.limit = 20

        let request = Paths.getRecommendedPrograms(parameters: parameters)
        let response = try await send(request)

        return response.value.items ?? []
    }

    private func getPrograms(for section: ProgramSection) async throws -> [BaseItemDto] {

        var parameters = Paths.GetLiveTvProgramsParameters()
        parameters.fields = .MinimumFields
            .appending(.channelInfo)
        parameters.hasAired = false
        parameters.limit = 20

        parameters.isKids = section == .kids
        parameters.isMovie = section == .movies
        parameters.isNews = section == .news
        parameters.isSeries = section == .series
        parameters.isSports = section == .sports

        let request = Paths.getLiveTvPrograms(parameters: parameters)
        let response = try await send(request)

        return response.value.items ?? []
    }

    private func getChannelPrograms() async throws -> [ChannelProgram] {
        guard let minEndDate = Calendar.current.date(byAdding: .hour, value: -1, to: .now),
              let maxStartDate = Calendar.current.date(byAdding: .hour, value: 6, to: .now)
        else { return [] }

        var channelParameters = Paths.GetLiveTvChannelsParameters()
        channelParameters.fields = .MinimumFields
        channelParameters.enableImages = true
        channelParameters.limit = 1000
        channelParameters.sortBy = [.name]
        channelParameters.userID = try authenticatedUser.id

        let channelRequest = Paths.getLiveTvChannels(parameters: channelParameters)
        let channelResponse = try await send(channelRequest)
        let channels = (channelResponse.value.items ?? [])
            .sorted(by: BaseItemDto.liveTVChannelSort)
        guard channels.isNotEmpty else { return [] }

        var programParameters = Paths.GetLiveTvProgramsParameters()
        programParameters.channelIDs = channels.compactMap(\.id)
        programParameters.maxStartDate = maxStartDate
        programParameters.minEndDate = minEndDate
        programParameters.sortBy = [.startDate]
        programParameters.userID = try authenticatedUser.id

        let programRequest = Paths.getLiveTvPrograms(parameters: programParameters)
        let programResponse = try await send(programRequest)

        let groupedPrograms = (programResponse.value.items ?? [])
            .grouped { program in
                channels.first(where: { $0.id == program.channelID })
            }

        return channels
            .reduce(into: [:]) { partialResult, channel in
                partialResult[channel] = (groupedPrograms[channel] ?? [])
                    .sorted(using: \.startDate)
            }
            .map(ChannelProgram.init)
            .sorted(by: ChannelProgram.liveTVChannelSort)
    }
}
