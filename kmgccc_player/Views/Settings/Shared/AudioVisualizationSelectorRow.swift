//
//  AudioVisualizationSelectorRow.swift
//  myPlayer2
//

import MotionKit
import SwiftUI

struct AudioVisualizationSelectorRow: View {
    let title: String
    @Binding var selection: AudioVisualizationKind
    /// Mini Player sizes its LED meter from the available width, so it has no
    /// meaningful count choice to offer.
    var showsLEDCount: Bool = true
    /// Mini Player spectrum width follows its available space, so only skin
    /// surfaces offer a capsule count.
    var showsSpectrumCount: Bool = true

    @AppStorage(SkinSpectrumBandCount.storageKey)
    private var spectrumBandCount = SkinSpectrumBandCount.defaultValue

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    private var knobColor: Color {
        if presentationStyle.usesMaterialSectionCards {
            return presentationStyle.primaryTextColor
        }
        return themeStore.accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            selectorRow

            // LED rows belong to the LED choice and appear only with it.
            if selection == .led {
                LEDMeterSettingsView(showsCount: showsLEDCount)
                    .transition(.opacity)
            }

            if selection == .spectrum && showsSpectrumCount {
                spectrumCountRow
                    .transition(.opacity)
            }
        }
        .motionAnimation(.microInteraction, value: selection == .led)
        .motionAnimation(.microInteraction, value: selection == .spectrum && showsSpectrumCount)
    }

    private var spectrumCountRow: some View {
        let range = SkinSpectrumBandCount.range
        let count = SkinSpectrumBandCount.clamped(spectrumBandCount)
        return HStack(spacing: presentationStyle.scaled(8)) {
            Text("段数")
                .settingsRowLabelStyle()
                .padding(.leading, presentationStyle.scaled(14))
            Spacer()
            Slider(
                value: Binding(
                    get: { Double(count) },
                    set: { spectrumBandCount = SkinSpectrumBandCount.clamped(Int($0.rounded())) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .tint(knobColor)
            .frame(width: presentationStyle.scaled(140))
            Text("\(count)")
                .font(presentationStyle.captionFont)
                .foregroundStyle(presentationStyle.settingsSecondaryTextColor(appColors: appColors))
                .monospacedDigit()
                .frame(width: presentationStyle.scaled(20), alignment: .trailing)
        }
    }

    private var selectorRow: some View {
        HStack(spacing: presentationStyle.compactInlineSpacing) {
            Text(title)
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
            Spacer()
            SettingsCapsuleSelector(
                options: AudioVisualizationKind.allCases,
                selection: $selection,
                title: \.displayName
            )
        }
    }
}
