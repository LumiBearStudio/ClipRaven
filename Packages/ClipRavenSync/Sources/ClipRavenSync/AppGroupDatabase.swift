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

    /// 메인 앱 + Extension 이 공유하는 App Group ID.
    public static let appGroupID = "group.com.lumibear.ClipRaven"

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
