import AppIntents
import WidgetKit
import GRDB
import UIKit
import ClipRavenSync

/// iOS 17+ Interactive Widget — 위젯에서 직접 클립보드에 복사한다.
///
/// `AppIntent`를 통해 위젯 내 버튼 탭이 앱을 열지 않고도 클립보드 쓰기 가능.
/// Deployment target iOS 17.0이므로 @available 조건 없이 사용.
///
/// 클립 타입별 처리 (메인 앱 ClipboardWriter와 동일한 정책):
/// - `.image`: thumbnail Data → UIImage → `UIPasteboard.image` (진짜 이미지로)
/// - 그 외: `contentText`를 `UIPasteboard.string`으로
///   ※ `.file` 클립은 macOS Finder에서 복사된 파일 경로가 contentText에 들어
///   있어 path 텍스트가 그대로 paste됨. iOS에선 원본 파일을 못 가져옴.
struct CopyClipIntent: AppIntent {

    static var title: LocalizedStringResource = "클립 복사"
    static var description = IntentDescription("선택한 클립을 클립보드에 복사합니다.")

    /// 복사할 클립의 DB row id.
    @Parameter(title: "클립 ID")
    var clipId: Int

    init() {}

    init(clipId: Int64) {
        self.clipId = Int(clipId)
    }

    func perform() async throws -> some IntentResult {
        guard let payload = fetchPayload(for: Int64(clipId)) else {
            return .result()
        }
        // AppIntent는 메인 스레드 보장 불필요 — 직접 UIPasteboard 접근 가능.
        await MainActor.run {
            // ① 이미지 클립이고 thumbnail 디코딩 성공 → 이미지로 paste
            if payload.contentType == ContentType.image.rawValue,
               let data = payload.thumbnail,
               let image = UIImage(data: data) {
                UIPasteboard.general.image = image
                return
            }
            // ② 그 외 — contentText 텍스트 paste
            if let text = payload.contentText, !text.isEmpty {
                UIPasteboard.general.string = text
            }
        }
        return .result()
    }

    // MARK: - Private

    private struct ClipPayload {
        let contentType: String?
        let contentText: String?
        let thumbnail: Data?
    }

    private func fetchPayload(for id: Int64) -> ClipPayload? {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.lumibear.ClipRavenMobile"
        ) else { return nil }

        let dbURL = groupURL
            .appendingPathComponent("ClipRaven", isDirectory: true)
            .appendingPathComponent("clipraven.sqlite")

        var config = Configuration()
        config.readonly = true
        guard let db = try? DatabasePool(path: dbURL.path, configuration: config) else { return nil }

        return try? db.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT contentType, contentText, thumbnail FROM clips WHERE id = ?",
                arguments: [id]
            ).map {
                ClipPayload(
                    contentType: $0["contentType"],
                    contentText: $0["contentText"],
                    thumbnail: $0["thumbnail"]
                )
            }
        }
    }
}

/// 앱 딥링크 URL 빌더 — 위젯 탭 시 앱을 해당 클립 컨텍스트로 열기 위해 사용.
enum ClipWidgetURL {
    static func clipDetail(id: Int64) -> URL {
        URL(string: "clipraven://clip/\(id)") ?? URL(string: "clipraven://")!
    }

    static var openApp: URL {
        URL(string: "clipraven://")!
    }
}
