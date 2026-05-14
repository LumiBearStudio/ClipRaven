import Foundation
import xxHash_Swift

/// 텍스트 contentHash 계산용 64-bit xxHash. SHA-256보다 ~5x 빠르고
/// dedup 목적엔 충분 — 의도적 충돌 공격 위협 없음 (로컬 데이터).
///
/// Mac과 iOS가 같은 알고리즘을 써서 cross-device dedup이 hash 일치로
/// 빠르게 잡히도록 패키지에 둠. 사용자는 보통 `TextNormalizer.normalize`
/// 후 이 함수에 통과시킨다.
///
/// ## ⚠️ 보안 고려사항 (감사 A-L4)
/// xxHash 는 **non-cryptographic** hash 입니다. 64-bit 출력 공간이라
/// birthday-paradox 기준 ~2^32 항목에서 충돌 가능. 보안 위협 모델:
///
/// - **본인 단말 한정 dedup 용도**: 사용자가 임의의 두 텍스트로 같은 hash 를
///   만들 수 있으나, 동일 사용자 본인 데이터를 본인이 dedup 하는 시나리오라
///   공격 표면이 거의 없음. **현재 사용 OK**.
/// - **타 사용자가 우리 hash 공간을 조작**: 위협 없음. ClipRaven 은 사용자별
///   로컬/사용자 본인 iCloud private DB 분리.
/// - **암호학적 무결성 요구 (예: 서명, 인증)**: 절대 사용 금지. `SHA256.hash`
///   사용.
///
/// 즉, dedup / cache key / index 용도 한정. 보안 결정의 일부가 되어선 안 됨.
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
