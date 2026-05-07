import Foundation

/// 이미지 클립 동기화 정책. Mac과 iOS가 같은 enum을 공유해 양쪽 동작이
/// 항상 일치하도록 한다.
///
/// 저장 위치: `UserDefaults.standard` (App Group 공유는 메인 앱 settings UI만
/// 쓰므로 표준 UserDefaults로 충분). iOS extensions는 read-only로 접근 불가
/// 하지만 sync 로직은 메인 앱 프로세스에서만 실행됨 → 문제 없음.
///
/// 정책 변경 즉시 반영 — sync 사이클이 매번 `current()`를 호출.
public enum ImageSyncMode: String, CaseIterable, Codable {
    /// 텍스트만 sync. 이미지는 다른 디바이스에 보이지 않는다.
    case off

    /// 썸네일(~10–50KB)만 sync. 이미지는 다른 디바이스에서 미리보기 가능,
    /// 단 paste 시 원본 해상도 아님 (썸네일 그대로). 기본값 — 데이터 절약.
    case thumbnailOnly

    /// 썸네일 + 원본(CKAsset)까지 sync. 다른 디바이스에서 원본 paste 가능.
    /// 사용자 iCloud 쿼터를 빠르게 소비할 수 있어 명시적 opt-in.
    case full

    public var displayName: String {
        switch self {
        case .off: return String(localized: "끄기 (텍스트만)", bundle: .module)
        case .thumbnailOnly: return String(localized: "썸네일만 (작게)", bundle: .module)
        case .full: return String(localized: "원본 포함", bundle: .module)
        }
    }

    public var summary: String {
        switch self {
        case .off: return String(localized: "이미지는 다른 기기에 보이지 않음", bundle: .module)
        case .thumbnailOnly: return String(localized: "추천 — 이미지 미리보기만, 데이터 절약", bundle: .module)
        case .full: return String(localized: "원본 paste 가능, iCloud 저장공간 사용", bundle: .module)
        }
    }
}

/// 원본 이미지 size cap — full 모드에서 이 크기를 넘으면 binary는 동기화하지
/// 않고 썸네일만 보낸다. 다른 디바이스에는 "원본 너무 큼" 배지가 표시됨.
public enum ImageSyncSizeCap: Int, CaseIterable, Codable {
    case mb10 = 10
    case mb25 = 25
    case mb50 = 50
    case unlimited = 0

    /// 바이트 단위. unlimited 의 경우 Int.max 반환.
    public var bytes: Int {
        if self == .unlimited { return .max }
        return rawValue * 1024 * 1024
    }

    public var displayName: String {
        switch self {
        case .mb10: return String(localized: "10 MB 이하만", bundle: .module)
        case .mb25: return String(localized: "25 MB 이하만", bundle: .module)
        case .mb50: return String(localized: "50 MB 이하만", bundle: .module)
        case .unlimited: return String(localized: "제한 없음", bundle: .module)
        }
    }
}

/// 사용자 동기화 옵션 read/write. 양 플랫폼 동일 키 사용.
///
/// `current()`는 sync 사이클마다 호출되므로 가벼워야 한다 — UserDefaults
/// 단순 read만 수행하고 캐시 안 함 (Settings에서 변경 즉시 반영).
public enum ImageSyncSettings {

    public struct Snapshot: Equatable {
        public let mode: ImageSyncMode
        public let sizeCap: ImageSyncSizeCap
        /// iOS 셀룰러에서 큰 binary 다운로드 차단. Mac에선 의미 없으나
        /// 같은 키 공유로 단순화.
        public let cellularAllowed: Bool

        public init(mode: ImageSyncMode, sizeCap: ImageSyncSizeCap, cellularAllowed: Bool) {
            self.mode = mode
            self.sizeCap = sizeCap
            self.cellularAllowed = cellularAllowed
        }
    }

    private enum Key {
        static let mode    = "imageSyncMode"
        static let sizeCap = "imageSyncSizeCapMB"
        static let cell    = "imageSyncCellularAllowed"
    }

    /// 기본값 — sync 자체는 켜진 상태에서 썸네일만, cap 10MB, 셀룰러 차단.
    public static let defaultSnapshot = Snapshot(
        mode: .thumbnailOnly,
        sizeCap: .mb10,
        cellularAllowed: false
    )

    public static func current(from defaults: UserDefaults = .standard) -> Snapshot {
        let mode: ImageSyncMode = defaults.string(forKey: Key.mode)
            .flatMap(ImageSyncMode.init(rawValue:))
            ?? defaultSnapshot.mode
        let capInt = defaults.object(forKey: Key.sizeCap) as? Int
        let sizeCap = capInt.flatMap(ImageSyncSizeCap.init(rawValue:)) ?? defaultSnapshot.sizeCap
        let cellularAllowed = defaults.object(forKey: Key.cell) as? Bool
            ?? defaultSnapshot.cellularAllowed
        return Snapshot(mode: mode, sizeCap: sizeCap, cellularAllowed: cellularAllowed)
    }

    public static func setMode(_ mode: ImageSyncMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Key.mode)
    }

    public static func setSizeCap(_ cap: ImageSyncSizeCap, to defaults: UserDefaults = .standard) {
        defaults.set(cap.rawValue, forKey: Key.sizeCap)
    }

    public static func setCellularAllowed(_ allowed: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(allowed, forKey: Key.cell)
    }
}
