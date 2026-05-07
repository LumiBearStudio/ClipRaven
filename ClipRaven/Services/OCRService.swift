import Foundation
import Vision
import AppKit

actor OCRService {
    private let clipRepository = ClipRepository()

    /// Perform OCR on image data and update the clip's ocrText field
    func performOCR(on imageData: Data, clipId: Int64) async {
        guard let cgImage = createCGImage(from: imageData) else { return }

        do {
            let text = try await recognizeText(in: cgImage)
            guard !text.isEmpty else { return }

            // Calculate confidence average
            let confidence = try await recognizeConfidence(in: cgImage)

            // Skip low-confidence results
            guard confidence >= 0.3 else { return }

            // Update clip with OCR text
            if var clip = try? clipRepository.fetchOne(id: clipId) {
                clip.ocrText = text
                clip.ocrConfidence = confidence
                clip.contentChosung = ChosungConverter.extractChosung(from: text)
                try? clipRepository.update(clip)

                // Trigger AI categorization now that OCR text is available
                #if canImport(FoundationModels)
                if #available(macOS 26, *) {
                    Task.detached(priority: .utility) {
                        await AICategoryService.shared.categorize(clipId: clipId, text: text)
                    }
                }
                #endif
            }
        } catch {
            ClipRavenLog.ocr.error("performing OCR: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Text Recognition

    private func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                continuation.resume(returning: text)
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func recognizeConfidence(in image: CGImage) async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let confidences = observations.compactMap { $0.topCandidates(1).first?.confidence }

                guard !confidences.isEmpty else {
                    continuation.resume(returning: 0.0)
                    return
                }

                let average = Double(confidences.reduce(0, +)) / Double(confidences.count)
                continuation.resume(returning: average)
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Image Conversion

    private func createCGImage(from data: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }
}
