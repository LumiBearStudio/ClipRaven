import Foundation
import GRDB

/// App Group SQLite 공유 헬퍼 — iOS Extension 들이 메인 앱과 같은 DB 파일에
/// 일관된 설정으로 접근할 수 있게 한다.
///
/// 이전엔 KeyboardViewController / ShareViewController / ClipWidgetProvider /
/// CopyClipIntent 가 각자 인라인으로 같은 `DatabasePool` 생성 코드를 4번 중복
/// 작성했고, `busyMode` / `synchronous` 설정이 일관되지 않았다
/// (아키텍처 감사 C 트랙). 본 헬퍼로 단일 진입점화.
///
/// **주의**: Persistent WAL 설정은 메인 앱의 `AppDatabase.makeShared()` 가
/// read-write 커넥션에서 sqlite3_file_control 로 set 한다. Extension 의
/// read/write 커넥션은 WAL 파일이 이미 만들어져 있는 환경에서 동작하므로
/// 추가 설정 불필요.
public enum AppGroupDatabase {

    /// 메인 앱 + Extension 이 공유하는 App Group ID. **플랫폼마다 형식이 다르다.**
    ///
    /// - macOS: Team ID 접두사 형식. macOS 프로비저닝 프로파일은
    ///   `63ZN5B3LHU.*` 와일드카드만 허가하므로 `group.*` 를 쓰면 매 실행마다
    ///   "다른 앱의 데이터에 접근" 권한 창이 뜬다 (ef170b5 에서 고친 문제).
    /// - iOS: 반드시 `group.` 접두사. iOS 는 Team ID 형식 App Group 을 허용하지
    ///   않는다 — 실기기·아카이브 서명이 되지 않고, 억지로 서명하면
    ///   `containerURL` 이 nil 이 되어 키보드·공유 확장이 DB 를 못 연다.
    ///   ef170b5 가 iOS 까지 Team ID 형식으로 바꿔서 그 뒤로 iOS 는
    ///   시뮬레이터(서명 검사 없음)에서만 빌드되고 있었다.
    ///
    /// 두 플랫폼의 컨테이너는 서로 다른 기기에 있으므로 ID 가 달라도 문제없다.
    /// App Group ID 가 필요한 곳은 반드시 이 상수를 쓸 것 — 문자열을 흩어 두면
    /// 이번처럼 한쪽만 바뀐다.
    #if os(iOS)
    public static let appGroupID = "group.com.lumibear.ClipRaven"
    #else
    public static let appGroupID = "63ZN5B3LHU.com.lumibear.ClipRaven"
    #endif

    /// App Group 컨테이너 안의 sqlite 파일 URL. nil 이면 entitlement 누락.
    public static var sharedSQLiteURL: URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        return containerURL
            .appendingPathComponent("ClipRaven", isDirectory: true)
            .appendingPathComponent("clipraven.sqlite")
    }

    /// Extension 용 readonly `DatabasePool`. Keyboard / Widget Provider /
    /// CopyClipIntent 가 사용. 메인 앱과 lock 충돌 시 5초 대기 + synchronous=NORMAL.
    public static func makeReadOnlyPool() -> DatabasePool? {
        guard let dbURL = sharedSQLiteURL else { return nil }
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.readonly = true
        config.busyMode = .timeout(5.0)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return try? DatabasePool(path: dbURL.path, configuration: config)
    }

    /// Extension 용 read-write `DatabasePool`. Share Extension 만 사용
    /// (메인 앱이 켜져 있지 않을 때 클립을 직접 insert 해야 하므로).
    /// busyMode + synchronous 일치, Persistent WAL 은 메인 앱이 이미 set.
    public static func makeWritablePool() -> DatabasePool? {
        guard let dbURL = sharedSQLiteURL else { return nil }
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5.0)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return try? DatabasePool(path: dbURL.path, configuration: config)
    }

    /// 이미지 원본이 저장되는 App Group 안의 `images/` 디렉토리.
    /// Share Extension 이 사진을 저장할 때 + 메인 앱 cleanOrphanedImages 가 enumerate.
    public static var sharedImagesDirectory: URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        let url = containerURL.appendingPathComponent("ClipRaven/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
