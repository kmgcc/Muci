//
//  AMLLLyricsRenderQualitySlider.swift
//  myPlayer2
//
//  kmgccc_player - Shared AMLL lyrics render quality control
//

import SwiftUI

struct AMLLLyricsRenderQualitySlider: View {
    @Binding var quality: AppSettings.AMLLLyricsRenderQuality
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    var body: some View {
        HStack(spacing: presentationStyle.scaled(12)) {
            VStack(alignment: .leading, spacing: presentationStyle.scaled(2)) {
                Text("歌词与皮肤渲染质量")
                    .font(presentationStyle.rowLabelFont)
                    .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                Text(quality.resolutionDescription)
                    .font(presentationStyle.captionFont)
                    .foregroundStyle(presentationStyle.settingsTertiaryTextColor(appColors: appColors))
            }

            Spacer(minLength: presentationStyle.scaled(12))

            SettingsCapsuleSelector(
                options: AppSettings.AMLLLyricsRenderQuality.allCases,
                selection: $quality,
                title: \.title
            )
        }
    }
}
