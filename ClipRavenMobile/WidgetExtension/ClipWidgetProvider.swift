import WidgetKit
import GRDB
import ClipRavenSync

/// 위젯 타임라인 공급자.
///
/// App Group SQLite를 readonly로 열어 최근 클립을 읽는다.
/// 클립이 새로 추가될 때마다 메인 앱이 `WidgetCenter.shared.reloadAllTimelines()`를
/// 호출하므로, 여기서는 15분 간격 폴링만 예약하면 된다.
struct ClipWidgetProvider: TimelineProvider {

    // MARK: - Placeholder (스켈레톤 UI)

    func placeholder(in context: Context) -> ClipWidgetEntry {
        .placeholder
    }

    // MARK: - Snapshot (위젯 갤러리 미리보기)

    func getSnapshot(in context: Context, completion: @escaping (ClipWidgetEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        let entry = makeEntry()
        completion(entry)
    }

    // MARK: - Timeline

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClipWidgetEntry>) -> Void) {
        let entry = makeEntry()
        // 15분 뒤 자동 갱신. 새 클립이 캡처되면 메인 앱에서 즉시 reload 요청함.
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }

    // MARK: - Data fetch

    private func makeEntry() -> ClipWidgetEntry {
        guard let dbPool = openDB() else {
            return .empty
        }
        do {
            let snapshots = try dbPool.read { db -> [ClipSnapshot] in
                // 키보드 익스텐션과 동일 필터 — 텍스트 클립 OR thumbnail 있는
                // 이미지 클립. Phase B 강화: 시간/썸네일/핀 함께 fetch.
                //
                // LIMIT 8 — Large 위젯이 최대 6-7개 표시 + 약간의 여유.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, contentType, contentText, nickname,
                           lastCopiedAt, thumbnail, isPinned
                    FROM clips
                    WHERE isDeleted = 0
                      AND (contentText IS NOT NULL OR thumbnail IS NOT NULL)
                    ORDER BY isPinned DESC, lastCopiedAt DESC
                    LIMIT 8
                    """)
                return rows.compactMap { row -> ClipSnapshot? in
                    guard let id: Int64 = row["id"],
                          let contentType: String = row["contentType"],
                          let lastCopiedAt: Date = row["lastCopiedAt"]
                    else { return nil }
                    let nickname: String? = row["nickname"]
                    let contentText: String? = row["contentText"]
                    let thumbnail: Data? = row["thumbnail"]
                    let isPinned: Bool = row["isPinned"] ?? false

                    let useNickname = (nickname?.isEmpty == false)
                    let displayText = nickname?.nilIfEmpty
                        ?? contentText?.nilIfEmpty
                        ?? "[\(contentType)]"
                    return ClipSnapshot(
                        id: id,
                        text: displayText,
                        contentType: contentType,
                        lastCopiedAt: lastCopiedAt,
                        thumbnailData: thumbnail,
                        isPinned: isPinned,
                        hasNickname: useNickname
                    )
                }
            }
            return ClipWidgetEntry(date: Date(), clips: snapshots)
        } catch {
            return .empty
        }
    }

    private func openDB() -> DatabasePool? {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.lumibear.ClipRavenMobile"
        ) else { return nil }

        let dbURL = groupURL
            .appendingPathComponent("ClipRaven", isDirectory: true)
            .appendingPathComponent("clipraven.sqlite")

        var config = Configuration()
        config.readonly = true
        // 메인 앱과 lock 충돌 시 5초 대기 — 키보드와 동일한 안전망.
        config.busyMode = .timeout(5.0)
        return try? DatabasePool(path: dbURL.path, configuration: config)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
