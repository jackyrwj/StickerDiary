import SwiftUI

@main
struct PersonalStickerApp: App {
    @State private var library = StickerLibrary()
    private let generator = StickerGenerationServiceFactory.makeDefault()

    var body: some Scene {
        WindowGroup {
            AppShellView(library: library, generator: generator)
                .tint(AppTheme.accent)
        }
    }
}
