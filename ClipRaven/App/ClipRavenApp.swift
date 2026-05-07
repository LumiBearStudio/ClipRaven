import SwiftUI

@main
struct ClipRavenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window is managed manually via StatusItemController
        // (SwiftUI Settings scene doesn't work reliably for accessory-mode apps)
        WindowGroup(id: "noop") {
            EmptyView()
        }
        .defaultSize(width: 0, height: 0)
        .commandsRemoved()
    }
}
