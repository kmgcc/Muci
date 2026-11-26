//
//  AMLLLyricSpringSettingsControls.swift
//  myPlayer2
//
//  kmgccc_player - Shared AMLL lyric spring controls
//

import SwiftUI

struct AMLLLyricSpringSettingsControls: View {
    @Binding var duration: Double
    @Binding var bounce: Double

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: presentationStyle.scaled(14)) {
                    sliderPane(
                        title: "持续时间",
                        valueText: String(format: "%.2f", duration),
                        value: $duration,
                        range: AppSettings.lyricSpringDurationRange,
                        defaultValue: AppSettings.defaultLyricSpringDuration
                    )
                    .frame(maxWidth: .infinity)

                    sliderPane(
                        title: "反弹",
                        valueText: String(format: "%.2f", bounce),
                        value: $bounce,
                        range: AppSettings.lyricSpringBounceRange,
                        defaultValue: AppSettings.defaultLyricSpringBounce
                    )
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                    sliderPane(
                        title: "持续时间",
                        valueText: String(format: "%.2f", duration),
                        value: $duration,
                        range: AppSettings.lyricSpringDurationRange,
                        defaultValue: AppSettings.defaultLyricSpringDuration
                    )
                    sliderPane(
                        title: "反弹",
                        valueText: String(format: "%.2f", bounce),
                        value: $bounce,
                        range: AppSettings.lyricSpringBounceRange,
                        defaultValue: AppSettings.defaultLyricSpringBounce
                    )
                }
            }
        }
    }

    private var markerColor: Color {
        presentationStyle.valueTextColor(accentColor: themeStore.accentColor).opacity(0.85)
    }

    private func sliderPane(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                Text(title)
                    .font(presentationStyle.rowLabelFont)
                    .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))

                Spacer()

                Text(valueText)
                    .font(presentationStyle.rowValueFont)
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
            }

            DefaultSnappingSlider(
                value: value,
                range: range,
                defaultValue: defaultValue,
                markerColor: markerColor
            )
            .frame(height: presentationStyle.tabHeight)
        }
    }
}
