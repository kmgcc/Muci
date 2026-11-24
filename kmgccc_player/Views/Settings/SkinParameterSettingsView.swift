import MotionKit
import SwiftUI

struct SkinParameterSettingsView: View {
    let skinID: String
    let surface: SkinSurface
    let definitions: [SkinParameterDefinition]
    let store: SkinParameterStore
    /// A scene skin draws at the render quality the lyrics share, so it offers that with its own options.
    var showsRenderQuality = false

    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var changedNextLine: Set<String> = []
    @State private var hintHideTask: Task<Void, Never>?

    private var visibleDefinitions: [SkinParameterDefinition] {
        Self.visibleDefinitions(skinID: skinID, surface: surface, definitions: definitions, store: store)
    }

    var body: some View {
        let _ = store.revision
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            if showsRenderQuality {
                AMLLLyricsRenderQualitySlider(quality: Binding(
                    get: { settings.amllLyricsRenderQuality },
                    set: { settings.amllLyricsRenderQuality = $0 }
                ))
                .settingsSearchAnchor("skin.renderQuality")
            }
            ForEach(sections, id: \.offset) { section in
                if let title = section.title { Text(title).settingsDescriptionStyle() }
                ForEach(section.definitions) { definition in
                    parameterRow(definition)
                        .settingsSearchAnchor("skin.parameter.\(definition.id)")
                }
            }
            if let hint = nextLineHint {
                Text(hint)
                    .settingsDescriptionStyle()
                    .transition(.opacity)
            }
        }
        .motionAnimation(.control, value: changedNextLine)
        .onDisappear { hintHideTask?.cancel() }
    }

    /// Names the parameters just adjusted that wait for the next lyric line, in declaration order.
    private var nextLineHint: String? {
        let titles = visibleDefinitions
            .filter { $0.applies == .nextLine && changedNextLine.contains($0.id) }
            .map(\.title)
        guard !titles.isEmpty else { return nil }
        return "调整\(titles.joined(separator: "、"))后，下一行歌词生效"
    }

    /// Shows the hint for a few seconds after a next-line parameter changes.
    private func noteNextLineChange(_ definition: SkinParameterDefinition) {
        guard definition.applies == .nextLine else { return }
        changedNextLine.insert(definition.id)
        hintHideTask?.cancel()
        hintHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            changedNextLine.removeAll()
        }
    }

    /// Consecutive rows that share a `section`, in declaration order.
    private var sections: [(offset: Int, title: String?, definitions: [SkinParameterDefinition])] {
        var result: [(offset: Int, title: String?, definitions: [SkinParameterDefinition])] = []
        for definition in visibleDefinitions {
            if let last = result.indices.last, result[last].title == definition.section {
                result[last].definitions.append(definition)
            } else {
                result.append((result.count, definition.section, [definition]))
            }
        }
        return result
    }

    @ViewBuilder
    private func parameterRow(_ definition: SkinParameterDefinition) -> some View {
        switch definition.control {
        case .toggle:
            SettingsSwitchRow(
                title: definition.title,
                isOn: Binding(
                    get: { booleanValue(store.value(skinID: skinID, surface: surface, definition: definition)) },
                    set: { set(definition, value: .boolean($0)) }
                )
            )
        case .range(let minimum, let maximum, let step):
            rangeRow(definition, minimum: minimum, maximum: maximum, step: step)
        case .choice(let choices):
            CapsulePicker(
                label: definition.title,
                options: choices,
                displayName: \.title,
                selection: Binding(
                    get: { textValue(store.value(skinID: skinID, surface: surface, definition: definition), choices: choices) },
                    set: { set(definition, value: .text($0)) }
                )
            )
        case .color:
            ColorPicker(definition.title, selection: Binding(
                get: { SkinValue(store.value(skinID: skinID, surface: surface, definition: definition)).colorValue?.swiftUIColor ?? themeStore.accentColor },
                set: { set(definition, value: .text(OKLCHColor(NSColor($0)).hexString)) }
            )).settingsRowLabelStyle()
        }
    }

    private func rangeRow(
        _ definition: SkinParameterDefinition,
        minimum: Double,
        maximum: Double,
        step: Double
    ) -> some View {
        let tint = presentationStyle.settingsSelectedTextColor(accentColor: themeStore.accentColor, appColors: nil)
        return DSPRangeSliderRow(
            title: definition.title,
            value: Binding(
                get: { numberValue(store.value(skinID: skinID, surface: surface, definition: definition)) },
                set: { set(definition, value: .number($0)) }
            ),
            range: minimum...maximum,
            step: step,
            unit: "",
            fractionDigits: Self.fractionDigits(for: step),
            defaultValue: numberValue(definition.defaultValue),
            defaultMarkerColor: tint.opacity(0.85)
        )
        .tint(tint)
    }

    /// Decimal places the step needs, so 0.05 shows as 0.25 and 1 shows as 3.
    private static func fractionDigits(for step: Double) -> Int {
        var digits = 0
        var scaled = step
        while digits < 4, abs(scaled - scaled.rounded()) > 1e-9 {
            scaled *= 10
            digits += 1
        }
        return digits
    }

    private func set(_ definition: SkinParameterDefinition, value: SkinParameterValue) {
        noteNextLineChange(definition)
        store.set(skinID: skinID, surface: surface, definition: definition, value: value)
    }

    static func visibleDefinitions(
        skinID: String,
        surface: SkinSurface,
        definitions: [SkinParameterDefinition],
        store: SkinParameterStore
    ) -> [SkinParameterDefinition] {
        definitions.filter {
            $0.isUserVisible && $0.surfaces.contains(surface)
                && isVisible($0, skinID: skinID, surface: surface, definitions: definitions, store: store)
        }
    }

    private static func isVisible(
        _ definition: SkinParameterDefinition,
        skinID: String,
        surface: SkinSurface,
        definitions: [SkinParameterDefinition],
        store: SkinParameterStore
    ) -> Bool {
        guard let condition = definition.visibleWhen else { return true }
        var environment = SkinCompileEnvironment()
        environment.params = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, SkinValue($0.defaultValue).type) })
        guard let expression = try? SkinExpressionCompiler.compile(.text(condition.hasPrefix("=") ? condition : "=" + condition), expected: .boolean, environment: environment) else { return false }
        let data = SkinSceneData()
        data.set(.params, store.values(skinID: skinID, surface: surface, definitions: definitions).mapValues(SkinValue.init))
        return expression.evaluate(.init(data: data)).isTruthy
    }

    private func booleanValue(_ value: SkinParameterValue) -> Bool {
        guard case .boolean(let value) = value else { return false }
        return value
    }

    private func numberValue(_ value: SkinParameterValue) -> Double {
        guard case .number(let value) = value else { return 0 }
        return value
    }

    private func textValue(_ value: SkinParameterValue, choices: [SkinParameterDefinition.Choice]) -> String {
        if case .text(let value) = value { return value }
        return choices.first?.id ?? ""
    }
}
