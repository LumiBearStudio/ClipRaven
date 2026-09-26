import Foundation
import GRDB
import os.log

/// 어떤 클립도 참조하지 않는 이미지 원본 파일을 정리한다.
///
/// ## 원본 수명 정책 (v1 리뷰 M6)
/// **원본은 클립과 같은 수명이다.** 클립 행이 남아 있는 동안(소프트 삭제 후 회수
/// 전까지 포함) 원본도 남고, 행이 사라지면 원본은 고아가 되어 이 정리에서 지워진다.
///
/// 이전에는 30일이 지난 비고정 이미지의 원본을 지웠다(`ImageBinaryCleanup`).
/// 클립은 기본 90일 보관이라 31~90일 구간의 이미지는 카드로는 멀쩡히 보이는데
/// 붙여넣으면 150px 썸네일이 나왔고, 사용자에게 알리는 설정도 표시도 없었다.
/// 게다가 그것이 원본 파일을 지우는 유일한 코드였다 — 클립을 지워도 파일은 남아
/// 고아가 계속 쌓였다.
///
/// ## 안전장치
/// - 파일명이 UUID 형식(`<UUID>.<확장자>`)인 파일만 대상으로 한다. 앱이 만드는
///   원본은 모두 이 형식이다.
/// - 수정한 지 `gracePeriod`(기본 24시간)가 지나지 않은 파일은 건드리지 않는다.
///   막 저장됐지만 아직 행이 커밋되지 않은 캡처·공유·백업 가져오기를 보호한다.
/// - DB 의 `imagePath` 를 따라가서 지우지 않는다. 폴더 안의 파일만 본다 —
///   조작된 백업의 `../clipraven.sqlite` 같은 경로로 DB 를 지울 수 있던 경로를 닫는다.
/// - 심볼릭 링크는 링크만 지운다(`removeItem` 은 대상을 따라가지 않는다).
public enum ImageOrphanSweep {

    private static let log = Logger(subsystem: "com.lumibear.ClipRaven", category: "ImageOrphanSweep")

    public struct Result: Equatable {
        public let scanned: Int
        public let removed: Int
        public let bytesFreed: Int64
    }

    private static let uuidFileName = try! NSRegularExpression(
        pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\.[A-Za-z0-9]{1,5}$"
    )

    /// DB 에 저장된 `imagePath` 를 원본 폴더 안의 파일명으로만 해석한다.
    /// 경로 구분자나 상위 경로(`..`)가 섞여 있으면 마지막 구성요소만 남기고,
    /// 그래도 `.`·`..`·빈 문자열이면 존재하지 않는 이름을 돌려준다.
    public static func sanitizedFileName(_ relativePath: String) -> String {
        let name = (relativePath as NSString).lastPathComponent
        return (name.isEmpty || name == "." || name == "..") ? "invalid-image-path" : name
    }

    /// 고아 원본 파일을 지운다.
    ///
    /// - Parameters:
    ///   - imagesDirectory: 원본 폴더. 이 폴더 바로 아래의 파일만 본다.
    ///   - dbReader: 참조 여부를 확인할 DB.
    ///   - gracePeriod: 이보다 최근에 수정된 파일은 건드리지 않는다.
    @discardableResult
    public static func run(
        imagesDirectory: URL,
        dbReader: some DatabaseReader,
        gracePeriod: TimeInterval = 24 * 3600,
        now: Date = Date()
    ) async throws -> Result {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: imagesDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            return Result(scanned: 0, removed: 0, bytesFreed: 0)   // 폴더가 아직 없음
        }

        let cutoff = now.addingTimeInterval(-gracePeriod)
        let candidates = entries.filter { url in
            let name = url.lastPathComponent
            guard uuidFileName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true || values.isSymbolicLink == true,
                  let modified = values.contentModificationDate, modified < cutoff
            else { return false }
            return true
        }
        guard !candidates.isEmpty else { return Result(scanned: 0, removed: 0, bytesFreed: 0) }

        // 소프트 삭제된 행까지 포함한 모든 참조 — 회수 전까지는 원본도 남긴다.
        let referenced: Set<String> = try await dbReader.read { db in
            Set(try String.fetchAll(db, sql: "SELECT imagePath FROM clips WHERE imagePath IS NOT NULL")
                .map(sanitizedFileName))
        }

        var removed = 0
        var bytes: Int64 = 0
        for url in candidates where !referenced.contains(url.lastPathComponent) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            do {
                try fm.removeItem(at: url)
                removed += 1
                bytes += Int64(size)
            } catch {
                log.error("orphan remove failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let result = Result(scanned: candidates.count, removed: removed, bytesFreed: bytes)
        if removed > 0 {
            log.info("orphan sweep: scanned=\(result.scanned, privacy: .public) removed=\(result.removed, privacy: .public) freed=\(result.bytesFreed, privacy: .public)B")
        }
        return result
    }
}
