import WidgetKit
import SwiftUI

// Widget entry views, shared with the app so the widget guide can preview
// the real widgets with the user's own stickers and diaries.

enum WidgetKind {
    static let sticker = "StickerWidget"
    static let diary = "DiaryWidget"
}

/// Cream paper gradient behind both widgets.
struct WidgetPaperBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.95, blue: 0.90),
                Color(red: 0.95, green: 0.91, blue: 0.85)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Sticker Widget

struct StickerTimelineEntry: TimelineEntry {
    let date: Date
    let stickerID: String?
    let stickerTitle: String?
    let stickerImage: UIImage?
}

struct StickerWidgetEntryView: View {
    var entry: StickerTimelineEntry
    /// Set by in-app previews, where there is no widget environment.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        Group {
            if let image = entry.stickerImage {
                stickerContent(image: image)
            } else {
                emptyContent
            }
        }
        .containerBackground(for: .widget) {
            WidgetPaperBackground()
        }
    }

    private func stickerContent(image: UIImage) -> some View {
        GeometryReader { geo in
            let inset: CGFloat = family == .systemSmall ? 6 : 10
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    width: geo.size.width - inset * 2,
                    height: geo.size.height - inset * 2
                )
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var emptyContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("还没有贴纸")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Diary Widget

struct DiaryTimelineEntry: TimelineEntry {
    let date: Date
    let diaryDate: Date?
    let textPreview: String?
    let stickerImage: UIImage?
}

struct DiaryWidgetEntryView: View {
    var entry: DiaryTimelineEntry
    /// Set by in-app previews, where there is no widget environment.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    private let ink = Color(red: 0.31, green: 0.24, blue: 0.20)
    private let mutedInk = Color(red: 0.56, green: 0.50, blue: 0.44)

    var body: some View {
        Group {
            if let text = entry.textPreview, let diaryDate = entry.diaryDate {
                diaryContent(date: diaryDate, text: text)
            } else {
                emptyContent
            }
        }
        .containerBackground(for: .widget) {
            WidgetPaperBackground()
        }
    }

    private func diaryContent(date: Date, text: String) -> some View {
        let dateStr = AppLocale.string(from: date, chinese: "M月d日 EEEE", template: "MMMdEEEE")

        let cleanText = text.replacingOccurrences(of: "\u{3000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text(dateStr)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(mutedInk)
                    .padding(.bottom, 6)

                Text(cleanText)
                    .font(DiaryFont.font(size: family == .systemSmall ? 13 : 14, weight: .medium))
                    .foregroundStyle(ink)
                    .lineSpacing(5)
                    .lineLimit(family == .systemSmall ? 5 : 4)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .padding(.trailing, entry.stickerImage != nil && family != .systemSmall ? 80 : 14)
            .padding(.vertical, 12)

            if let sticker = entry.stickerImage {
                let size: CGFloat = family == .systemSmall ? 44 : 64
                Image(uiImage: sticker)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(6))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 3)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
            }
        }
    }

    private var emptyContent: some View {
        VStack(spacing: 6) {
            Image(systemName: "book.closed")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(mutedInk.opacity(0.6))
            Text("还没有日记")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(mutedInk.opacity(0.6))
        }
    }
}
