import AppKit
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Settings 탭들이 공유하는 작은 헬퍼 모음.
/// 이전엔 SettingsWindow.swift 안에 private 으로 묶여 있었으나, 탭 파일 분리에 따라
/// internal 가시성으로 끌어올려 별도 파일로 분리.

// MARK: - Apple Intelligence status helper

func appleIntelligenceStatusText() -> String {
    // 회귀 방어: String(localized:) 를 통과시켜야 영문 locale 에서 영문 번역이
    // 표시된다. 단순 `return "사용 가능"` 은 호출자 `Text(string)` 가
    // LocalizedStringKey 추론을 못해 영문 환경에서 한국어 그대로 노출됨.
    #if canImport(FoundationModels)
    if #available(macOS 26, *) {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return String(localized: "사용 가능")
        case .unavailable(let reason):
            let format = String(localized: "사용 불가: %@")
            return String(format: format, String(describing: reason))
        @unknown default:
            return String(localized: "알 수 없음")
        }
    }
    return String(localized: "macOS 26 이상 필요")
    #else
    return String(localized: "FoundationModels 프레임워크 미포함 (Xcode 26+ SDK 필요)")
    #endif
}

extension View {
    func darkFormStyle() -> some View {
        self.formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color(NSColor.windowBackgroundColor))
    }
}

/// Settings Form 의 SECTION 헤더 — 작은 회색 라벨.
struct SectionHeader: View {
    let title: LocalizedStringKey   // must be LocalizedStringKey, not String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.bottom, 2)
    }
}
