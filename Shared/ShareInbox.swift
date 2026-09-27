import Foundation

/// Images handed over by the share extension, waiting in the App Group
/// container until the app turns them into stickers.
///
/// The extension writes here and then tries to open the app. If that jump
/// fails, the images simply wait until the next time the app comes forward.
enum ShareInbox {
    /// Opened by the share extension; the app then drains the inbox.
    static let openURL = URL(string: "stickerdiary://share")!

    private static var directory: URL? {
        SharedStickerStore.sharedContainerURL?.appendingPathComponent("ShareInbox", isDirectory: true)
    }

    /// Saves one encoded image. Names sort by time, so stickers keep the share order.
    @discardableResult
    static func add(_ data: Data, index: Int) -> Bool {
        guard let directory else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let name = String(format: "%013d-%02d-%@.jpg", stamp, index, UUID().uuidString)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static var isEmpty: Bool {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return true }
        return !names.contains { $0.hasSuffix(".jpg") }
    }

    /// Reads and removes everything waiting, oldest first. Removing on read
    /// means a URL open and a foreground check can't import the same image twice.
    static func takeAll() -> [Data] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              ) else { return [] }
        return urls
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                defer { try? FileManager.default.removeItem(at: url) }
                return try? Data(contentsOf: url)
            }
    }
}
