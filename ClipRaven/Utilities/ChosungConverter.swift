import Foundation

enum ChosungConverter {
    // Korean initial consonants (초성)
    private static let chosungList: [Character] = [
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"
    ]

    /// Extract initial consonants from Korean text
    /// "클립보드" → "ㅋㄹㅂㄷ"
    static func extractChosung(from text: String) -> String {
        var result = ""

        for char in text {
            // Swift Character 는 항상 ≥1 개의 Unicode.Scalar 를 가진다 (빈 Character 는 표현 불가).
            // 따라서 first! 는 안전. swiftlint:disable:next force_unwrapping
            let scalar = char.unicodeScalars.first!.value

            // Hangul syllable range: U+AC00 ~ U+D7A3
            if scalar >= 0xAC00 && scalar <= 0xD7A3 {
                let index = Int((scalar - 0xAC00) / 588)
                if index < chosungList.count {
                    result.append(chosungList[index])
                }
            } else if isChosung(char) {
                result.append(char)
            }
            // Skip non-Korean characters for chosung index
        }

        return result
    }

    /// Check if entire query is chosung-only (for fallback search)
    static func isChosungOnly(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.allSatisfy { isChosung($0) }
    }

    /// 쿼리를 초성 경로로 라우팅할지 결정.
    ///
    /// 판단 기준: 자음(초성) 포함 AND 완성형 한글 없음.
    /// "ㄱ나" 같은 혼합도 초성 경로로 처리 — 완성형이 섞이면 FTS가 더 정확하므로
    /// hasFullHangul 검사로 두 경로를 구분한다.
    ///
    /// iOS `ClipListViewModel.performSearch(_:)`와 동일 로직.
    static func shouldUseChosungSearch(_ text: String) -> Bool {
        let hasChosung = text.contains { isChosung($0) }
        let hasFullHangul = text.contains {
            // Character 는 항상 ≥1 scalar — first! 안전. swiftlint:disable:next force_unwrapping
            let v = $0.unicodeScalars.first!.value
            return v >= 0xAC00 && v <= 0xD7A3
        }
        return hasChosung && !hasFullHangul
    }

    private static func isChosung(_ char: Character) -> Bool {
        let chosungSet: Set<Character> = Set(chosungList)
        return chosungSet.contains(char)
    }
}
