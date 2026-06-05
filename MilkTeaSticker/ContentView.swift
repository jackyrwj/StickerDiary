import SwiftUI

enum AppOnboarding {
    static let hasSeenKey = "hasSeenStickerDiaryOnboardingV2"
}

struct ContentView: View {
    @AppStorage(AppOnboarding.hasSeenKey) private var hasSeenOnboarding = false

    var body: some View {
        if hasSeenOnboarding {
            DailyStickerView {
                hasSeenOnboarding = false
            }
        } else {
            StickerDiaryOnboardingView {
                hasSeenOnboarding = true
            }
        }
    }
}

#Preview {
    ContentView()
}
