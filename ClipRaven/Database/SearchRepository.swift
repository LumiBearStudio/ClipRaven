import Foundation
import GRDB
import ClipRavenSync

struct SearchRepository {
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool = AppDatabase.shared.dbPool) {
        self.dbPool = dbPool
    }

    // MARK: - FTS5 Search (with LIKE substring fallback)

    func search(
        query: String,
        contentType: ContentType? = nil,
        limit: Int = 50
    ) throws -> [Clip] {
        guard !query.isEmpty else { return [] }

        // 1) Try FTS5 first (fast, prefix-based)
        let ftsResults = try ftsSearch(query: query, contentType: contentType, limit: limit)

        // 2) If few results, fallback to LIKE substring search
        if ftsResults.count < 5 {
            let likeResults = try substringSearch(query: query, contentType: contentType, limit: limit)

            // Merge: FTS results first, then LIKE results (deduped)
            let existingIds = Set(ftsResults.compactMap(\.id))
            let additional = likeResults.filter { clip in
                guard let id = clip.id else { return false }
                return !existingIds.contains(id)
            }
            return ftsResults + additional
        }

        return ftsResults
    }

    // MARK: - FTS5 Search (prefix-based)

    private func ftsSearch(
        query: String,
        contentType: ContentType? = nil,
        limit: Int = 50
    ) throws -> [Clip] {
        let ftsQuery = buildFTSQuery(query)

        return try dbPool.read { db in
            var sql = """
                SELECT clips.*,
                       bm25(clips_fts, 10.0, 5.0, 3.0, 2.0, 8.0) AS rank
                FROM clips
                JOIN clips_fts ON clips_fts.rowid = clips.id
                WHERE clips_fts MATCH ?
                  AND clips.isDeleted = 0
            """
            var arguments: [DatabaseValueConvertible] = [ftsQuery]

            if let contentType {
                sql += " AND clips.contentType = ?"
                arguments.append(contentType.rawValue)
            }

            sql += " ORDER BY clips.isPinned DESC, rank ASC LIMIT ?"
            arguments.append(limit)

            return try Clip.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    // MARK: - LIKE Substring Search (fallback for partial Korean matches)

    private func substringSearch(
        query: String,
        contentType: ContentType? = nil,
        limit: Int = 50
    ) throws -> [Clip] {
        let pattern = "%\(query)%"

        return try dbPool.read { db in
            var sql = """
                SELECT * FROM clips
                WHERE isDeleted = 0
                  AND (contentText LIKE ? OR sourceAppName LIKE ? OR tagsText LIKE ? OR ocrText LIKE ?)
            """
            var arguments: [DatabaseValueConvertible] = [pattern, pattern, pattern, pattern]

            if let contentType {
                sql += " AND contentType = ?"
                arguments.append(contentType.rawValue)
            }

            sql += " ORDER BY isPinned DESC, lastCopiedAt DESC LIMIT ?"
            arguments.append(limit)

            return try Clip.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    // MARK: - Chosung Fallback Search (Korean consonant-only search)

    func searchChosung(
        query: String,
        limit: Int = 50
    ) throws -> [Clip] {
        guard !query.isEmpty else { return [] }

        return try dbPool.read { db in
            try Clip
                .filter(Column("isDeleted") == false)
                .filter(Column("contentChosung").like("%\(query)%"))
                .order(Column("isPinned").desc, Column("lastCopiedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Snippet for highlight

    func searchWithSnippet(
        query: String,
        limit: Int = 50
    ) throws -> [(clip: Clip, snippet: String)] {
        guard !query.isEmpty else { return [] }

        let ftsQuery = buildFTSQuery(query)

        return try dbPool.read { db in
            let sql = """
                SELECT clips.*,
                       snippet(clips_fts, 0, '<mark>', '</mark>', '…', 32) AS snippet
                FROM clips
                JOIN clips_fts ON clips_fts.rowid = clips.id
                WHERE clips_fts MATCH ?
                  AND clips.isDeleted = 0
                ORDER BY clips.isPinned DESC,
                         bm25(clips_fts, 10.0, 5.0, 3.0, 2.0, 8.0) ASC
                LIMIT ?
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [ftsQuery, limit])
            return try rows.map { row in
                let clip = try Clip(row: row)
                let snippet = row["snippet"] as String? ?? ""
                return (clip: clip, snippet: snippet)
            }
        }
    }

    // MARK: - Similar Image Search (dHash Hamming distance)

    /// dHash Hamming distance로 유사 이미지 검색
    func findSimilarImages(dHash: Int64, threshold: Int = 10, excludeId: Int64? = nil) throws -> [Clip] {
        try dbPool.read { db in
            var sql = """
                SELECT * FROM clips
                WHERE contentType = 'image'
                  AND isDeleted = 0
                  AND imageDhash IS NOT NULL
            """
            if let excludeId {
                sql += " AND id != \(excludeId)"
            }

            let rows = try Clip.fetchAll(db, sql: sql)

            // Hamming distance = popcount(a XOR b)
            return rows.filter { clip in
                guard let clipHash = clip.imageDhash else { return false }
                let xor = UInt64(bitPattern: clipHash ^ dHash)
                return xor.nonzeroBitCount <= threshold
            }
        }
    }

    // MARK: - FTS Maintenance

    func optimizeFTS() throws {
        try dbPool.write { db in
            try db.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('optimize')")
        }
    }

    func rebuildFTS() throws {
        try dbPool.write { db in
            try db.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('rebuild')")
        }
    }

    // MARK: - Private

    private func buildFTSQuery(_ input: String) -> String {
        // Tokenize and add prefix matching for the last term
        let terms = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") } // Escape double quotes

        guard !terms.isEmpty else { return input }

        // All terms except last are exact, last gets prefix match
        var parts = terms.dropLast().map { "\"\($0)\"" }
        if let last = terms.last {
            parts.append("\"\(last)\"*")
        }

        return parts.joined(separator: " ")
    }
}
