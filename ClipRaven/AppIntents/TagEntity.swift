import AppIntents
import Foundation
import ClipRavenSync

/// App Intents wrapper around `Tag`. Used as the parameter type for
/// `GetClipsByTagIntent` — Shortcuts renders a dropdown populated by `TagQuery`.
struct TagEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "ClipRaven Tag"
    static var defaultQuery = TagQuery()

    /// String id for App Intents compatibility — Int64 is not `EntityIdentifierConvertible`.
    let id: String

    var tagId: Int64 { Int64(id) ?? 0 }

    @Property(title: "Name")
    var name: String

    @Property(title: "Color")
    var colorHex: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(from tag: Tag) {
        self.id = String(tag.id ?? 0)
        self.name = tag.name
        self.colorHex = tag.colorHex
    }
}
