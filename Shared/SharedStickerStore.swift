import Foundation
import UIKit

/// Shared data layer for App ↔ Widget communication via App Group container.
enum SharedStickerStore {
    static let appGroupID = "group.com.demo.MilkTeaSticker"
    static let entriesFileName = "widgetStickerEntries.json"

    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static var sharedStickersDirectory: URL? {
        guard let container = sharedContainerURL else { return nil }
        return container.appendingPathComponent("SharedStickers", isDirectory: true)
    }

    // MARK: - Write (called by main app)

    static func writeEntries(_ entries: [SharedStickerEntry]) {
        guard let container = sharedContainerURL else { return }
        let url = container.appendingPathComponent(entriesFileName)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func writeStickerImage(id: String, image: UIImage) {
        guard let dir = sharedStickersDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).png")
        if let data = image.pngData() {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Writes already-encoded PNG data (avoids a decode/re-encode round trip).
    static func writeStickerImageData(id: String, data: Data) {
        guard let dir = sharedStickersDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).png")
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Read (called by widget)

    static func readEntries() -> [SharedStickerEntry] {
        guard let container = sharedContainerURL,
              let data = try? Data(contentsOf: container.appendingPathComponent(entriesFileName)),
              let entries = try? JSONDecoder().decode([SharedStickerEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func stickerImageURL(id: String) -> URL? {
        guard let dir = sharedStickersDirectory else { return nil }
        let url = dir.appendingPathComponent("\(id).png")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func readStickerImage(id: String) -> UIImage? {
        guard let url = stickerImageURL(id: id) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Diary Snapshots

    private static let diaryFileName = "widgetDiarySnapshots.json"

    static func writeDiarySnapshots(_ snapshots: [SharedDiarySnapshot]) {
        guard let container = sharedContainerURL else { return }
        let url = container.appendingPathComponent(diaryFileName)
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func readDiarySnapshots() -> [SharedDiarySnapshot] {
        guard let container = sharedContainerURL,
              let data = try? Data(contentsOf: container.appendingPathComponent(diaryFileName)),
              let snapshots = try? JSONDecoder().decode([SharedDiarySnapshot].self, from: data) else {
            return []
        }
        return snapshots
    }

    // MARK: - Cleanup

    static func removeOrphanedImages(validIDs: Set<String>) {
        guard let dir = sharedStickersDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let id = file.deletingPathExtension().lastPathComponent
            if !validIDs.contains(id) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

/// Lightweight metadata shared between app and widget.
struct SharedStickerEntry: Codable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let timestamp: TimeInterval

    var date: Date {
        Date(timeIntervalSince1970: timestamp)
    }
}

/// Diary snapshot shared with widget.
struct SharedDiarySnapshot: Codable {
    let dateTimestamp: TimeInterval
    let textPreview: String
    let stickerID: String?

    var date: Date {
        Date(timeIntervalSince1970: dateTimestamp)
    }
}
