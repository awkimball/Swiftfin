//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

struct EPGDateMenu: View {

    @AdaptiveLayout
    private var viewLayout

    @FocusState
    private var isFocused: Bool

    let viewModel: EPGViewModel

    private var selection: Binding<Date> {
        Binding(
            get: { viewModel.selectedDate },
            set: {
                viewModel.setDate(date: $0)
            }
        )
    }

    private var selectedLabel: String {
        viewModel.selectedDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    @ContentBuilder
    private var pickerContent: some View {
        Picker(L10n.date, selection: selection) {
            ForEach(viewModel.availableDates, id: \.self) { date in
                Text(date.formatted(.dateTime.weekday(viewLayout.isLarge ? .wide : .abbreviated).month(.abbreviated).day()))
                    .tag(date)
            }
        }
    }

    @ContentBuilder
    var body: some View {
        if viewLayout.isLarge {
            Menu {
                pickerContent
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .font(.system(size: 20, weight: .semibold))

                    Text(selectedLabel)
                        .font(.system(size: 21, weight: .semibold))
                        .lineLimit(1)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .opacity(0.72)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .backport
                .glassEffect(
                    .regular.selection(
                        tint: isFocused ? .white : nil,
                        foregroundColor: isFocused ? .black : .primary
                    )
                    .interactive(),
                    in: .capsule
                )
            }
            .buttonStyle(EPGButtonStyle())
            .focused($isFocused)
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(.easeInOut(duration: 0.1), value: isFocused)
        } else {
            Menu(L10n.date, systemImage: "calendar") {
                pickerContent
            }
        }
    }
}
