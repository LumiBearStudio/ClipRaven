import SwiftUI
import Combine

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var themePreference: String = UserDefaults.standard.string(forKey: "theme") ?? "system" {
        didSet {
            UserDefaults.standard.set(themePreference, forKey: "theme")
            applyTheme()
        }
    }

    @Published var colorPresetRaw: String = UserDefaults.standard.string(forKey: "colorPreset") ?? "default" {
        didSet {
            UserDefaults.standard.set(colorPresetRaw, forKey: "colorPreset")
            NotificationCenter.default.post(name: .clipRavenThemeChanged, object: nil)
        }
    }

    @Published var currentTheme: AppTheme = .dark

    var colorPreset: ColorPreset {
        ColorPreset(rawValue: colorPresetRaw) ?? .default
    }

    private init() {
        applyTheme()
    }

    func applyTheme() {
        switch themePreference {
        case "dark":
            currentTheme = .dark
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light":
            currentTheme = .light
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            currentTheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
            NSApp.appearance = nil
        }
        NotificationCenter.default.post(name: .clipRavenThemeChanged, object: nil)
    }
}

enum AppTheme {
    case dark, light
}

// MARK: - Color Presets

enum ColorPreset: String, CaseIterable, Identifiable {
    case `default` = "default"
    case lavender  = "lavender"
    case ocean     = "ocean"
    case sunset    = "sunset"
    case mint      = "mint"
    case rose      = "rose"
    case amber     = "amber"
    case graphite  = "graphite"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default:  return "기본"
        case .lavender: return "라벤더"
        case .ocean:    return "오션"
        case .sunset:   return "선셋"
        case .mint:     return "민트"
        case .rose:     return "로즈"
        case .amber:    return "앰버"
        case .graphite: return "그래파이트"
        }
    }

    var accentColor: Color {
        switch self {
        case .default:  return Color(red: 0.25, green: 0.52, blue: 0.95)
        case .lavender: return Color(red: 0.72, green: 0.52, blue: 0.98)
        case .ocean:    return Color(red: 0.12, green: 0.72, blue: 0.88)
        case .sunset:   return Color(red: 0.98, green: 0.48, blue: 0.30)
        case .mint:     return Color(red: 0.22, green: 0.85, blue: 0.65)
        case .rose:     return Color(red: 0.96, green: 0.35, blue: 0.60)
        case .amber:    return Color(red: 0.98, green: 0.72, blue: 0.10)
        case .graphite: return Color(red: 0.58, green: 0.58, blue: 0.62)
        }
    }

    var swatchColor: Color { accentColor }
}
