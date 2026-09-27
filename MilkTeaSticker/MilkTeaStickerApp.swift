import SwiftUI

@main
struct DailyStickerApp: App {
    @StateObject private var subscriptionManager = SubscriptionManager.shared

    init() {
        LegacyPerks.recordOnFirstLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    StickerStore.shared.syncToWidget()
                }
                .environmentObject(subscriptionManager)
        }
    }
}
