import AppKit

/// Marker to identify clipboard writes originating from ClipRaven.
/// When the monitor detects this type, it skips processing to avoid
/// recording its own paste operations as new clipboard entries.
enum ClipboardMarker {
    static let selfType = NSPasteboard.PasteboardType("com.lumibear.clipraven.source")
}
