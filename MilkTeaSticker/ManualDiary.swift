import SwiftUI
import UIKit

/// Product differences between the Chinese app and the English (US) app.
///
/// The Chinese app writes diaries with AI. The English app is a hand-written
/// sticker journal: no AI writing, so no photos leave the device, and Pro sells
/// unlimited stickers per page instead of AI quota. Paper themes and fonts are
/// Pro in both.
///
/// Chinese users can turn AI writing off in Settings and write by hand like the
/// English app, but they keep the Chinese Pro rules (no sticker cap).
enum AppFeatures {
    static let aiDiaryEnabledKey = "aiDiaryEnabled"

    /// Whether this edition offers AI writing at all.
    static var aiDiaryAvailable: Bool { AppLocale.isChinese }

    /// Whether AI writes diaries right now. On by default so existing users
    /// keep their AI button after updating.
    static var aiDiary: Bool {
        aiDiaryAvailable && (UserDefaults.standard.object(forKey: aiDiaryEnabledKey) as? Bool ?? true)
    }

    /// Paper themes are Pro, except for people who installed before they were
    /// (they got them free, so they keep them).
    static var paperThemesRequirePro: Bool { !LegacyPerks.freePaperThemes }

    /// Free English pages hold a few stickers; Pro removes the cap.
    static var stickersPerPageRequirePro: Bool { !aiDiaryAvailable }
}

/// Perks kept by people who installed a version where they were still free.
enum LegacyPerks {
    private static let decidedKey = "legacyPerksDecidedV1"
    private static let freePaperThemesKey = "legacyFreePaperThemes"
    /// Keys only an earlier version could have written by the time this runs.
    private static let earlierVersionKeys = ["stickerEntries", "diaryPaperColor", "hasSeenMainFlowCoachV1"]

    static var freePaperThemes: Bool {
        UserDefaults.standard.bool(forKey: freePaperThemesKey)
    }

    /// Run once at launch before any view reads or writes those keys. The
    /// answer is stored, so later launches don't re-decide it.
    static func recordOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: decidedKey) else { return }
        let isEarlierInstall = earlierVersionKeys.contains { defaults.object(forKey: $0) != nil }
        defaults.set(isEarlierInstall, forKey: freePaperThemesKey)
        defaults.set(true, forKey: decidedKey)
    }
}

/// English app: a free page holds up to `freeLimit` stickers, Pro is unlimited.
/// Only adding is gated; pages already over the limit stay as they are.
@MainActor
enum PageStickerLimit {
    static let freeLimit = 4

    static var isActive: Bool {
        AppFeatures.stickersPerPageRequirePro && !SubscriptionManager.shared.isProUser
    }

    /// How many more stickers a page holding `count` can take, or nil when
    /// there is no limit. `count` is only evaluated when the limit applies.
    static func remaining(count: () -> Int) -> Int? {
        guard isActive else { return nil }
        return max(0, freeLimit - count())
    }
}

/// Legal pages hosted from docs/ on GitHub Pages; the English pages live in docs/en.
enum LegalPage {
    case terms
    case privacy

    var url: URL {
        let base = "https://jackyrwj.github.io/StickerDiary/"
        let path: String
        switch self {
        case .terms: path = AppLocale.isChinese ? "user-agreement.html" : "en/terms.html"
        case .privacy: path = AppLocale.isChinese ? "privacy-policy.html" : "en/privacy-policy.html"
        }
        return URL(string: base + path)!
    }
}

// MARK: - Writing prompts

/// Rotating prompts shown in empty paragraphs, so a blank page is never just
/// blank. Fixed lists written per language, nothing is generated.
enum WritingPrompts {
    static var all: [String] { AppLocale.isChinese ? chinese : english }

    private static let chinese: [String] = [
        "今天什么让你笑了？",
        "这是在哪里遇到的？",
        "它为什么吸引了你？",
        "当时和谁在一起？",
        "它是什么味道、什么声音？",
        "如果讲给朋友听，你会怎么说？",
        "今天有什么意外的事？",
        "此刻你想感谢什么？",
        "今天最好的五分钟是哪一段？",
        "拍下它的时候，你是什么心情？",
        "今天差点错过了什么？",
        "关于它，你最想记住什么？",
        "今天天气怎么样？",
        "哪首歌适合这一刻？",
        "今天学到了什么？",
        "有什么比想象中难？",
        "今天有什么小小的成就？",
        "如果重来一次，你会怎么做？",
        "今天和昨天有什么不一样？",
        "谁会想看到这个？",
        "那时候你在想什么？",
        "它背后有什么故事？",
        "今天犒劳了自己什么？",
        "最近在期待什么？",
        "什么让你笑出了声？",
        "用三个词形容它。",
        "今天早上脑子里在想什么？",
        "下一站想去哪里？",
        "今天有什么让你觉得温暖？",
        "有什么别人可能没注意到的小细节？",
    ]

    private static let english: [String] = [
        "What made you smile today?",
        "Where did you find this?",
        "Why did this catch your eye?",
        "Who were you with?",
        "What did it smell, taste or sound like?",
        "What would you tell a friend about this?",
        "What surprised you today?",
        "What are you grateful for right now?",
        "What was the best five minutes of today?",
        "How were you feeling when you took this?",
        "What almost didn't happen today?",
        "What do you want to remember about this?",
        "What was the weather like?",
        "What song fits this moment?",
        "What did you learn today?",
        "What was harder than expected?",
        "What small win did you have?",
        "What would you do differently?",
        "What made today different from yesterday?",
        "Who would love to see this?",
        "What were you thinking about?",
        "What's the story behind this?",
        "What did you treat yourself to?",
        "What are you looking forward to?",
        "What made you laugh?",
        "Describe it in three words.",
        "What was on your mind this morning?",
        "Where do you want to go next?",
        "What felt cozy today?",
        "What's one thing you noticed that others might miss?",
    ]

    /// Stable for a given day and paragraph, so the prompt doesn't jump around
    /// while typing; `shuffle` moves every paragraph to a new prompt.
    static func prompt(for date: Date, index: Int, shuffle: Int) -> String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        let position = (day * 7 + index * 5 + shuffle * 11) % all.count
        return all[(position + all.count) % all.count]
    }
}

// MARK: - Monthly recap

struct MonthlyRecapData {
    let month: Date
    let stickers: [UIImage]
    let stickerCount: Int
    let stickerDays: Int
    let diaryDays: Int

    static let maxStickers = 25

    static func load(month: Date, records: [StickerCalendarRecord]) -> MonthlyRecapData {
        let calendar = Calendar.current
        let entries = StickerStore.shared.loadEntries()
            .filter { calendar.isDate($0.date, equalTo: month, toGranularity: .month) }
            .sorted { $0.timestamp < $1.timestamp }
        let stickers = entries
            .compactMap { StickerStore.shared.loadStickerImage(id: $0.id) }
            .prefix(maxStickers)
        let stickerDays = Set(entries.map { calendar.startOfDay(for: $0.date) }).count
        let diaryDays = Set(
            records
                .filter { calendar.isDate($0.date, equalTo: month, toGranularity: .month) && isRealDiaryText($0.diaryText) }
                .map { calendar.startOfDay(for: $0.date) }
        ).count
        return MonthlyRecapData(
            month: month,
            stickers: Array(stickers),
            stickerCount: entries.count,
            stickerDays: stickerDays,
            diaryDays: diaryDays
        )
    }
}

/// The shareable 4:5 recap card (1080×1350 when rendered at 3×).
struct MonthlyRecapCard: View {
    let data: MonthlyRecapData

    static let size = CGSize(width: 360, height: 450)

    private let ink = Color(red: 0.19, green: 0.13, blue: 0.11)
    private let mutedInk = Color(red: 0.50, green: 0.44, blue: 0.40)
    private let paper = Color(red: 1.0, green: 0.97, blue: 0.90)
    private let accent = Color(red: 0.80, green: 0.35, blue: 0.24)

    private var monthName: String {
        AppLocale.string(from: data.month, chinese: "M月", template: "MMMM")
    }

    private var yearText: String {
        AppLocale.string(from: data.month, chinese: "yyyy年", template: "yyyy")
    }

    private var columnCount: Int {
        switch data.stickers.count {
        case ...4: 2
        case ...9: 3
        case ...16: 4
        default: 5
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandRow

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(monthName)
                    .font(DiaryFont.display(size: 34, weight: .black))
                    .foregroundStyle(ink)
                Text(yearText)
                    .font(DiaryFont.display(size: 16, weight: .bold))
                    .foregroundStyle(mutedInk)
            }
            .padding(.top, 14)
            Text("我的贴纸月报")
                .font(DiaryFont.display(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.top, 2)

            stickerGrid
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 12)

            statsRow
        }
        .padding(22)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(paper)
    }

    private var brandRow: some View {
        HStack(spacing: 7) {
            Image("BrandAppIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .stroke(.black.opacity(0.06), lineWidth: 0.5)
                )
            Text("贴纸日记")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(mutedInk)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            stat(value: data.stickerCount, label: String(localized: "张贴纸"))
            statDivider
            stat(value: data.stickerDays, label: String(localized: "天有贴纸"))
            statDivider
            stat(value: data.diaryDays, label: String(localized: "天写了日记"))
        }
        .padding(.vertical, 10)
        .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statDivider: some View {
        Rectangle()
            .fill(mutedInk.opacity(0.18))
            .frame(width: 1, height: 30)
    }

    @ViewBuilder
    private var stickerGrid: some View {
        if data.stickers.isEmpty {
            Text("这个月还没有贴纸")
                .font(DiaryFont.display(size: 16, weight: .semibold))
                .foregroundStyle(mutedInk.opacity(0.7))
        } else {
            // Not a lazy grid: ImageRenderer doesn't draw lazy containers.
            // Fixed cell sizes keep a short last row centred under the full ones.
            GeometryReader { geo in
                let columns = columnCount
                let rows = stride(from: 0, to: data.stickers.count, by: columns).map {
                    Array($0..<min($0 + columns, data.stickers.count))
                }
                let spacing: CGFloat = 4
                let cellWidth = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                let cellHeight = (geo.size.height - spacing * CGFloat(rows.count - 1)) / CGFloat(rows.count)
                VStack(spacing: spacing) {
                    ForEach(rows.indices, id: \.self) { row in
                        HStack(spacing: spacing) {
                            ForEach(rows[row], id: \.self) { index in
                                Image(uiImage: data.stickers[index])
                                    .resizable()
                                    .scaledToFit()
                                    .rotationEffect(.degrees(Self.tilt(for: index)))
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                    .frame(width: cellWidth, height: min(cellHeight, cellWidth * 1.2))
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func stat(value: Int, label: String) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(ink)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(mutedInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    /// Small, repeatable tilt so the grid looks hand-placed.
    private static func tilt(for index: Int) -> Double {
        let pattern: [Double] = [-6, 4, -2, 7, -5, 3, 6, -4, 2, -7]
        return pattern[index % pattern.count]
    }
}

struct MonthlyRecapSheet: View {
    let data: MonthlyRecapData
    @Environment(\.dismiss) private var dismiss
    @State private var renderedImage: UIImage?
    @State private var showShareSheet = false

    private let ink = Color(red: 0.34, green: 0.24, blue: 0.18)

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("月度回顾")
                    .font(DiaryFont.display(size: 20, weight: .black))
                    .foregroundStyle(ink)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(ink.opacity(0.25))
                }
                .accessibilityLabel(String(localized: "关闭"))
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)

            Spacer(minLength: 0)

            MonthlyRecapCard(data: data)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                .scaleEffect(0.92)

            Spacer(minLength: 0)

            Button {
                renderedImage = renderedImage ?? render()
                showShareSheet = renderedImage != nil
            } label: {
                Label("分享回顾", systemImage: "square.and.arrow.up")
                    .font(DiaryFont.display(size: 17))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(ink, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color(red: 0.98, green: 0.96, blue: 0.93).ignoresSafeArea())
        .sheet(isPresented: $showShareSheet) {
            if let renderedImage {
                ShareSheetView(items: [renderedImage])
            }
        }
    }

    @MainActor
    private func render() -> UIImage? {
        let renderer = ImageRenderer(content: MonthlyRecapCard(data: data))
        renderer.scale = 3
        return renderer.uiImage
    }
}
