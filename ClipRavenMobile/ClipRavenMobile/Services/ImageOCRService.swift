import Vision
import UIKit
import os.log
import GRDB
import ClipRavenSync

/// Vision framework OCR service.
/// Called after an image clip is inserted to extract searchable text.
/// Stores the result in the `ocrText` column and triggers an FTS update.
enum ImageOCRService {

    private static let log = Logger(subsystem: "com.lumibear.ClipRavenMobile", category: "OCR")

    /// Runs OCR on imageData (PNG/JPEG). Returns nil if no text found or
    /// if Vision fails. Recognition runs at `.accurate` level.
    static func extractText(from imageData: Data) async -> String? {
        guard let cgImage = UIImage(data: imageData)?.cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, error in
                guard error == nil,
                      let observations = req.results as? [VNRecognizedTextObservation]
                else {
                    continuation.resume(returning: nil)
                    return
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n")
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Support Korean + English — most common in ClipRaven use cases.
            request.recognitionLanguages = ["ko-KR", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                log.error("VNImageRequestHandler failed: \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Runs OCR and persists the result to the clips row identified by `clipId`.
    /// Runs in a background task — does not block the calling context.
    static func runAndStore(clipId: Int64, imageData: Data, dbPool: DatabasePool) async {
        log.debug("OCR start clipId=\(clipId, privacy: .public)")
        guard let text = await extractText(from: imageData) else {
            log.debug("OCR no text clipId=\(clipId, privacy: .public)")
            return
        }
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE clips SET ocrText = ?, updatedAt = ? WHERE id = ?",
                    arguments: [text, Date(), clipId]
                )
            }
            log.info("OCR stored \(text.count, privacy: .public) chars clipId=\(clipId, privacy: .public)")
        } catch {
            log.error("OCR store failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Scans all image clips that lack ocrText and runs OCR in the background.
    /// Call once at app launch after DB is ready.
    static func backfillMissingOCR(dbPool: DatabasePool) {
        Task.detached(priority: .utility) {
            do {
                let clips = try await dbPool.read { db in
                    try Clip
                        .filter(Column("contentType") == ContentType.image.rawValue)
                        .filter(Column("isDeleted") == false)
                        .filter(Column("ocrText") == nil)
                        .filter(Column("thumbnail") != nil)
                        .limit(50)
                        .fetchAll(db)
                }
                for clip in clips {
                    guard let id = clip.id, let data = clip.thumbnail else { continue }
                    await runAndStore(clipId: id, imageData: data, dbPool: dbPool)
                    // Throttle — don't saturate CPU on launch.
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms between clips
                }
            } catch {
                log.error("backfill scan failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
