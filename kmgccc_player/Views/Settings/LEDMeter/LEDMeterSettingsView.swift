//
//  LEDMeterSettingsView.swift
//  myPlayer2
//
//  kmgccc_player - LED Meter Settings View
//

import SwiftUI

/// LED meter rows shown under an audio visualization selector while LED is
/// selected. The configuration is global, so every surface shares it.
struct LEDMeterSettingsView: View {
    var showsCount: Bool = true

    @Environment(AppSettings.self) private var settings
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    @State private var ledCount: Int = AppSettings.shared.ledCount
    @State private var brightnessLevels: Int = AppSettings.shared.ledBrightnessLevels

    var body: some View {
        VStack(spacing: presentationStyle.scaled(16)) {
            if showsCount {
                ledCountPicker
            }
            brightnessLevelsPicker
        }
        .onAppear {
            ledCount = settings.ledCount
            brightnessLevels = settings.ledBrightnessLevels
        }
        .onChange(of: ledCount) { _, _ in applyLedConfig() }
        .onChange(of: brightnessLevels) { _, _ in applyLedConfig() }
    }

    private var ledCountPicker: some View {
        HStack(spacing: presentationStyle.scaled(8)) {
            Text("settings.led.count")
                .settingsRowLabelStyle()
                .padding(.leading, labelIndent)
            Spacer()
            SettingsCapsuleSelector(
                options: [9, 11, 13, 15],
                selection: $ledCount,
                title: { $0.formatted() }
            )
        }
    }

    private var brightnessLevelsPicker: some View {
        HStack(spacing: presentationStyle.scaled(8)) {
            Text("settings.led.brightness")
                .settingsRowLabelStyle()
                .padding(.leading, labelIndent)
            Spacer()
            SettingsCapsuleSelector(
                options: [3, 5, 7],
                selection: $brightnessLevels,
                title: { $0.formatted() }
            )
        }
    }

    /// Labels sit one step in from the selector they belong to. The tracks
    /// keep the section's trailing alignment.
    private var labelIndent: CGFloat {
        presentationStyle.scaled(14)
    }

    private func applyLedConfig() {
        settings.ledCount = ledCount
        settings.ledBrightnessLevels = brightnessLevels

        ledMeterProvider.updateConfig(
            LEDMeterConfig(
                ledCount: ledCount,
                levels: brightnessLevels,
                cutoffHz: Float(settings.ledCutoffHz),
                sensitivity: settings.ledSensitivity,
                speed: Float(settings.ledSpeed),
                targetHz: settings.ledTargetHz
            )
        )
    }
}
