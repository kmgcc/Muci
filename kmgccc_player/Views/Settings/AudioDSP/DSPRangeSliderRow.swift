//
//  DSPRangeSliderRow.swift
//  myPlayer2
//
//  Unified slider and scrubbable numeric row for DSP and audio settings.
//  Left: parameter title. Right: fixed-width slider and scrubbable number, so
//  the controls of consecutive rows share one column.
//

import SwiftUI

struct DSPRangeSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String = "dB"
    var fractionDigits: Int = 1
    var defaultValue: Double? = nil
    var defaultMarkerColor: Color = .secondary
    /// Supplementary note shown from an info mark beside the title.
    var info: String? = nil
    var onCommit: (() -> Void)? = nil

    static let sliderWidth: CGFloat = 168
    static let valueWidth: CGFloat = 58

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .settingsRowLabelStyle()
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
                .settingsInfoHint(info)
                .frame(maxWidth: .infinity, alignment: .leading)

            slider
                .frame(width: Self.sliderWidth)
                .accessibilityLabel(title)

            ScrubbableNumberField(
                value: $value,
                range: range,
                step: step,
                unit: unit,
                fractionDigits: fractionDigits,
                alignment: .trailing,
                onCommit: onCommit
            )
            .frame(width: Self.valueWidth, alignment: .trailing)
            .accessibilityLabel(title)
        }
    }

    @ViewBuilder
    private var slider: some View {
        if let defaultValue {
            DefaultSnappingSlider(
                value: sliderBinding,
                range: range,
                defaultValue: defaultValue,
                markerColor: defaultMarkerColor,
                // Keep the neighboring steps reachable when dragging slowly past the default.
                maxSnapDistance: step * 0.75,
                snapsOnlyWhileEditing: true,
                editingChanged: sliderEditingChanged
            )
        } else {
            Slider(value: sliderBinding, in: range, onEditingChanged: sliderEditingChanged)
        }
    }

    private func sliderEditingChanged(_ isEditing: Bool) {
        if !isEditing { onCommit?() }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { min(max(value, range.lowerBound), range.upperBound) },
            set: { raw in
                // A declared default can fall between regular steps.
                let next = raw == defaultValue ? raw : ScrubbableNumberField.quantize(
                    raw,
                    range: range,
                    step: step,
                    fractionDigits: fractionDigits
                )
                if next != value { value = next }
            }
        )
    }
}
