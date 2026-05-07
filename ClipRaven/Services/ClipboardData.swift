import Foundation

/// Data captured from NSPasteboard on the main thread.
/// Passed to ClipProcessor for thread-safe background processing.
struct ClipboardData: Sendable {
    let text: String?
    let imageData: Data?
    let fileURLs: [URL]?
}
