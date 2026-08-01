import SwiftUI

@main
struct PersonalStickerApp: App {
    @State private var library = StickerLibrary()

    var body: some Scene {
        WindowGroup {
            AppShellView(library: library)
                .tint(AppTheme.accent)
        }
    }
}
