//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import UIKit

struct EPGLayout: Equatable {

    let channelColumnWidth: CGFloat
    let rowHeight: CGFloat
    let rulerHeight: CGFloat
    let pointsPerMinute: CGFloat

    init(
        viewLayout: ViewLayout,
        channelColumnWidth: CGFloat? = nil,
        rowHeight: CGFloat? = nil,
        rulerHeight: CGFloat? = nil,
        pointsPerMinute: CGFloat? = nil
    ) {
        let minimumRowHeight: CGFloat = viewLayout.value(standard: 76, large: 120)
        let minimumRulerHeight: CGFloat = viewLayout.value(standard: 34, large: 62)
        let traits = UITraitCollection(preferredContentSizeCategory: viewLayout.contentSizeCategory)
        let preferredProgramHeight = viewLayout.isLarge
            ? minimumRowHeight
            : (
                UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits).lineHeight +
                    UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits).lineHeight +
                    22
            ).rounded(.up)
        let preferredRulerHeight = viewLayout.isLarge
            ? minimumRulerHeight
            : (UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits).lineHeight + 14).rounded(.up)

        self.channelColumnWidth = channelColumnWidth ?? viewLayout.value(
            standard: viewLayout.value(compact: 100, regular: 148),
            large: 324
        )
        self.rowHeight = rowHeight ?? max(minimumRowHeight, preferredProgramHeight)
        self.rulerHeight = rulerHeight ?? max(minimumRulerHeight, preferredRulerHeight)
        self.pointsPerMinute = pointsPerMinute ?? viewLayout.value(
            standard: viewLayout.value(compact: 5, regular: 7),
            large: 13.5
        )
    }

    /// The horizontal distance that a span of time occupies.
    func width(from start: Date, to end: Date) -> CGFloat {
        max(0, CGFloat(start.distance(to: end) / 60) * pointsPerMinute)
    }
}
