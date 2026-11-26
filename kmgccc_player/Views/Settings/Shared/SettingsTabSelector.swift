//
//  SettingsTabSelector.swift
//  myPlayer2
//
//  kmgccc_player - Reusable Tab Selector for Settings Pages
//

import SwiftUI

/// Settings navigation with a material track and a Liquid Glass selection.
struct SettingsTabSelector: View {
    let tabs: [String]
    let fillsWidth: Bool
    @Binding var selectedTab: Int

    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    init(tabs: [String], selectedTab: Binding<Int>, fillsWidth: Bool = false) {
        self.tabs = tabs
        self._selectedTab = selectedTab
        self.fillsWidth = fillsWidth
    }

    var body: some View {
        SlidingSelector(
            segments: Array(tabs.indices),
            selection: $selectedTab,
            hSpacing: 0,
            background: { Color.clear },
            knob: {
                Color.clear
                    .glassEffect(.clear, in: Capsule())
            },
            content: { index, isSelected in
                Text(tabs[index])
                    .font(.system(
                        size: presentationStyle.scaled(13),
                        weight: isSelected ? .medium : .regular
                    ))
                    .foregroundStyle(
                        isSelected
                            ? presentationStyle.settingsPrimaryTextColor(appColors: appColors)
                            : presentationStyle.settingsSecondaryTextColor(appColors: appColors)
                    )
                    .lineLimit(1)
                    .frame(
                        minWidth: presentationStyle.scaled(presentationStyle.isCompact ? 96 : 72),
                        maxWidth: fillsWidth ? .infinity : nil,
                        minHeight: presentationStyle.tabHeight
                    )
                    .padding(.vertical, presentationStyle.scaled(3))
                    .accessibilityValue(Text(isSelected ? "已选择" : "未选择"))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        )
        .padding(presentationStyle.scaled(3))
        .background(.ultraThinMaterial, in: Capsule())
        .fixedSize(horizontal: !fillsWidth, vertical: false)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var selectedTab = 0
        
        var body: some View {
            SettingsTabSelector(tabs: ["常规", "歌词"], selectedTab: $selectedTab)
                .padding()
        }
    }
    return PreviewWrapper()
}
