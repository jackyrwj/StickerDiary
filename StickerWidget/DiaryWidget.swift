import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Diary Selection Intent

struct SelectDiaryIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "选择日记"
    static var description = IntentDescription("选择要在桌面预览的日记")

    @Parameter(title: "日记")
    var diary: DiaryEntity?
}

struct DiaryEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "日记")
    static var defaultQuery = DiaryEntityQuery()

    var id: String // dateTimestamp as string
    var dateLabel: String
    var textPreview: String
    var stickerID: String?

    var displayRepresentation: DisplayRepresentation {
        let preview = String(textPreview.replacingOccurrences(of: "\u{3000}", with: "").prefix(30))
        if let sid = stickerID, let url = SharedStickerStore.stickerImageURL(id: sid) {
            return DisplayRepresentation(
                title: "\(dateLabel)",
                subtitle: "\(preview)…",
                image: .init(url: url)
            )
        }
        return DisplayRepresentation(
            title: "\(dateLabel)",
            subtitle: "\(preview)…"
        )
    }
}

struct DiaryEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DiaryEntity] {
        let all = SharedStickerStore.readDiarySnapshots()
        return all
            .filter { identifiers.contains(String($0.dateTimestamp)) }
            .map { makeEntity($0) }
    }

    func suggestedEntities() async throws -> [DiaryEntity] {
        SharedStickerStore.readDiarySnapshots().map { makeEntity($0) }
    }

    func defaultResult() async -> DiaryEntity? {
        guard let first = SharedStickerStore.readDiarySnapshots().first else { return nil }
        return makeEntity(first)
    }

    private func makeEntity(_ snapshot: SharedDiarySnapshot) -> DiaryEntity {
        let label = AppLocale.string(from: snapshot.date, chinese: "M月d日 EEEE", template: "MMMdEEEE")
        return DiaryEntity(
            id: String(snapshot.dateTimestamp),
            dateLabel: label,
            textPreview: snapshot.textPreview,
            stickerID: snapshot.stickerID
        )
    }
}

// MARK: - Timeline Provider

struct DiaryTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = DiaryTimelineEntry
    typealias Intent = SelectDiaryIntent

    func placeholder(in context: Context) -> DiaryTimelineEntry {
        DiaryTimelineEntry(date: .now, diaryDate: .now, textPreview: String(localized: "今天阳光很好，路过那家常去的咖啡店，点了一杯桂花拿铁……"), stickerImage: nil)
    }

    func snapshot(for configuration: SelectDiaryIntent, in context: Context) async -> DiaryTimelineEntry {
        if let diary = configuration.diary {
            let sticker: UIImage? = diary.stickerID.flatMap { SharedStickerStore.readStickerImage(id: $0) }
            let timestamp = TimeInterval(diary.id) ?? 0
            return DiaryTimelineEntry(
                date: .now,
                diaryDate: Date(timeIntervalSince1970: timestamp),
                textPreview: diary.textPreview,
                stickerImage: sticker
            )
        }
        // Show latest diary for snapshot
        if let latest = SharedStickerStore.readDiarySnapshots().first {
            let sticker: UIImage? = latest.stickerID.flatMap { SharedStickerStore.readStickerImage(id: $0) }
            return DiaryTimelineEntry(date: .now, diaryDate: latest.date, textPreview: latest.textPreview, stickerImage: sticker)
        }
        return DiaryTimelineEntry(date: .now, diaryDate: nil, textPreview: nil, stickerImage: nil)
    }

    func timeline(for configuration: SelectDiaryIntent, in context: Context) async -> Timeline<DiaryTimelineEntry> {
        // User picked a specific diary → static display
        if let diary = configuration.diary {
            let sticker: UIImage? = diary.stickerID.flatMap { SharedStickerStore.readStickerImage(id: $0) }
            let timestamp = TimeInterval(diary.id) ?? 0
            let entry = DiaryTimelineEntry(
                date: .now,
                diaryDate: Date(timeIntervalSince1970: timestamp),
                textPreview: diary.textPreview,
                stickerImage: sticker
            )
            return Timeline(entries: [entry], policy: .never)
        }

        // No selection → auto-rotate all diary entries every 3 hours
        let snapshots = SharedStickerStore.readDiarySnapshots()
        guard !snapshots.isEmpty else {
            let empty = DiaryTimelineEntry(date: .now, diaryDate: nil, textPreview: nil, stickerImage: nil)
            return Timeline(entries: [empty], policy: .after(.now.addingTimeInterval(3600)))
        }

        let interval: TimeInterval = 3 * 3600 // 3 hours per diary
        var timelineEntries: [DiaryTimelineEntry] = []
        let now = Date.now

        for (index, snapshot) in snapshots.enumerated() {
            let entryDate = now.addingTimeInterval(interval * Double(index))
            let sticker: UIImage? = snapshot.stickerID.flatMap { SharedStickerStore.readStickerImage(id: $0) }
            timelineEntries.append(DiaryTimelineEntry(
                date: entryDate,
                diaryDate: snapshot.date,
                textPreview: snapshot.textPreview,
                stickerImage: sticker
            ))
        }

        let refreshDate = now.addingTimeInterval(interval * Double(snapshots.count))
        return Timeline(entries: timelineEntries, policy: .after(refreshDate))
    }
}

// MARK: - Widget Definition

struct DiaryWidget: Widget {
    let kind: String = WidgetKind.diary

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectDiaryIntent.self,
            provider: DiaryTimelineProvider()
        ) { entry in
            DiaryWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("今日日记")
        .description("预览日记，不选则自动轮播")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
