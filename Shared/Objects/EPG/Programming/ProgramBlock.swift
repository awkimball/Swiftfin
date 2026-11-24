//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

@MainActor
struct ProgramBlock: Identifiable {

    struct ID: Hashable {

        let channelID: String?
        let programIDs: [String?]
        let start: Date
        let end: Date
    }

    let id: ID
    @SharedBaseItems
    var programs: [BaseItemDto]
    let start: Date
    let end: Date

    var isGroup: Bool {
        programs.count > 1
    }

    init(
        programs: [BaseItemDto],
        start: Date,
        end: Date
    ) {
        self.id = ID(
            channelID: programs.first?.channelID,
            programIDs: programs.map(\.id),
            start: start,
            end: end
        )

        self.programs = programs
        self.start = start
        self.end = end
    }

    func isAiring(at date: Date) -> Bool {
        programs.contains { program in
            guard let start = program.startDate, let end = program.endDate else { return false }

            return start <= date && date < end
        }
    }

    var hasTimer: Bool {
        programs.contains { $0.timerID != nil || $0.seriesTimerID != nil }
    }

    var title: String {
        if isGroup {
            // swiftlint:disable:next hard_coded_display_string
            return "\(programs.count) \(L10n.programs)"
        }

        return programs.first?.displayTitle ?? L10n.programs
    }

    var timeRangeLabel: String? {
        if isGroup {
            return [
                start.formatted(date: .omitted, time: .shortened),
                end.formatted(date: .omitted, time: .shortened),
            ]
                .joined(separator: " – ")
        }

        guard let program = programs.first else { return nil }

        let times = [
            program.startDate?.formatted(date: .omitted, time: .shortened),
            program.endDate?.formatted(date: .omitted, time: .shortened),
        ]
            .compactMap(\.self)

        return times.isEmpty ? nil : times.joined(separator: " – ")
    }

    var episodeHeadline: String? {
        guard !isGroup, let program = programs.first else { return nil }

        let distinctEpisode = program.episodeTitle?.nilIfBlank.flatMap {
            $0.caseInsensitiveCompare(program.displayTitle) == .orderedSame ? nil : $0
        }

        let parts = [program.seasonEpisodeLabel, distinctEpisode].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " \(String.bullet) ")
    }

    var categoryLabel: String? {
        guard !isGroup, let program = programs.first else { return nil }

        var parts: [String] = []

        if program.isMovie == true {
            parts.append(L10n.movie)
            if let year = program.productionYear {
                parts.append(String(year))
            }
        } else if let genres = program.genres?.prefix(2), genres.isNotEmpty {
            parts.append(contentsOf: genres)
        } else if program.isSports == true {
            parts.append(L10n.sports)
        } else if program.isNews == true {
            parts.append(L10n.news)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " \(String.bullet) ")
    }
}

@MainActor
extension Collection<BaseItemDto> {

    func programBlocks(
        startDate: Date,
        endDate: Date
    ) -> [ProgramBlock] {
        let clampedPrograms = compactMap { ClampedProgram($0, clampedTo: startDate ... endDate) }
            .sorted { $0.start < $1.start }

        var chunks: [[ClampedProgram]] = []
        var currentChunk: [ClampedProgram] = []
        var currentEnd: Date?

        for program in clampedPrograms {
            let joinsCurrentChunk = program.isShort &&
                currentChunk.first?.isShort == true &&
                currentEnd.map { program.start <= $0 } == true

            if currentChunk.isNotEmpty, !joinsCurrentChunk {
                chunks.append(currentChunk)
                currentChunk.removeAll(keepingCapacity: true)
                currentEnd = nil
            }

            currentChunk.append(program)

            if let previousEnd = currentEnd {
                currentEnd = previousEnd > program.end ? previousEnd : program.end
            } else {
                currentEnd = program.end
            }
        }

        if currentChunk.isNotEmpty {
            chunks.append(currentChunk)
        }

        return chunks.compactMap { chunk in
            guard let first = chunk.first,
                  let end = chunk.map(\.end).max()
            else { return nil }

            return ProgramBlock(
                programs: chunk.map(\.program),
                start: first.start,
                end: end
            )
        }
    }
}
