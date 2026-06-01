import SwiftUI
import UIKit

@main
struct DailyStickerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Pre-loads the iOS keyboard infrastructure on launch so the first
/// becomeFirstResponder call in the diary page is instant.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        KeyboardWarmup.shared.warmUp()
        return true
    }
}

private final class KeyboardWarmup {
    static let shared = KeyboardWarmup()

    func warmUp() {
        DispatchQueue.main.async { [weak self] in
            self?.performWarmUp()
        }
    }

    private func performWarmUp() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }

        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        window.alpha = 0.01
        window.isUserInteractionEnabled = false

        let textField = UITextField()
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        window.addSubview(textField)
        window.makeKeyAndVisible()

        textField.becomeFirstResponder()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            textField.resignFirstResponder()
            textField.removeFromSuperview()
            window.isHidden = true
        }
    }
}
