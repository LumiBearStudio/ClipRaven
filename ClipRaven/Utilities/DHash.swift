import AppKit
import Foundation

enum DHash {
    /// Compute difference hash (dHash) for an image.
    /// Returns a 64-bit integer fingerprint, or nil if the image cannot be decoded.
    /// Safe to call on any thread.
    static func compute(from imageData: Data) -> Int64? {
        // Create the CGImage directly from data — bypasses NSImage entirely, which
        // avoids all NSImage/AppKit thread-safety concerns and the
        // cgImage(forProposedRect:nil,...) nil-on-background-thread problem.
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return compute(from: cgImage)
    }

    static func compute(from image: NSImage) -> Int64? {
        // cgImage(forProposedRect:) with an explicit size works reliably for
        // bitmap-backed images. Passing nil can fail for TIFF/multi-rep images
        // on background threads; we work around that by converting to Data first.
        if let data = image.tiffRepresentation {
            return compute(from: data)
        }
        // Fallback: try cgImage directly (works for PNG-backed images).
        var rect = NSRect(origin: .zero, size: image.size)
        guard rect.size.width > 0, rect.size.height > 0,
              let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        else { return nil }
        return compute(from: cgImage)
    }

    // MARK: - Hamming Distance

    /// Calculate Hamming distance between two dHash values.
    /// Works correctly for negative Int64 values — XOR operates on the raw bit pattern.
    static func hammingDistance(_ hash1: Int64, _ hash2: Int64) -> Int {
        let xor = UInt64(bitPattern: hash1 ^ hash2)
        return xor.nonzeroBitCount
    }

    /// Returns true when two images are "similar" (Hamming distance ≤ threshold).
    /// Threshold 5: catches re-screenshots and lightly edited images; rejects unrelated images.
    static func isSimilar(_ hash1: Int64, _ hash2: Int64, threshold: Int = 5) -> Bool {
        hammingDistance(hash1, hash2) <= threshold
    }

    // MARK: - Core implementation

    private static func compute(from cgImage: CGImage) -> Int64? {
        // dHash grid: 9 wide × 8 tall. Each row compares 8 adjacent pixel pairs → 64 bits.
        let width = 9
        let height = 8

        guard let pixels = renderToPixels(cgImage: cgImage, width: width, height: height) else {
            return nil
        }

        var hash: Int64 = 0
        var bit = 0

        for y in 0..<height {
            for x in 0..<(width - 1) {
                let left  = luminance(pixels: pixels, x: x,     y: y, width: width)
                let right = luminance(pixels: pixels, x: x + 1, y: y, width: width)
                if left > right {
                    hash |= (Int64(1) << bit)
                }
                bit += 1
            }
        }

        return hash
    }

    // MARK: - Private: pure CoreGraphics pixel rendering

    /// Render a CGImage into a 9×8 RGBA pixel buffer using only CoreGraphics.
    ///
    /// Design choices:
    ///
    /// 1. We accept a CGImage (not NSImage) so no AppKit drawing APIs are needed —
    ///    this makes the entire path safe on background threads.
    ///
    /// 2. We pass a pre-allocated [UInt8] buffer as CGContext's `data` pointer so we
    ///    can read pixel values directly after drawing, without calling
    ///    NSBitmapImageRep.colorAt(). That API requires the rep to have been created
    ///    from a raw byte buffer (not from a CGImage wrapper), and it silently returns
    ///    nil otherwise.
    ///
    /// 3. We use CGColorSpace.sRGB instead of CGColorSpaceCreateDeviceRGB().
    ///    sRGB is the macOS display standard and is what NSImage/AppKit calibrates
    ///    colors against. DeviceRGB can produce subtly different component values for
    ///    wide-gamut images and is not guaranteed to round-trip correctly through
    ///    NSColor component accessors.
    ///
    /// 4. premultipliedLast (RGBA) is required by CGContext when alpha is present.
    ///    For dHash on photographic content, all pixels are fully opaque so
    ///    premultiplication has no effect on the luminance comparison.
    ///
    /// 5. CGContext coordinates have (0,0) at bottom-left. This flips the image
    ///    vertically relative to NSBitmapImageRep's top-left origin — but dHash only
    ///    requires *consistent* pixel ordering, not a specific orientation. Every call
    ///    on the same image produces the same hash.
    private static func renderToPixels(cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return pixels
    }

    /// BT.601 luma from a raw RGBA premultiplied pixel buffer.
    /// Integer math (×1000) avoids floating-point overhead for 72 pixel accesses.
    private static func luminance(pixels: [UInt8], x: Int, y: Int, width: Int) -> Int {
        let index = (y * width + x) * 4
        let r = Int(pixels[index])
        let g = Int(pixels[index + 1])
        let b = Int(pixels[index + 2])
        return 299 * r + 587 * g + 114 * b
    }
}
