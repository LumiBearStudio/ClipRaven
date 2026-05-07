import Foundation
import xxHash_Swift

/// 텍스트 contentHash 계산용 64-bit xxHash. SHA-256보다 ~5x 빠르고
/// dedup 목적엔 충분 — 의도적 충돌 공격 위협 없음 (로컬 데이터).
///
/// Mac과 iOS가 같은 알고리즘을 써서 cross-device dedup이 hash 일치로
/// 빠르게 잡히도록 패키지에 둠. 사용자는 보통 `TextNormalizer.normalize`
/// 후 이 함수에 통과시킨다.
public enum XXHash64Wrapper {
    /// Compute xxHash64 digest of a string (after normalization).
    public static func hash(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = XXH64.digest(data)
        return String(format: "%016llx", digest)
    }

    /// Compute xxHash64 digest of raw data.
    public static func hash(_ data: Data) -> String {
        let digest = XXH64.digest(data)
        return String(format: "%016llx", digest)
    }
}
