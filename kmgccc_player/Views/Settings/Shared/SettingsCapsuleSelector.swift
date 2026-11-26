import SwiftUI

struct SettingsCapsuleStyle {
    let presentation: FullscreenSettingsPresentationStyle
    let appColors: SettingsAppForegroundColors?
    let accentColor: Color

    var labelFont: Font { .system(size: presentation.scaled(12)) }
    var segmentHeight: CGFloat { presentation.scaled(24) }
    var trackInset: CGFloat { presentation.scaled(3) }

    var selectedColor: Color {
        presentation.settingsSelectedTextColor(accentColor: accentColor, appColors: appColors)
    }

    var unselectedColor: Color {
        presentation.settingsSecondaryTextColor(appColors: appColors)
    }

    var trackColor: Color {
        presentation.settingsSegmentedTrackColor(appColors: appColors)
    }

    var knobColor: Color { selectedColor.opacity(0.18) }
}

/// A borderless segmented control for settings rows.
struct SettingsCapsuleSelector<Selection: Hashable>: View {
    let options: [Selection]
    @Binding var selection: Selection
    var accentColor: Color? = nil
    let title: (Selection) -> String

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentation
    @Environment(\.settingsAppForegroundColors) private var appColors

    var body: some View {
        let style = SettingsCapsuleStyle(
            presentation: presentation,
            appColors: appColors,
            accentColor: accentColor ?? themeStore.accentColor
        )

        SlidingSelector(
            segments: options,
            selection: $selection,
            hSpacing: 0,
            background: { Color.clear },
            knob: { Capsule().fill(style.knobColor) },
            content: { option, isSelected in
                Text(title(option))
                    .font(style.labelFont)
                    .foregroundStyle(isSelected ? style.selectedColor : style.unselectedColor)
                    .lineLimit(1)
                    .padding(.horizontal, presentation.scaled(10))
                    .frame(minWidth: presentation.scaled(44))
                    .frame(height: style.segmentHeight)
                    .accessibilityValue(Text(isSelected ? "已选择" : "未选择"))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        )
        .padding(style.trackInset)
        .background(Capsule().fill(style.trackColor))
        .fixedSize(horizontal: true, vertical: false)
    }
}
