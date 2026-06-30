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

extension ProgramsView {

    struct TVGuideGrid: View {

        @Router
        private var router

        @Injected(\.currentUserSession)
        private var userSession

        @State
        private var now: Date = .now

        let channelPrograms: [ChannelProgram]

        private let channelColumnWidth: CGFloat = 260
        private let columnGridSpacing: CGFloat = 28
        private let guideCellSpacing: CGFloat = 7
        private let hourWidth: CGFloat = 420
        private let rowHeight: CGFloat = 92
        private let headerHeight: CGFloat = 58
        private let visibleHours = 7
        private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

        private struct ProgramTimelineSegment: Identifiable {
            let id: String
            let program: BaseItemDto?
            let width: CGFloat
        }

        private var guideStart: Date {
            let hourStart = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
            return Calendar.current.date(byAdding: .hour, value: -1, to: hourStart) ?? hourStart
        }

        private var guideEnd: Date {
            Calendar.current.date(byAdding: .hour, value: visibleHours, to: guideStart) ?? guideStart
        }

        private var timeline: [Date] {
            (0 ... visibleHours).compactMap { offset in
                Calendar.current.date(byAdding: .hour, value: offset, to: guideStart)
            }
        }

        private var guideWidth: CGFloat {
            CGFloat(visibleHours) * hourWidth
        }

        private var currentTimeOffset: CGFloat? {
            guard guideStart <= now, now <= guideEnd else { return nil }
            return width(from: guideStart, to: now)
        }

        var body: some View {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        guideRows
                            .padding(.horizontal, 50)
                    } header: {
                        HStack(alignment: .top, spacing: columnGridSpacing) {
                            channelHeader
                            timeRuler
                        }
                        .padding(.horizontal, 50)
                        .background(Color.black.opacity(0.35))
                        .zIndex(20)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onReceive(timer) { newValue in
                now = newValue
            }
        }

        private var channelHeader: some View {
            Text("Channels")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: channelColumnWidth, height: headerHeight, alignment: .leading)
        }

        private var timeRuler: some View {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)

                ForEach(Array(timeline.enumerated()), id: \.offset) { offset, date in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(date, style: .time)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)

                        Rectangle()
                            .fill(.white.opacity(0.35))
                            .frame(width: 1, height: 14)
                    }
                    .offset(x: CGFloat(offset) * hourWidth)
                }

                ForEach(0 ..< visibleHours, id: \.self) { offset in
                    Rectangle()
                        .fill(.white.opacity(0.22))
                        .frame(width: 1, height: 9)
                        .offset(x: CGFloat(offset) * hourWidth + hourWidth / 2, y: 34)
                }

                if let currentTimeOffset {
                    Text(now, style: .time)
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.red, in: Capsule())
                        .offset(x: currentTimeOffset - 28, y: 4)
                }
            }
            .frame(width: guideWidth, height: headerHeight, alignment: .topLeading)
        }

        @ViewBuilder
        private var guideRows: some View {
            ZStack(alignment: .topLeading) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(channelPrograms) { channelProgram in
                        HStack(alignment: .top, spacing: columnGridSpacing) {
                            channelLabel(channelProgram.channel)
                                .frame(width: channelColumnWidth, height: rowHeight - 14, alignment: .leading)
                                .padding(.vertical, 7)

                            programTimeline(for: channelProgram)
                                .frame(width: guideWidth, height: rowHeight, alignment: .leading)
                        }
                        .frame(height: rowHeight, alignment: .leading)
                        .frame(width: channelColumnWidth + columnGridSpacing + guideWidth, alignment: .leading)
                        .background(alignment: .bottom) {
                            Rectangle()
                                .fill(.white.opacity(0.08))
                                .frame(height: 1)
                        }
                    }
                }

                currentTimeLine
            }
            .frame(width: channelColumnWidth + columnGridSpacing + guideWidth, alignment: .topLeading)
        }

        @ViewBuilder
        private var currentTimeLine: some View {
            if let currentTimeOffset {
                Rectangle()
                    .fill(.red)
                    .frame(width: 3, height: CGFloat(channelPrograms.count) * rowHeight)
                    .offset(x: channelColumnWidth + columnGridSpacing + currentTimeOffset - 1.5)
                    .zIndex(10)
                    .allowsHitTesting(false)
            }
        }

        private func programTimeline(for channelProgram: ChannelProgram) -> some View {
            HStack(spacing: guideCellSpacing) {
                let segments = timelineSegments(for: channelProgram)

                if segments.isEmpty {
                    emptyProgramCell(channel: channelProgram.channel)
                        .frame(width: CGFloat(visibleHours) * hourWidth - guideCellSpacing, height: rowHeight - 14)
                } else {
                    ForEach(segments) { segment in
                        if let program = segment.program {
                            programCell(program, channel: channelProgram.channel)
                                .frame(width: segment.width, height: rowHeight - 14)
                        } else {
                            Color.clear
                                .frame(width: segment.width, height: rowHeight - 14)
                        }
                    }
                }
            }
        }

        private func emptyProgramCell(channel: BaseItemDto) -> some View {
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(0.05))
                .overlay(alignment: .leading) {
                    Text("No guide data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                }
        }

        private func channelLabel(_ channel: BaseItemDto) -> some View {
            Button {
                play(channel)
            } label: {
                HStack(spacing: 16) {
                    ImageView(channel.imageSource(.primary, maxWidth: 120))
                        .image { image in
                            image
                                .aspectRatio(contentMode: .fit)
                        }
                        .failure {
                            Image(systemName: "tv")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 64, height: 38)

                    VStack(alignment: .leading, spacing: 4) {
                        if let channelNumber = channel.channelNumber, channelNumber.isNotEmpty {
                            Text(channelNumber)
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }

                        Text(channel.displayTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.trailing, 22)
            }
            .buttonStyle(GuideChannelButtonStyle())
            .focusEffectDisabled()
        }

        private func programCell(_ program: BaseItemDto, channel: BaseItemDto) -> some View {
            Button {
                play(channel)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(program.displayTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    HStack(spacing: 3) {
                        if let startDate = program.startDate {
                            Text(startDate, style: .time)
                        }

                        Text(String.hyphen)

                        if let endDate = program.endDate {
                            Text(endDate, style: .time)
                        }
                    }
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                    if let overview = program.overview, overview.isNotEmpty {
                        Text(overview)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
            }
            .buttonStyle(GuideCellButtonStyle(isCurrent: programIsCurrent(program)))
            .focusEffectDisabled()
        }

        private func visiblePrograms(for channelProgram: ChannelProgram) -> [BaseItemDto] {
            channelProgram.programs.filter { program in
                guard let startDate = program.startDate,
                      let endDate = program.endDate
                else { return false }

                return endDate > guideStart && startDate < guideEnd
            }
        }

        private func timelineSegments(for channelProgram: ChannelProgram) -> [ProgramTimelineSegment] {
            var cursor = guideStart
            var segments: [ProgramTimelineSegment] = []

            for (index, program) in visiblePrograms(for: channelProgram).enumerated() {
                let programStart = max(program.startDate ?? cursor, guideStart)
                let programEnd = min(program.endDate ?? guideEnd, guideEnd)
                let gapWidth = width(from: cursor, to: programStart)

                if gapWidth > 0 {
                    segments.append(
                        ProgramTimelineSegment(
                            id: "\(channelProgram.id ?? "channel")-gap-\(index)",
                            program: nil,
                            width: gapWidth
                        )
                    )
                }

                segments.append(
                    ProgramTimelineSegment(
                        id: program.id ?? "\(channelProgram.id ?? "channel")-program-\(index)",
                        program: program,
                        width: max(width(from: programStart, to: programEnd) - guideCellSpacing, 96)
                    )
                )

                cursor = max(cursor, programEnd)
            }

            return segments
        }

        private func programIsCurrent(_ program: BaseItemDto) -> Bool {
            guard let startDate = program.startDate,
                  let endDate = program.endDate
            else { return false }

            return startDate <= now && now <= endDate
        }

        private func width(from startDate: Date, to endDate: Date) -> CGFloat {
            guard endDate > startDate else { return 0 }
            return CGFloat(endDate.timeIntervalSince(startDate) / 3600) * hourWidth
        }

        private func play(_ channel: BaseItemDto) {
            guard let userSession else { return }

            router.route(
                to: .videoPlayer(
                    provider: channel.getPlaybackItemProvider(userSession: userSession)
                )
            )
        }
    }
}

private struct GuideCellButtonStyle: ButtonStyle {

    @Environment(\.isFocused)
    private var isFocused

    var isCurrent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.white.opacity(isFocused ? 0.18 : (isCurrent ? 0.12 : 0.07)), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(isFocused ? 0.22 : 0.07), lineWidth: 1)
            }
    }
}

private struct GuideChannelButtonStyle: ButtonStyle {

    @Environment(\.isFocused)
    private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(.white.opacity(isFocused ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(isFocused ? 0.22 : 0), lineWidth: 1)
            }
    }
}
