import Foundation
import GRDB
import os.log

/// 이미지 원본 binary 의 TTL 기반 정리.
///
/// 정책:
/// - **30일 이상** 된 `.image` 클립의 imagePath 파일 → 삭제 + DB의 imagePath 컬럼 nil
/// - **핀 고정**(`isPinned = 1`) 클립은 영구 보관 (사용자가 명시적으로 보존)
/// - **30일 미만**은 손대지 않음
/// - 메타데이터(thumbnail, contentHash, ocrText 등)는 **항상 유지** —
///   히스토리 가치는 보존, binary만 휘발성으로 다룬다
///
/// 호출 시점:
/// - Mac: 기존 cleanup cron 에서 매일 1회
/// - iOS: 앱 launch 시 1회 (BackgroundTasks 안 쓰는 이유는 iOS 백그라운드
///   실행이 불안정해서 "다음 launch에 정리"가 더 결정론적이라서)
public enum ImageBinaryCleanup {

    private static let log = Logger(subsystem: "com.lumibear.ClipRaven", category: "ImageBinaryCleanup")

    public struct Result {
        public let scanned: Int
        public let removed: Int
        public let bytesFreed: Int64
    }

    /// 30일 cutoff 로 정리 수행. 호출 측이 dbPool 과 함께 호출.
    @discardableResult
    public static func run(
        dbPool: DatabaseWriter,
        retentionDays: Int = 30,
        store: ImageOriginalStore? = ImageOriginalStoreRegistry.current
    ) async throws -> Result {
        guard let store else {
            log.error("ImageOriginalStore not registered — skipping cleanup")
            return Result(scanned: 0, removed: 0, bytesFreed: 0)
        }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)

        // Step 1: 만료 + non-pinned 클립의 imagePath 목록 조회
        let candidates: [(id: Int64, path: String)] = try await dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, imagePath FROM clips
                WHERE contentType = 'image'
                  AND imagePath IS NOT NULL
                  AND isPinned = 0
                  AND createdAt < ?
                """, arguments: [cutoff])
            .compactMap { row -> (Int64, String)? in
                guard let id: Int64 = row["id"],
                      let path: String = row["imagePath"]
                else { return nil }
                return (id, path)
            }
        }

        var removedCount = 0
        var bytesFreed: Int64 = 0
        var idsToNullify: [Int64] = []

        // Step 2: 파일 삭제 + 사이즈 카운트
        for (id, relPath) in candidates {
            let url = store.fullURL(for: relPath)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = (attrs[.size] as? NSNumber)?.intValue
            {
                bytesFreed += Int64(size)
            }
            try? FileManager.default.removeItem(at: url)
            idsToNullify.append(id)
            removedCount += 1
        }

        // Step 3: DB 의 imagePath 컬럼을 nil 로 — thumbnail/메타는 유지
        if !idsToNullify.isEmpty {
            try await dbPool.write { db in
                let placeholders = idsToNullify.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "UPDATE clips SET imagePath = NULL WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(idsToNullify)
                )
            }
        }

        let result = Result(scanned: candidates.count, removed: removedCount, bytesFreed: bytesFreed)
        log.info("cleanup: scanned=\(result.scanned, privacy: .public) removed=\(result.removed, privacy: .public) freed=\(result.bytesFreed, privacy: .public)B")
        return result
    }
}
