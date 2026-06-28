//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import Foundation

/// The arrangement of multi-view tiles on screen.
enum MultiViewLayout: String, CaseIterable, Identifiable {

    /// Two equal columns (default).
    case sideBySide

    /// One large tile beside one smaller tile (asymmetric columns).
    case oneLarger

    /// Two equal rows, stacked vertically.
    case stacked

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .sideBySide: "Side by Side"
        case .oneLarger: "One Larger"
        case .stacked: "Stacked"
        }
    }

    var systemImage: String {
        switch self {
        case .sideBySide: "rectangle.split.2x1"
        case .oneLarger: "rectangle.lefthalf.inset.filled"
        case .stacked: "rectangle.split.1x2"
        }
    }

    /// The fraction of the larger dimension given to the primary tile in `oneLarger`.
    private static let primaryFraction: CGFloat = 0.68

    /// Computes the frame for each of `count` tiles within `size`.
    ///
    /// `primaryIndex` is the tile given the larger area in the `oneLarger` layout.
    /// Currently tuned for two tiles.
    func frames(in size: CGSize, count: Int, primaryIndex: Int) -> [CGRect] {
        guard count == 2 else {
            // Fallback: even horizontal split for any other count.
            let width = size.width / CGFloat(max(count, 1))
            return (0 ..< count).map { i in
                CGRect(x: CGFloat(i) * width, y: 0, width: width, height: size.height)
            }
        }

        switch self {
        case .sideBySide:
            let width = size.width / 2
            return [
                CGRect(x: 0, y: 0, width: width, height: size.height),
                CGRect(x: width, y: 0, width: width, height: size.height),
            ]

        case .oneLarger:
            let primaryWidth = (size.width * Self.primaryFraction).rounded()
            let secondaryWidth = size.width - primaryWidth
            let primaryIsFirst = primaryIndex == 0

            let firstWidth = primaryIsFirst ? primaryWidth : secondaryWidth
            let secondWidth = primaryIsFirst ? secondaryWidth : primaryWidth

            return [
                CGRect(x: 0, y: 0, width: firstWidth, height: size.height),
                CGRect(x: firstWidth, y: 0, width: secondWidth, height: size.height),
            ]

        case .stacked:
            let height = size.height / 2
            return [
                CGRect(x: 0, y: 0, width: size.width, height: height),
                CGRect(x: 0, y: height, width: size.width, height: height),
            ]
        }
    }
}
