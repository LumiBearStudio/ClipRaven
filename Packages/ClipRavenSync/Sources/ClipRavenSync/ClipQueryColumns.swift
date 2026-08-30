import Foundation
import GRDB

/// 목록용 `clips` SELECT 컬럼 목록 생성기.
///
/// ## 왜 필요한가
/// 키보드 익스텐션(50행)과 위젯(8행)은 카드에 200자·120자만 그리면서 쿼리는
/// **본문 전체**를 가져오고 있었다. 수 MB 짜리 로그·JSON 을 복사해 둔 사용자면
/// 목록 로딩만으로 익스텐션 메모리 한도(키보드 ~60MB, 위젯 ~30MB)를 넘겨
/// 강제 종료된다 (감사 X2). `contentText` 를 SQL 단계에서 잘라 온다.
///
/// ## 왜 컬럼을 손으로 안 쓰나
/// `clips` 는 46개 컬럼이고 마이그레이션마다 늘어난다. 하드코딩하면 새 컬럼이
/// 조용히 빠져 `Clip` 디코딩이 깨지거나 값이 nil 로 유실된다. 스키마
/// (`pragma_table_info`) 에서 직접 만들면 그런 실수가 구조적으로 불가능하다.
///
/// ## 주의
/// 잘린 본문은 **표시 전용**이다. 붙여넣기·복사처럼 전체 내용이 필요한 경로는
/// 반드시 id 로 원본을 다시 읽어야 한다 (키보드 `fullContentText`,
/// 위젯 `CopyClipIntent.fetchPayload`).
public enum ClipQueryColumns {

    /// 목록에 올릴 본문 길이 상한 (문자).
    public static let defaultPreviewLimit = 300

    /// `clips` 의 전체 컬럼 목록. `contentText` 만 `substr(...) AS contentText`
    /// 로 감싼다. 별칭을 유지하므로 `Clip` 디코딩은 그대로 동작한다.
    ///
    /// - Parameters:
    ///   - db: 스키마를 읽을 연결.
    ///   - previewLimit: 본문 최대 문자 수.
    ///   - prefix: 컬럼 앞에 붙일 테이블 별칭 (JOIN 쿼리에서 모호성 제거용).
    /// - Returns: `"clips.id, clips.contentType, substr(clips.contentText, 1, 300) AS contentText, ..."`
    public static func list(
        _ db: Database,
        previewLimit: Int = defaultPreviewLimit,
        prefix: String = "clips"
    ) throws -> String {
        let names = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('clips')")
        return names.map { name in
            name == "contentText"
                ? "substr(\(prefix).contentText, 1, \(previewLimit)) AS contentText"
                : "\(prefix).\(name)"
        }
        .joined(separator: ", ")
    }
}
