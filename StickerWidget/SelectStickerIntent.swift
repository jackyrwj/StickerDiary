import AppIntents
import UIKit

// MARK: - Widget Configuration Intent

struct SelectStickerIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "选择贴纸"
    static var description = IntentDescription("选择要在桌面显示的贴纸")

    @Parameter(title: "贴纸")
    var sticker: StickerEntity?
}

// MARK: - Sticker Entity

struct StickerEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "贴纸")
    static var defaultQuery = StickerEntityQuery()

    var id: String
    var title: String
    var subtitle: String
    var dateLabel: String

    var displayRepresentation: DisplayRepresentation {
        let label = dateLabel.isEmpty ? title : "\(dateLabel)  \(title)"

        // Thumbnail from shared container
        if let imageURL = SharedStickerStore.stickerImageURL(id: id) {
            return DisplayRepresentation(
                title: "\(label)",
                image: .init(url: imageURL)
            )
        }

        return DisplayRepresentation(title: "\(label)")
    }
}

// MARK: - Entity Query

struct StickerEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [StickerEntity] {
        let entries = SharedStickerStore.readEntries()
        return entries
            .filter { identifiers.contains($0.id) }
            .map { makeEntity($0) }
    }

    func suggestedEntities() async throws -> [StickerEntity] {
        SharedStickerStore.readEntries().map { makeEntity($0) }
    }

    func defaultResult() async -> StickerEntity? {
        guard let first = SharedStickerStore.readEntries().first else { return nil }
        return makeEntity(first)
    }

    private func makeEntity(_ entry: SharedStickerEntry) -> StickerEntity {
        let dateLabel = AppLocale.string(from: entry.date, chinese: "M月d日", template: "MMMd")

        return StickerEntity(
            id: entry.id,
            title: entry.title,
            subtitle: entry.subtitle,
            dateLabel: dateLabel
        )
    }
}
