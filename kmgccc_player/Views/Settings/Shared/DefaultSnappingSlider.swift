import AppKit
import SwiftUI

struct DefaultSnappingSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var markerColor: Color = .secondary.opacity(0.72)
    var maxSnapDistance: Double = .infinity
    var snapsOnlyWhileEditing = false
    var editingChanged: (Bool) -> Void = { _ in }

    @State private var isEditing = false
    @State private var movedAwayFromDefault = false
    @State private var hasSnappedDuringEditing = false

    private var snapTolerance: Double {
        min((range.upperBound - range.lowerBound) * 0.04, maxSnapDistance)
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { value },
            set: { proposedValue in
                let clampedValue = min(max(proposedValue, range.lowerBound), range.upperBound)
                let shouldSnap = (!snapsOnlyWhileEditing || isEditing)
                    && abs(clampedValue - defaultValue) <= snapTolerance

                if shouldSnap {
                    if isEditing,
                       movedAwayFromDefault,
                       !hasSnappedDuringEditing {
                        hasSnappedDuringEditing = true
                        NSHapticFeedbackManager.defaultPerformer.perform(
                            .alignment,
                            performanceTime: .drawCompleted
                        )
                    }
                    value = defaultValue
                } else {
                    movedAwayFromDefault = true
                    hasSnappedDuringEditing = false
                    value = clampedValue
                }
            }
        )
    }

    var body: some View {
        Slider(
            value: sliderBinding,
            in: range
        ) { editing in
            isEditing = editing
            if editing {
                movedAwayFromDefault = abs(value - defaultValue) > snapTolerance
                hasSnappedDuringEditing = false
            } else {
                movedAwayFromDefault = false
                hasSnappedDuringEditing = false
            }
            editingChanged(editing)
        }
        .overlay {
            if value != defaultValue {
                GeometryReader { geometry in
                    Circle()
                        .fill(markerColor)
                        .frame(width: 4, height: 4)
                        .position(
                            x: defaultMarkerX(in: geometry.size),
                            y: geometry.size.height / 2
                        )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private func defaultMarkerX(in size: CGSize) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return size.width / 2 }
        let normalizedDefault = (defaultValue - range.lowerBound) / span
        let horizontalInset = min(size.height / 2, size.width / 2)
        return horizontalInset + (size.width - horizontalInset * 2) * CGFloat(normalizedDefault)
    }
}
