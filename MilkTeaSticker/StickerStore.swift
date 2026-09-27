import Foundation
import UIKit
import WidgetKit

/// Persistence layer for stickers.
/// Stores sticker images as PNGs and metadata in UserDefaults.
final class StickerStore {
    static let shared = StickerStore()

    private let fileManager = FileManager.default
    private let imageCache = NSCache<NSString, UIImage>()
    private let stickerEntriesKey = "stickerEntries"
    private let stickerOrderKey = "stickerDateOrders"
    private let calendar = Calendar.current
    /// In-memory copy of the metadata list so hot paths don't re-decode
    /// UserDefaults JSON on every call. Guarded by `entriesLock` because
    /// widget sync and preloading read it from background queues.
    private var cachedEntries: [StickerEntry]?
    private var cachedOrders: [String: [String]]?
    private let entriesLock = NSLock()

    private var containerURL: URL? {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private var stickersDirectory: URL? {
        guard let container = containerURL else { return nil }
        let dir = container.appendingPathComponent("Stickers", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Save

    /// Save a sticker image and its metadata. Returns the saved entry ID.
    @discardableResult
    func saveSticker(image: UIImage, title: String, subtitle: String, date: Date = .now) -> String {
        let id = UUID().uuidString
        let timestamp = date.timeIntervalSince1970

        // Write image as PNG
        if let dir = stickersDirectory {
            let imageURL = dir.appendingPathComponent("\(id).png")
            if let data = image.resizedForStickerStorage(maxDimension: 720).pngData() {
                try? data.write(to: imageURL, options: .atomic)
            }
        }

        // Write metadata
        var entries = loadEntries()
        let entry = StickerEntry(id: id, title: title, subtitle: subtitle, timestamp: timestamp)
        entries.insert(entry, at: 0) // newest first

        // Keep at most 50 entries
        if entries.count > 50 {
            let removed = entries.suffix(from: 50)
            for old in removed {
                deleteStickerImage(id: old.id)
            }
            entries = Array(entries.prefix(50))
        }

        saveEntries(entries)
        syncToWidget()
        return id
    }

    // MARK: - Load

    func loadEntries() -> [StickerEntry] {
        entriesLock.lock()
        defer { entriesLock.unlock() }
        if let cachedEntries { return cachedEntries }
        let entries: [StickerEntry]
        if let data = UserDefaults.standard.data(forKey: stickerEntriesKey),
           let decoded = try? JSONDecoder().decode([StickerEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
        cachedEntries = entries
        return entries
    }

    /// Metadata for one day in the user-adjusted order, without touching image files.
    func orderedEntriesForDate(_ date: Date) -> [StickerEntry] {
        let entries = loadEntries().filter { calendar.isDate($0.date, inSameDayAs: date) }
        return applySavedOrder(to: entries, for: date)
    }

    /// Loads only the first sticker image for a day (used for calendar previews).
    func firstOrderedSticker(for date: Date) -> (entry: StickerEntry, image: UIImage)? {
        for entry in orderedEntriesForDate(date) {
            if let image = loadStickerImage(id: entry.id) {
                return (entry, image)
            }
        }
        return nil
    }

    func loadStickerImage(id: String) -> UIImage? {
        let key = id as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let dir = stickersDirectory else { return nil }
        let imageURL = dir.appendingPathComponent("\(id).png")
        guard let data = try? Data(contentsOf: imageURL),
              let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Returns the image only if it is already in memory (never touches disk).
    func cachedStickerImage(id: String) -> UIImage? {
        imageCache.object(forKey: id as NSString)
    }

    /// Finds the store ID of an in-memory sticker image loaded for `date`.
    /// Used when a diary paragraph has an image but no recorded ID.
    func stickerID(matching image: UIImage, on date: Date) -> String? {
        orderedEntriesForDate(date).first { cachedStickerImage(id: $0.id) === image }?.id
    }

    /// Load the most recent N sticker images
    func loadRecentStickers(count: Int = 4) -> [(entry: StickerEntry, image: UIImage)] {
        let entries = loadEntries().prefix(count)
        return entries.compactMap { entry in
            guard let image = loadStickerImage(id: entry.id) else { return nil }
            return (entry, image)
        }
    }

    /// Load stickers for a specific date
    func loadStickersForDate(_ date: Date) -> [(entry: StickerEntry, image: UIImage)] {
        let entries = loadEntries().filter { calendar.isDate($0.date, inSameDayAs: date) }
        return entries.compactMap { entry in
            guard let image = loadStickerImage(id: entry.id) else { return nil }
            return (entry, image)
        }
    }

    /// Load stickers for a specific date using the user-adjusted order.
    func loadOrderedStickersForDate(_ date: Date) -> [(entry: StickerEntry, image: UIImage)] {
        orderedEntriesForDate(date).compactMap { entry in
            guard let image = loadStickerImage(id: entry.id) else { return nil }
            return (entry, image)
        }
    }

    /// Persist the visual order for one date. Unknown/deleted IDs are ignored on read.
    func saveStickerOrder(ids: [String], for date: Date) {
        let validIDs = Set(loadEntries().filter { calendar.isDate($0.date, inSameDayAs: date) }.map(\.id))
        let orderedIDs = ids.filter { validIDs.contains($0) }
        var orders = loadStickerOrders()
        let key = orderKey(for: date)
        if orderedIDs.isEmpty {
            orders.removeValue(forKey: key)
        } else {
            orders[key] = orderedIDs
        }
        saveStickerOrders(orders)
    }

    /// Warm the image cache for a date's stickers on a background thread.
    func preloadStickers(for date: Date) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.loadStickersForDate(date)
        }
    }

    // MARK: - Delete

    func deleteSticker(id: String) {
        imageCache.removeObject(forKey: id as NSString)
        deleteStickerImage(id: id)
        var entries = loadEntries()
        entries.removeAll { $0.id == id }
        saveEntries(entries)
        removeStickerIDFromSavedOrders(id)
        syncToWidget()
    }

    // MARK: - Widget Sync

    /// Sync all sticker data to the App Group container for widget access.
    func syncToWidget() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let entries = self.loadEntries()
            let sharedEntries = entries.map {
                SharedStickerEntry(id: $0.id, title: $0.title, subtitle: $0.subtitle, timestamp: $0.timestamp)
            }
            SharedStickerStore.writeEntries(sharedEntries)

            let validIDs = Set(entries.map(\.id))
            for entry in entries where SharedStickerStore.stickerImageURL(id: entry.id) == nil {
                if let url = self.stickersDirectory?.appendingPathComponent("\(entry.id).png"),
                   let data = try? Data(contentsOf: url) {
                    SharedStickerStore.writeStickerImageData(id: entry.id, data: data)
                }
            }
            SharedStickerStore.removeOrphanedImages(validIDs: validIDs)

            DispatchQueue.main.async {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    /// Sync diary snapshots to the App Group container for diary widget.
    /// Called from the main view whenever diary records change.
    static func syncDiaryToWidget(records: [(date: Date, text: String, stickerID: String?)]) {
        DispatchQueue.global(qos: .utility).async {
            let calendar = Calendar.current
            let snapshots = records
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.date > $1.date }
                .prefix(20)
                .map { record in
                    // Take first ~150 chars as preview
                    let preview = String(record.text.prefix(200))
                    return SharedDiarySnapshot(
                        dateTimestamp: calendar.startOfDay(for: record.date).timeIntervalSince1970,
                        textPreview: preview,
                        stickerID: record.stickerID
                    )
                }
            SharedStickerStore.writeDiarySnapshots(Array(snapshots))
            DispatchQueue.main.async {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    // MARK: - Private

    private func saveEntries(_ entries: [StickerEntry]) {
        entriesLock.lock()
        cachedEntries = entries
        entriesLock.unlock()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: stickerEntriesKey)
    }

    private func applySavedOrder(to entries: [StickerEntry], for date: Date) -> [StickerEntry] {
        let fallback = chronologicalEntries(entries)
        guard let savedIDs = loadStickerOrders()[orderKey(for: date)], !savedIDs.isEmpty else {
            return fallback
        }

        let byID = Dictionary(fallback.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [StickerEntry] = []
        var usedIDs = Set<String>()

        for id in savedIDs {
            guard let item = byID[id], !usedIDs.contains(id) else { continue }
            ordered.append(item)
            usedIDs.insert(id)
        }

        ordered.append(contentsOf: fallback.filter { !usedIDs.contains($0.id) })
        return ordered
    }

    private func chronologicalEntries(_ entries: [StickerEntry]) -> [StickerEntry] {
        entries
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.timestamp == rhs.element.timestamp {
                    return lhs.offset > rhs.offset
                }
                return lhs.element.timestamp < rhs.element.timestamp
            }
            .map(\.element)
    }

    private func loadStickerOrders() -> [String: [String]] {
        entriesLock.lock()
        defer { entriesLock.unlock() }
        if let cachedOrders { return cachedOrders }
        let orders: [String: [String]]
        if let data = UserDefaults.standard.data(forKey: stickerOrderKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            orders = decoded
        } else {
            orders = [:]
        }
        cachedOrders = orders
        return orders
    }

    private func saveStickerOrders(_ orders: [String: [String]]) {
        entriesLock.lock()
        cachedOrders = orders
        entriesLock.unlock()
        guard let data = try? JSONEncoder().encode(orders) else { return }
        UserDefaults.standard.set(data, forKey: stickerOrderKey)
    }

    private func orderKey(for date: Date) -> String {
        let startOfDay = calendar.startOfDay(for: date)
        return String(Int(startOfDay.timeIntervalSince1970))
    }

    private func removeStickerIDFromSavedOrders(_ id: String) {
        var orders = loadStickerOrders()
        var changed = false
        for key in orders.keys {
            let filtered = orders[key]?.filter { $0 != id } ?? []
            if filtered != orders[key] {
                orders[key] = filtered
                changed = true
            }
        }
        if changed {
            saveStickerOrders(orders.filter { !$0.value.isEmpty })
        }
    }

    private func deleteStickerImage(id: String) {
        guard let dir = stickersDirectory else { return }
        let imageURL = dir.appendingPathComponent("\(id).png")
        try? fileManager.removeItem(at: imageURL)
    }
}

private extension UIImage {
    func resizedForStickerStorage(maxDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else { return self }

        let ratio = maxDimension / longestSide
        let targetSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

/// Lightweight metadata stored in UserDefaults
struct StickerEntry: Codable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let timestamp: TimeInterval

    var date: Date {
        Date(timeIntervalSince1970: timestamp)
    }
}
