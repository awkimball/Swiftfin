//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

struct EPGTimeRuler: View {

    @AdaptiveLayout
    private var viewLayout

    let viewModel: EPGViewModel

    /// Count of timestamps needed for the period (30m increments)
    private var labelCount: Int {
        max(0, Int(viewModel.startDate.distance(to: viewModel.endDate) / (Double(30) * 60)))
    }

    private func nowOffset(layout: EPGLayout) -> CGFloat? {
        guard viewModel.now >= viewModel.startDate, viewModel.now <= viewModel.endDate else {
            return nil
        }

        return layout.width(from: viewModel.startDate, to: viewModel.now)
    }

    @ContentBuilder
    var body: some View {
        let layout = EPGLayout(viewLayout: viewLayout)
        let totalWidth = max(1, layout.width(from: viewModel.startDate, to: viewModel.endDate))
        let currentOffset = nowOffset(layout: layout)
        let collisionHalfWidth: CGFloat = viewLayout.isLarge ? 128 : 64

        ZStack(alignment: .bottomLeading) {
            LazyHStack(spacing: 0) {
                ForEach(0 ..< labelCount, id: \.self) { index in
                    let date = viewModel.startDate.addingTimeInterval(Double(index * 30 * 60))
                    let isOnTheHour = Calendar.current.component(.minute, from: date) == 0
                    let slotLeading = CGFloat(index) * 30 * layout.pointsPerMinute
                    let collidesWithNow = currentOffset.map {
                        abs((slotLeading + 54) - $0) < collisionHalfWidth
                    } ?? false

                    VStack(alignment: .leading, spacing: viewLayout.isLarge ? 6 : 4) {
                        timestamp(for: date, isOnTheHour: isOnTheHour)
                            .opacity(collidesWithNow ? 0 : 1)

                        Spacer(minLength: 0)

                        Rectangle()
                            .fill(Color.primary.opacity(isOnTheHour ? 0.30 : 0.14))
                            .frame(width: 1, height: isOnTheHour ? (viewLayout.isLarge ? 14 : 10) : (viewLayout.isLarge ? 8 : 5))
                    }
                    .frame(
                        width: 30 * layout.pointsPerMinute,
                        height: layout.rulerHeight,
                        alignment: .topLeading
                    )
                }
            }
            .frame(width: totalWidth, height: layout.rulerHeight, alignment: .leading)

            if let currentOffset {
                VStack(spacing: 0) {
                    Text(viewModel.now, style: .time)
                        .font(.system(size: viewLayout.isLarge ? 20 : 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, viewLayout.isLarge ? 13 : 7)
                        .padding(.vertical, viewLayout.isLarge ? 5 : 2)
                        .background {
                            Capsule()
                                .fill(Color(uiColor: .systemRed))
                                .overlay {
                                    Capsule()
                                        .strokeBorder(Color.black.opacity(0.30), lineWidth: 1)
                                }
                        }

                    Rectangle()
                        .fill(Color(uiColor: .systemRed))
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                }
                .frame(height: layout.rulerHeight - (viewLayout.isLarge ? 4 : 2))
                .fixedSize(horizontal: true, vertical: false)
                .position(x: currentOffset, y: (layout.rulerHeight + (viewLayout.isLarge ? 4 : 2)) / 2)
                .allowsHitTesting(false)
            }
        }
        .frame(width: totalWidth, height: layout.rulerHeight)
    }

    @ContentBuilder
    private func timestamp(for date: Date, isOnTheHour: Bool) -> some View {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let isDayStart = components.hour == 0 && components.minute == 0

        Text(
            isDayStart
                ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                : date.formatted(date: .omitted, time: .shortened)
        )
        .font(viewLayout.isLarge ? .system(size: 24, weight: isOnTheHour ? .semibold : .medium) : .caption2.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(isDayStart ? Color.primary : Color.primary.opacity(isOnTheHour ? 0.80 : 0.50))
        .lineLimit(1)
        .padding(.leading, 6)
        .padding(.top, viewLayout.isLarge ? 8 : 4)
    }
}
