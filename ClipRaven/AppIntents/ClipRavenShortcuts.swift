import AppIntents
import ClipRavenSync

/// Registers ClipRaven's intents with the Shortcuts and Spotlight catalogs.
/// macOS auto-detects this provider at launch — no manual wiring needed.
struct ClipRavenShortcuts: AppShortcutsProvider {

    /// Limit the total number of appearances to stay below Apple's cap.
    /// Bump if we ever add more intents beyond what the OS allows.
    static var shortcutTileColor: ShortcutTileColor = .purple

    static var appShortcuts: [AppShortcut] {

        AppShortcut(
            intent: GetLatestClipIntent(),
            phrases: [
                "\(.applicationName) 최근 클립",
                "\(.applicationName) 마지막 클립",
                "Get latest \(.applicationName) clip",
                "Latest \(.applicationName) clip"
            ],
            shortTitle: "Latest Clip",
            systemImageName: "doc.on.clipboard"
        )

        AppShortcut(
            intent: SearchClipboardHistoryIntent(),
            phrases: [
                "\(.applicationName)에서 검색",
                "\(.applicationName) 클립 검색",
                "Search \(.applicationName)",
                "Search clipboard with \(.applicationName)"
            ],
            shortTitle: "Search Clips",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: GetClipsByTagIntent(),
            phrases: [
                "\(.applicationName) 태그 클립",
                "Clips with tag in \(.applicationName)",
                "Get \(.applicationName) clips by tag"
            ],
            shortTitle: "Clips by Tag",
            systemImageName: "tag"
        )

        AppShortcut(
            intent: AddClipIntent(),
            phrases: [
                "\(.applicationName)에 클립 추가",
                "Add clip to \(.applicationName)",
                "Save clip in \(.applicationName)"
            ],
            shortTitle: "Add Clip",
            systemImageName: "plus.circle"
        )

        AppShortcut(
            intent: PasteClipIntent(),
            phrases: [
                "\(.applicationName) 클립 붙여넣기",
                "Paste \(.applicationName) clip",
                "Paste clip from \(.applicationName)"
            ],
            shortTitle: "Paste Clip",
            systemImageName: "square.and.arrow.down.on.square"
        )
    }
}
