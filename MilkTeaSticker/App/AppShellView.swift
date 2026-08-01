import SwiftUI

enum AppTab: Hashable {
    case create
    case library
}

struct AppShellView: View {
    let library: StickerLibrary
    @State private var selectedTab: AppTab = .create

    var body: some View {
        TabView(selection: $selectedTab) {
            CreateFlowView(library: library) {
                selectedTab = .library
            }
            .tabItem {
                Label("制作", systemImage: "wand.and.stars")
            }
            .tag(AppTab.create)

            StickerLibraryView(library: library)
                .tabItem {
                    Label("贴纸库", systemImage: "face.smiling.inverse")
                }
                .badge(library.packs.isEmpty ? 0 : library.packs.count)
                .tag(AppTab.library)
        }
        .background(AppTheme.background)
    }
}

enum AppTheme {
    static let accent = Color(red: 0.49, green: 0.30, blue: 0.94)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let warm = Color(red: 1.00, green: 0.73, blue: 0.31)
}

#Preview {
    AppShellView(library: StickerLibrary.preview)
}
