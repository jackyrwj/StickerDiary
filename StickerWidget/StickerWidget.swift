import WidgetKit
import SwiftUI

// MARK: - Timeline Provider

struct StickerTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = StickerTimelineEntry
    typealias Intent = SelectStickerIntent

    func placeholder(in context: Context) -> StickerTimelineEntry {
        StickerTimelineEntry(date: .now, stickerID: nil, stickerTitle: String(localized: "贴纸"), stickerImage: nil)
    }

    func snapshot(for configuration: SelectStickerIntent, in context: Context) async -> StickerTimelineEntry {
        if let sticker = configuration.sticker {
            let image = SharedStickerStore.readStickerImage(id: sticker.id)
            return StickerTimelineEntry(date: .now, stickerID: sticker.id, stickerTitle: sticker.title, stickerImage: image)
        }
        // Show latest sticker for snapshot
        if let first = SharedStickerStore.readEntries().first {
            let image = SharedStickerStore.readStickerImage(id: first.id)
            return StickerTimelineEntry(date: .now, stickerID: first.id, stickerTitle: first.title, stickerImage: image)
        }
        return StickerTimelineEntry(date: .now, stickerID: nil, stickerTitle: nil, stickerImage: nil)
    }

    func timeline(for configuration: SelectStickerIntent, in context: Context) async -> Timeline<StickerTimelineEntry> {
        // User picked a specific sticker → static display
        if let sticker = configuration.sticker {
            let image = SharedStickerStore.readStickerImage(id: sticker.id)
            let entry = StickerTimelineEntry(
                date: .now,
                stickerID: sticker.id,
                stickerTitle: sticker.title,
                stickerImage: image
            )
            return Timeline(entries: [entry], policy: .never)
        }

        // No selection → auto-rotate all stickers every 2 hours
        let allEntries = SharedStickerStore.readEntries()
        guard !allEntries.isEmpty else {
            let empty = StickerTimelineEntry(date: .now, stickerID: nil, stickerTitle: nil, stickerImage: nil)
            return Timeline(entries: [empty], policy: .after(.now.addingTimeInterval(3600)))
        }

        let interval: TimeInterval = 2 * 3600 // 2 hours per sticker
        var timelineEntries: [StickerTimelineEntry] = []
        let now = Date.now

        for (index, stickerEntry) in allEntries.enumerated() {
            let entryDate = now.addingTimeInterval(interval * Double(index))
            let image = SharedStickerStore.readStickerImage(id: stickerEntry.id)
            timelineEntries.append(StickerTimelineEntry(
                date: entryDate,
                stickerID: stickerEntry.id,
                stickerTitle: stickerEntry.title,
                stickerImage: image
            ))
        }

        // After showing all, refresh to loop again
        let refreshDate = now.addingTimeInterval(interval * Double(allEntries.count))
        return Timeline(entries: timelineEntries, policy: .after(refreshDate))
    }
}

// MARK: - Widget Definition

struct StickerWidget: Widget {
    let kind: String = WidgetKind.sticker

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectStickerIntent.self,
            provider: StickerTimelineProvider()
        ) { entry in
            StickerWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("贴纸")
        .description("展示贴纸，不选则自动轮播")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
