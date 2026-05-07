import Foundation
import UIKit
import CryptoKit

/// iOS-side 이미지 클립 처리. UIPasteboard에서 받은 이미지를:
/// 1. 썸네일 생성 (~200x200 JPEG, 품질 0.7)
/// 2. SHA-256 해시 (dedup 키)
/// 3. dHash (perceptual hash, 향후 유사 이미지 dedup용 — 지금은 skip)
///
/// 메인 앱은 원본 이미지 풀 데이터는 저장하지 않고 썸네일만 보관.
/// 풀 사이즈 캡처/저장은 Phase C에서 이미지 sync 본격 도입 시.
enum ImageThumbnailMaker {

    /// 썸네일 최대 변(긴 쪽). Paste 표준이 ~256, ClipRaven Mac은 150.
    /// CKRecord field 한도 안에서 안전하게 가도록 200.
    private static let thumbnailMaxDimension: CGFloat = 200

    /// JPEG 압축 품질. 0.7이면 시각 손실 없으면서 파일 크기 ~10–30KB.
    private static let jpegQuality: CGFloat = 0.7

    /// 캡처한 이미지에서 (thumbnail data, image hash) 산출.
    /// 실패 시 nil.
    static func process(_ image: UIImage) -> (thumbnail: Data, hash: String)? {
        guard let thumbnail = makeThumbnail(image),
              let jpegData = thumbnail.jpegData(compressionQuality: jpegQuality)
        else { return nil }

        // 원본 이미지의 PNG 바이트 → SHA-256. 이미지 자체의 fingerprint
        // (썸네일 hash 아니라) — Mac이 같은 이미지를 캡처한 경우 dedup.
        let sourceData: Data
        if let png = image.pngData() {
            sourceData = png
        } else if let jpg = image.jpegData(compressionQuality: 1.0) {
            sourceData = jpg
        } else {
            return nil
        }

        let digest = SHA256.hash(data: sourceData)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (jpegData, hex)
    }

    /// 입력 이미지를 thumbnail 사이즈로 다운샘플. aspect ratio 유지.
    private static func makeThumbnail(_ image: UIImage) -> UIImage? {
        let originalSize = image.size
        let longSide = max(originalSize.width, originalSize.height)
        guard longSide > 0 else { return nil }

        // 원본이 이미 작으면 스케일 안 내림.
        if longSide <= thumbnailMaxDimension {
            return image
        }

        let scale = thumbnailMaxDimension / longSide
        let newSize = CGSize(
            width: originalSize.width * scale,
            height: originalSize.height * scale
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // pixel-exact, no @2x retina inflation
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
