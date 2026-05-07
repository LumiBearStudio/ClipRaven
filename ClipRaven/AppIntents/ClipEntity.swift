import AppIntents
import Foundation
import ClipRavenSync

/// App Intents wrapper around `Clip`. This is what Shortcuts.app, Spotlight, and Siri
/// actually see when an intent returns or consumes a clip value.
///
/// Keep this intentionally narrow — only fields worth showing in the Shortcuts UI or
/// chaining between actions. The full `Clip` stays internal.
struct ClipEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "ClipRaven Clip"
    static var defaultQuery = ClipQuery()

    /// AppIntents requires `ID` to be `EntityIdentifierConvertible` — String qualifies,
    /// Int64 does not. We stringify the DB row id and convert back at lookup time.
    let id: String

    /// Convenience: the underlying Int64 rowId for repository lookups.
    var clipId: Int64 { Int64(id) ?? 0 }

    @Property(title: "Preview")
    var preview: String

    @Property(title: "Content Type")
    var contentType: String

    @Property(title: "Source App")
    var sourceApp: String?

    @Property(title: "Copy Count")
    var copyCount: Int

    @Property(title: "Created")
    var createdAt: Date

    /// Full text when available — lets users chain the whole clip into
    /// actions like "Create Note", "Send Email", etc. without needing Preview truncation.
    @Property(title: "Full Text")
    var fullText: String

    var displayRepresentation: DisplayRepresentation {
        let subtitle: LocalizedStringResource = {
            if let app = sourceApp, !app.isEmpty {
                return "\(app) · \(contentType)"
            }
            return "\(contentType)"
        }()
        return DisplayRepresentation(title: "\(preview)", subtitle: subtitle)
    }

    init(from clip: Clip) {
        self.id = String(clip.id ?? 0)
        let raw = clip.contentText ?? "(image/file)"
        self.preview = String(raw.prefix(100))
        self.fullText = raw
        self.contentType = clip.contentType.displayName
        self.sourceApp = clip.sourceAppName
        self.copyCount = clip.copyCount
        self.createdAt = clip.createdAt
    }
}
