import Foundation

enum AppConstants {
    static let appName = "ClipRaven"
    static let bundleIdentifier = "com.lumibear.clipraven"

    // Database
    static let databaseFileName = "clipraven.sqlite"

    // Clipboard
    static let clipboardPollingInterval: TimeInterval = 0.5

    // UI
    static let panelWidth: CGFloat = 780
    static let panelHeight: CGFloat = 340
    static let cardWidth: CGFloat = 240
    static let cardHeight: CGFloat = 190

    // Limits
    static let maxClipCount = 5000
    static let maxImageSizeBytes = 10 * 1024 * 1024 // 10MB
    static let thumbnailMaxDimension: CGFloat = 150
}
