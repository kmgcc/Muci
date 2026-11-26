import MotionKit
import SwiftUI

/// The glass capsule that shows the volume while the scroll wheel sets it.
struct VolumeScrollHUD: View {
    let volume: Double
    let scale: CGFloat
    let foregroundProfile: FullscreenMiniPlayerForegroundProfile
    let glassStyle: FullscreenControlsGlassStyle

    var body: some View {
        let percentage = Int((volume * 100).rounded())
        HStack(spacing: 12 * scale) {
            Image(systemName: icon)
                .font(.system(size: 22 * scale, weight: .semibold))
                .frame(width: 32 * scale)

            Text("\(percentage)%")
                .font(.system(size: 24 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
                .motionAnimation(.contentReplacement, value: percentage)
                .frame(width: 86 * scale)
        }
        .foregroundStyle(foregroundProfile.primaryColor.opacity(0.96))
        .compositingGroup()
        .blendMode(foregroundProfile.iconBlendMode)
        .frame(width: 184 * scale, height: 58 * scale)
        .contentShape(Capsule())
        .liquidGlassPill(
            colorScheme: glassStyle.colorScheme,
            accentColor: nil as Color?,
            prominence: .standard,
            materialStyle: glassStyle.materialStyle,
            isFloating: true
        )
        .environment(\.colorScheme, glassStyle.colorScheme)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Volume")
        .accessibilityValue(Text("\(percentage)%"))
    }

    private var icon: String {
        switch volume {
        case ...0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}
