import SwiftUI

/// 외관 설정 탭 — 테마 색상 프리셋 그리드.
struct AppearanceSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage(AppAnimations.key) private var animationsEnabled = true

    var body: some View {
        Form {
            Section {
                Picker("테마", selection: $themeManager.themePreference) {
                    Label("시스템 기본값", systemImage: "circle.lefthalf.filled").tag("system")
                    Label("다크",         systemImage: "moon.fill").tag("dark")
                    Label("라이트",       systemImage: "sun.max.fill").tag("light")
                }
                .pickerStyle(.radioGroup)
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.colorTheme")
            }

            Section {
                ColorPresetGridView(selected: themeManager.colorPresetRaw) { preset in
                    themeManager.colorPresetRaw = preset.rawValue
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                SectionHeader(title: "header.accentColor")
            }

            Section {
                Toggle("애니메이션", isOn: $animationsEnabled)
                    .listRowBackground(Color(NSColor.controlBackgroundColor))
                Text("끄면 화면 전환과 카드 펼침이 즉시 표시됩니다. 시스템의 '동작 줄이기' 설정과 별개입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.motion")
            }
        }
        .darkFormStyle()
        .tint(themeManager.colorPreset.accentColor)
    }
}

// MARK: - Color Preset Grid

private struct ColorPresetGridView: View {
    let selected: String
    let onSelect: (ColorPreset) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(ColorPreset.allCases) { preset in
                ColorSwatchCell(
                    preset: preset,
                    isSelected: preset.rawValue == selected,
                    onTap: { onSelect(preset) }
                )
            }
        }
    }
}

private struct ColorSwatchCell: View {
    let preset: ColorPreset
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(preset.swatchColor)
                        .frame(width: 32, height: 32)
                    if isSelected {
                        Circle()
                            .strokeBorder(Color(NSColor.labelColor), lineWidth: 2.5)
                            .frame(width: 36, height: 36)
                    }
                }
                Text(preset.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color(NSColor.labelColor) : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
