//
//  CapsulePicker.swift
//  myPlayer2
//
//  kmgccc_player - Reusable Capsule-style Picker Component
//

import SwiftUI

/// A reusable capsule-style picker with buttons inside a capsule container.
/// Positions setting label on the left and options right-aligned on the right.
struct CapsulePicker<Option: Hashable, Value: Hashable>: View {
    let label: String
    let options: [Option]
    let optionID: (Option) -> Value
    let displayName: (Option) -> String
    @Binding var selection: Value
    var accentColor: Color? = nil
    /// Supplementary note shown from an info mark beside the label.
    var info: String? = nil

    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    /// Initializer for Identifiable options where selection is Option.ID
    init(
        label: String,
        options: [Option],
        displayName: @escaping (Option) -> String,
        selection: Binding<Value>,
        accentColor: Color? = nil,
        info: String? = nil
    ) where Option: Identifiable, Option.ID == Value {
        self.label = label
        self.options = options
        self.optionID = { $0.id }
        self.displayName = displayName
        self._selection = selection
        self.accentColor = accentColor
        self.info = info
    }

    /// Initializer for self-identified options where Option == Value (e.g. Enums, Strings)
    init(
        label: String,
        options: [Option],
        selection: Binding<Value>,
        displayName: @escaping (Option) -> String = { "\($0)" },
        accentColor: Color? = nil,
        info: String? = nil
    ) where Option == Value {
        self.label = label
        self.options = options
        self.optionID = { $0 }
        self.displayName = displayName
        self._selection = selection
        self.accentColor = accentColor
        self.info = info
    }

    var body: some View {
        HStack(spacing: presentationStyle.compactInlineSpacing) {
            Text(label)
                .settingsRowLabelStyle()
                .settingsInfoHint(info)

            Spacer()

            SettingsCapsuleSelector(
                options: options.map(optionID),
                selection: $selection,
                accentColor: accentColor
            ) { id in
                options.first(where: { optionID($0) == id }).map(displayName) ?? ""
            }
        }
    }
}
