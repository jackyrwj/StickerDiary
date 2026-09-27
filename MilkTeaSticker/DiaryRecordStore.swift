import Foundation
import UIKit

/// Persists diaries as one JSON file in Application Support.
///
/// Reads are served from an in-memory copy; writes update memory immediately and
/// hit disk on a background queue, so autosave never blocks typing. Older builds
/// stored the same records in UserDefaults under `dailyDiaryRecords`; they are
/// migrated on first load and the old key is left untouched as a backup.
final class DiaryRecordStore {
    static let shared = DiaryRecordStore()

    private let legacyUserDefaultsKey = "dailyDiaryRecords"
    private let calendar = Calendar.current
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "DiaryRecordStore.write", qos: .utility)
    private var cachedEntries: [PersistedDiaryRecord]?

    private init() {}

    private var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("DiaryRecords.json")
    }

    func loadCalendarRecords() -> [StickerCalendarRecord] {
        loadEntries().map { entry in
            let date = Date(timeIntervalSince1970: entry.dayTimestamp)
            let stickerCount = StickerStore.shared.orderedEntriesForDate(date).count
            let preview = StickerStore.shared.firstOrderedSticker(for: date)
            return StickerCalendarRecord(
                date: date,
                stickers: preview.map { [Optional($0.image)] } ?? [],
                diaryText: entry.diaryText,
                diaryTitle: entry.diaryTitle,
                stickerCountOverride: stickerCount,
                stickerSlots: entry.stickerSlots ?? [],
                hadStickerSlots: entry.hadStickerSlots ?? [],
                blocks: entry.blocks
            )
        }
    }

    func saveDiaryText(
        _ text: String,
        for date: Date,
        title: String? = nil,
        stickerSlots: [Bool] = [],
        hadStickerSlots: [Bool] = [],
        blocks: [PersistedDiaryBlock]? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dayTimestamp = calendar.startOfDay(for: date).timeIntervalSince1970
        var entries = loadEntries().filter { $0.dayTimestamp != dayTimestamp }
        guard !trimmed.isEmpty else {
            saveEntries(entries)
            return
        }
        entries.append(PersistedDiaryRecord(
            dayTimestamp: dayTimestamp,
            diaryText: trimmed,
            diaryTitle: trimmedTitle?.isEmpty == false ? trimmedTitle : nil,
            stickerSlots: stickerSlots,
            hadStickerSlots: hadStickerSlots,
            blocks: blocks
        ))
        entries.sort { $0.dayTimestamp > $1.dayTimestamp }
        saveEntries(entries)
    }

    func deleteDiary(for date: Date) {
        DiaryFinishedDays.remove(for: date)
        let dayTimestamp = calendar.startOfDay(for: date).timeIntervalSince1970
        let entries = loadEntries().filter { $0.dayTimestamp != dayTimestamp }
        saveEntries(entries)
    }

    private func loadEntries() -> [PersistedDiaryRecord] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedEntries { return cachedEntries }

        let decoder = JSONDecoder()
        var entries: [PersistedDiaryRecord] = []
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode([PersistedDiaryRecord].self, from: data) {
            entries = decoded
        } else if let data = UserDefaults.standard.data(forKey: legacyUserDefaultsKey),
                  let decoded = try? decoder.decode([PersistedDiaryRecord].self, from: data) {
            entries = decoded
            write(entries)
        }
        cachedEntries = entries
        return entries
    }

    private func saveEntries(_ entries: [PersistedDiaryRecord]) {
        lock.lock()
        cachedEntries = entries
        lock.unlock()
        write(entries)
    }

    private func write(_ entries: [PersistedDiaryRecord]) {
        guard let url = fileURL else { return }
        writeQueue.async {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

struct PersistedDiaryRecord: Codable {
    let dayTimestamp: TimeInterval
    let diaryText: String
    var diaryTitle: String?
    var stickerSlots: [Bool]?
    var hadStickerSlots: [Bool]?
    /// Structured paragraphs. `nil` for diaries saved before blocks existed;
    /// those fall back to splitting `diaryText` on blank lines.
    var blocks: [PersistedDiaryBlock]?
}

/// One diary paragraph with everything needed to restore its layout exactly.
struct PersistedDiaryBlock: Codable, Equatable {
    var text: String
    var stickerID: String?
    var hadStickerSlot: Bool
    var stickerOffsetX: Double
    var stickerOffsetY: Double
    var stickerScale: Double
    /// Sticker positions for the inline layout, as UTF-16 offsets into `text`.
    /// `nil` means "never customised", so the default placement is used.
    var inlineStickers: [PersistedInlineSticker]?
}

struct PersistedInlineSticker: Codable, Equatable {
    var stickerID: String
    var offset: Int
}
