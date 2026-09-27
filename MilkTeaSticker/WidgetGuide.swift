import SwiftUI
import WidgetKit

/// iOS has no API to add a widget for the user, so the app shows how to do it:
/// once or twice after the user has written a diary, and from Settings.
enum WidgetGuide {
    private static let promptCountKey = "widgetGuidePromptCountV1"
    private static let lastPromptKey = "widgetGuideLastPromptV1"
    private static let optOutKey = "widgetGuideOptOutV1"
    private static let maxPrompts = 2
    private static let minIntervalBetweenPrompts: TimeInterval = 3 * 24 * 3600

    /// Kinds of this app's widgets currently on the Home Screen.
    static func installedKinds() async -> Set<String> {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let kinds = (try? result.get())?.map(\.kind) ?? []
                continuation.resume(returning: Set(kinds))
            }
        }
    }

    /// Frequency cap for the automatic prompt; does not check installed widgets.
    static var canPrompt: Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: optOutKey),
              defaults.integer(forKey: promptCountKey) < maxPrompts else { return false }
        let last = defaults.double(forKey: lastPromptKey)
        return last == 0 || Date().timeIntervalSince1970 - last >= minIntervalBetweenPrompts
    }

    static func recordPrompt() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: promptCountKey) + 1, forKey: promptCountKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastPromptKey)
    }

    static func optOut() {
        UserDefaults.standard.set(true, forKey: optOutKey)
    }
}

// MARK: - Guide Sheet

struct WidgetGuideSheet: View {
    /// Shown automatically (offers "don't show again") rather than opened from Settings.
    var isPrompt = false

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPage = 0
    @State private var installedKinds: Set<String> = []
    @State private var stickerEntry = StickerTimelineEntry(date: .now, stickerID: nil, stickerTitle: nil, stickerImage: nil)
    @State private var diaryEntry = DiaryTimelineEntry(date: .now, diaryDate: nil, textPreview: nil, stickerImage: nil)

    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let mutedInk = Color(red: 0.56, green: 0.56, blue: 0.58)
    private let cardBg = Color(red: 0.96, green: 0.96, blue: 0.97)
    private let accent = Color(red: 0.95, green: 0.65, blue: 0.12)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 28)

                    Text("桌面小组件")
                        .font(DiaryFont.display(size: 34, weight: .black, design: .default))
                        .foregroundStyle(ink)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                    Text("不用打开 App，也能在桌面看到你的贴纸和日记。")
                        .font(DiaryFont.display(size: 15, weight: .medium, design: .default))
                        .foregroundStyle(mutedInk)
                        .padding(.horizontal, 24)
                        .padding(.top, 6)

                    previewPager
                        .padding(.top, 22)

                    stepsCard
                        .padding(.horizontal, 20)
                        .padding(.top, 22)
                        .padding(.bottom, 16)
                }
            }

            buttons
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        .background(Color.white.ignoresSafeArea())
        .task {
            loadPreviewEntries()
            installedKinds = await WidgetGuide.installedKinds()
        }
    }

    // MARK: Previews

    private var previewPager: some View {
        VStack(spacing: 12) {
            TabView(selection: $selectedPage) {
                previewPage(
                    title: String(localized: "贴纸"),
                    subtitle: String(localized: "展示贴纸，不选则自动轮播"),
                    kind: WidgetKind.sticker
                ) {
                    StickerWidgetEntryView(entry: stickerEntry, familyOverride: .systemMedium)
                }
                .tag(0)

                previewPage(
                    title: String(localized: "今日日记"),
                    subtitle: String(localized: "预览日记，不选则自动轮播"),
                    kind: WidgetKind.diary
                ) {
                    // Stand-in for the system's content margins, which only exist on the Home Screen.
                    DiaryWidgetEntryView(entry: diaryEntry, familyOverride: .systemMedium)
                        .padding(6)
                }
                .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 250)

            HStack(spacing: 7) {
                ForEach(0..<2, id: \.self) { index in
                    Capsule()
                        .fill(index == selectedPage ? accent : mutedInk.opacity(0.28))
                        .frame(width: index == selectedPage ? 18 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selectedPage)
            .accessibilityHidden(true)
        }
    }

    private func previewPage<Content: View>(
        title: String,
        subtitle: String,
        kind: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 14) {
            content()
                .frame(width: 329, height: 155)
                .background(WidgetPaperBackground())
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(DiaryFont.display(size: 17, weight: .bold, design: .default))
                        .foregroundStyle(ink)
                    if installedKinds.contains(kind) {
                        Label("已添加", systemImage: "checkmark")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.36, green: 0.66, blue: 0.40), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(DiaryFont.display(size: 13, weight: .medium, design: .default))
                    .foregroundStyle(mutedInk)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Steps

    private var stepsCard: some View {
        let appName = String(localized: "贴纸日记")
        return VStack(alignment: .leading, spacing: 18) {
            Text("添加方法")
                .font(DiaryFont.display(size: 17, weight: .bold, design: .default))
                .foregroundStyle(ink)

            stepRow(number: 1, icon: "hand.tap", text: String(localized: "回到桌面，长按空白处，直到图标开始晃动"))
            stepRow(number: 2, icon: "plus.square", text: String(localized: "点左上角的「编辑」，再点「添加小组件」"))
            stepRow(number: 3, icon: "magnifyingglass", text: String(localized: "搜索「\(appName)」，选好样式和尺寸后添加"))

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 20)
                Text("添加后长按小组件，点「编辑小组件」，可以固定显示某一张贴纸或某一篇日记。")
                    .font(DiaryFont.display(size: 13, weight: .medium, design: .default))
                    .foregroundStyle(mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func stepRow(number: Int, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(accent, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(DiaryFont.display(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(mutedInk)
                .padding(.top, 3)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Buttons

    private var buttons: some View {
        VStack(spacing: 4) {
            Button {
                dismiss()
            } label: {
                Text("知道了")
                    .font(DiaryFont.display(size: 17, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)

            if isPrompt {
                Button {
                    WidgetGuide.optOut()
                    dismiss()
                } label: {
                    Text("不再提示")
                        .font(DiaryFont.display(size: 14, weight: .semibold, design: .default))
                        .foregroundStyle(mutedInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Data

    /// The widgets' own data files, so the preview shows the user's latest sticker and diary.
    private func loadPreviewEntries() {
        if let latest = SharedStickerStore.readEntries().first {
            stickerEntry = StickerTimelineEntry(
                date: .now,
                stickerID: latest.id,
                stickerTitle: latest.title,
                stickerImage: SharedStickerStore.readStickerImage(id: latest.id)
            )
        }

        if let latest = SharedStickerStore.readDiarySnapshots().first {
            diaryEntry = DiaryTimelineEntry(
                date: .now,
                diaryDate: latest.date,
                textPreview: latest.textPreview,
                stickerImage: latest.stickerID.flatMap { SharedStickerStore.readStickerImage(id: $0) }
            )
        } else {
            diaryEntry = DiaryTimelineEntry(
                date: .now,
                diaryDate: .now,
                textPreview: String(localized: "今天阳光很好，路过那家常去的咖啡店，点了一杯桂花拿铁……"),
                stickerImage: stickerEntry.stickerImage
            )
        }
    }
}
