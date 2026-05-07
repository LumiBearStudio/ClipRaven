import Foundation
import CommonCrypto
import ClipRavenSync

actor DuplicateDetector {
    private let clipRepository = ClipRepository()

    /// Check for duplicates and return existing clip ID if found
    /// Returns the existing clip if duplicate is detected (caller should increment count)
    func checkDuplicate(
        contentType: ContentType,
        text: String? = nil,
        imageData: Data? = nil
    ) -> Clip? {
        switch contentType {
        case .text, .code:
            return checkTextDuplicate(text)

        case .url:
            return checkURLDuplicate(text)

        case .color:
            return checkColorDuplicate(text)

        case .image:
            return checkImageDuplicate(imageData)

        case .file:
            // 파일 경로 기반 중복 체크 (경로 텍스트 해싱)
            return checkTextDuplicate(text)
        }
    }

    // MARK: - Text/Code

    private func checkTextDuplicate(_ text: String?) -> Clip? {
        guard let text, !text.isEmpty else { return nil }
        let normalized = TextNormalizer.normalize(text)
        let hash = XXHash64Wrapper.hash(normalized)
        return try? clipRepository.fetchByHash(hash)
    }

    // MARK: - URL

    private func checkURLDuplicate(_ urlString: String?) -> Clip? {
        guard let urlString, !urlString.isEmpty else { return nil }
        let normalized = URLNormalizer.normalize(urlString)
        let hash = XXHash64Wrapper.hash(normalized)
        return try? clipRepository.fetchByHash(hash)
    }

    // MARK: - Color

    private func checkColorDuplicate(_ colorText: String?) -> Clip? {
        guard let colorText, let hex8 = ColorParser.normalizeToHex8(colorText) else { return nil }
        let hash = XXHash64Wrapper.hash(hex8)
        return try? clipRepository.fetchByHash(hash)
    }

    // MARK: - Image

    private func checkImageDuplicate(_ imageData: Data?) -> Clip? {
        guard let imageData else { return nil }

        // 1. Exact match via SHA-256
        let sha256 = SHA256Hash.compute(imageData)
        if let existing = try? clipRepository.fetchByImageHash(sha256) {
            return existing
        }

        // 2. Fuzzy match via dHash
        // Note: This requires scanning recent images - optimize in production
        // For now, rely on exact SHA-256 match

        return nil
    }

    // MARK: - Hash Generation

    func generateHash(contentType: ContentType, text: String?) -> String? {
        guard let text else { return nil }

        switch contentType {
        case .text, .code:
            let normalized = TextNormalizer.normalize(text)
            return XXHash64Wrapper.hash(normalized)
        case .url:
            let normalized = URLNormalizer.normalize(text)
            return XXHash64Wrapper.hash(normalized)
        case .color:
            if let hex8 = ColorParser.normalizeToHex8(text) {
                return XXHash64Wrapper.hash(hex8)
            }
            return XXHash64Wrapper.hash(text)
        case .image:
            return nil  // Images use imageHash field
        case .file:
            // 파일 경로를 정규화하여 해시 — 동일 경로 중복 감지
            let normalized = TextNormalizer.normalize(text)
            return XXHash64Wrapper.hash(normalized)
        }
    }

    func generateImageHash(_ imageData: Data) -> String {
        SHA256Hash.compute(imageData)
    }

    func generateDHash(_ imageData: Data) -> Int64? {
        DHash.compute(from: imageData)
    }
}

// MARK: - SHA-256 Helper (CommonCrypto)

enum SHA256Hash {
    static func compute(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
