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
                // 본문은 substr 로 잘라 온다 — 위젯이 실제로 그리는 건 120자인데
                // 전체를 가져오면 수 MB 텍스트 클립 하나로 위젯 메모리 한도
                // (~30MB, 엔트리가 아카이빙되므로 더 빨리 닿는다) 를 넘긴다
                // (감사 X2). 버튼 탭 시 CopyClipIntent 가 id 로 전체 본문을
                // 다시 읽으므로 복사되는 내용은 잘리지 않는다.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, contentType,
                           substr(contentText, 1, 300) AS contentText,
                           nickname, lastCopiedAt, thumbnail, isPinned
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
        AppGroupDatabase.makeReadOnlyPool()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
