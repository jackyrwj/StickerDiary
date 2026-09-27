import SwiftUI
import WidgetKit
import UIKit

// Diary page: paragraph editor, inline-sticker editor and paper styles.

struct DiaryBookView: View {
    @Environment(\.scenePhase) private var scenePhase

    let entries: [DiaryEntry]
    let records: [StickerCalendarRecord]
    @Binding var selectedDate: Date
    let isGenerating: Bool
    let generationError: String?
    let generationRevision: Int
    var generatedTitle: String? = nil
    let onArchive: (Date, [EditableDiaryEntry], String?) -> Void
    let onAutosave: (Date, [EditableDiaryEntry], String?) -> Void
    let onCaptureForDate: (Date) -> Void
    let onImportForDate: (Date) -> Void
    let onDateEntries: (Date) -> [DiaryEntry]
    let onRegenerate: (Date) -> Void
    let onClearDiary: (Date) -> Void
    let activeCoachStep: AppCoachStep?
    let onCoachAction: (AppCoachStep) -> Void
    let onCoachSkip: () -> Void
    let onDiaryGenerationAnimationComplete: () -> Void
    /// "写好了": the page has been saved and tucked into the notebook.
    let onFinish: (Date) -> Void
    let onClose: () -> Void
    /// Not read directly: observing it redraws when AI writing is toggled in Settings.
    @AppStorage(AppFeatures.aiDiaryEnabledKey) private var aiDiaryEnabled = true
    @State private var visibleCharacters = 0
    @State private var visibleStickerCount = 0
    @State private var paperStyle: DiaryPaperStyle = .grid
    @AppStorage("diaryPaperColor") private var selectedPaperColor: DiaryPaperColor = .classic
    /// Whether shared diary images carry the app icon + "Sticker Diary" footer.
    @AppStorage("diaryShareWatermark") private var diaryShareWatermark = true
    @ObservedObject private var subscription = SubscriptionManager.shared
    /// Bumped by the lightbulb button to show a different set of writing prompts.
    @State private var writingPromptShuffle = 0
    @State private var richFocusRequest = 0
    /// Prompt shown in a floating card when no empty paragraph can display it.
    @State private var floatingPrompt: String?
    @State private var floatingPromptHideTask: Task<Void, Never>?
    @State private var showPaperColorPicker = false
    @State private var showFontPicker = false
    /// Stored in the App Group so the widget uses the same face.
    @AppStorage(DiaryFont.selectionKey, store: DiaryFont.defaults) private var storedHandwriting: DiaryHandwriting = .standard
    @State private var showQuickPromptPicker = false
    @State private var layoutStyle: DiaryLayoutStyle = .timeline
    @State private var editableEntries: [EditableDiaryEntry] = []
    @State private var isWriting = false
    @State private var isStickerLayoutMode = false
    @State private var isArchivingPage = false
    @State private var isPageArchived = false
    /// Days marked "写好了": the page is read-only until "继续编辑".
    @State private var finishedDayIDs = DiaryFinishedDays.load()
    @State private var currentWritingIndex = 0
    @State private var isDiaryDeleteTargetVisible = false
    @State private var isDiaryDeleteTargetActive = false
    @State private var richCombinedText: String = ""
    @State private var richInlineInsertions: [InlineStickerInsertion] = []
    @State private var richCursorPosition: Int = 0
    /// Entry IDs / texts of the paragraphs currently shown in the inline editor,
    /// used to map inline edits back onto `editableEntries`.
    @State private var richBlockEntryIDs: [UUID] = []
    @State private var richBlockTexts: [String] = []
    @State private var richContentInitialized = false
    @State private var richContentRevision = 0
    /// Fullscreen editing follows the keyboard: on while a text view is focused.
    @State private var isEditorFocused = false
    @State private var isCalendarExpanded = false
    @State private var editorExitTask: Task<Void, Never>?
    @State private var writingTotalCharacters = 0
    @State private var diaryCustomTitle: String = ""
    @State private var originalHadSticker: Set<Int> = []
    @State private var dateStickerOptions: [DiaryStickerOption] = []
    @State private var activeGenerationStickerIndex: Int?
    @State private var generationAnimationStopToken = 0
    @State private var lastAnimatedGenerationRevision = 0
    @State private var saveState: DiarySaveState = .idle
    @State private var autosaveTask: Task<Void, Never>?
    /// True after an autosave wrote to disk but the parent's records weren't
    /// refreshed yet; flushed by the next full save or when the page goes away.
    @State private var needsFullSave = false
    @State private var saveStateResetTask: Task<Void, Never>?
    @State private var showCloseDuringGenerationConfirm = false
    @State private var showRegenerateConfirm = false
    @State private var showClearDiaryConfirm = false
    @State private var showStickerLimitAlert = false
    @State private var showNetworkPermissionAlert = false
    @State private var allowNextNetworkPermissionRetry = false
    @State private var shouldRetryNetworkRequestOnActive = false
    @State private var previewedDiaryStickerID: String?
    /// Maximum number of stickers that can be sent to the AI for one diary.
    private static let maxDiaryStickers = 8
    @State private var autoFocusBlankEntry = false
    @State private var showDiaryShareSheet = false
    @State private var diarySharePreviewImage: UIImage?
    @State private var lastDiaryShareImage: UIImage?
    @State private var diaryScrollResetToken = 0
    @State private var coachFrames: [AppCoachTarget: CGRect] = [:]
    @State private var coachGlobalOrigin: CGPoint = .zero

    private let calendar = Calendar.current

    /// A Pro theme picked while subscribed falls back to classic once Pro lapses.
    private var paperColor: DiaryPaperColor {
        selectedPaperColor.isLocked(isPro: subscription.isProUser) ? .classic : selectedPaperColor
    }

    /// Placeholder for an empty paragraph: a rotating writing prompt.
    private func writingPlaceholder(for index: Int) -> String {
        WritingPrompts.prompt(for: selectedDate, index: index, shuffle: writingPromptShuffle)
    }

    /// Only the first empty paragraph shows a prompt, so the page shows one at a time.
    private var placeholderEntryIndex: Int? {
        editableEntries.firstIndex {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var currentEntries: [DiaryEntry] {
        entries
    }

    private var dateStickerImages: [UIImage] {
        dateStickerOptions.map(\.image)
    }

    /// Stickers offered by the inline toolbar: the day's stickers, plus any
    /// sticker already in the diary that is no longer in the store.
    private var allAvailableStickers: [DiaryStickerOption] {
        var options = dateStickerOptions
        var seen = Set(options.map(\.id))
        for entry in editableEntries {
            guard let sticker = entry.sticker else { continue }
            let id = entry.stickerID ?? "entry-\(entry.id.uuidString)"
            if seen.insert(id).inserted, !options.contains(where: { $0.image === sticker }) {
                options.append(DiaryStickerOption(id: id, stickerID: entry.stickerID, image: sticker))
            }
        }
        return options
    }

    private func reloadDateStickers() {
        dateStickerOptions = DiaryStickerOption.forDate(selectedDate)
    }

    private func totalCharacters(of source: [DiaryEntry]) -> Int {
        source.reduce(0) { $0 + diaryBlockText(for: $1).count + 2 }
    }

    private var fullText: String {
        currentEntries.map { diaryBlockText(for: $0) }.joined(separator: "\n\n")
    }

    private var hasEditableDiaryContent: Bool {
        editableEntries.contains { entry in
            !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entry.sticker != nil
        }
    }

    private var hasDiaryText: Bool {
        editableEntries.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Read-only "写好了" state. Only a page with words can be finished.
    private var isDiaryFinished: Bool {
        finishedDayIDs.contains(selectedDayID) && hasDiaryText && !isWriting && !isGenerating
    }

    /// Shows the bottom "写好了" / "继续编辑" button.
    private var showsFinishToggle: Bool {
        hasDiaryText
            && !isEditorFocused && !isWriting && !isGenerating
            && !isArchivingPage && !isPageArchived
            && !showPaperColorPicker && !showFontPicker
            && !isDiaryDeleteTargetVisible
    }

    private var shouldConfirmRegeneration: Bool {
        hasEditableDiaryContent && !isWriting && !isGenerating
    }

    private var canUseToolbarMagicWand: Bool {
        (hasEditableDiaryContent || !dateStickerImages.isEmpty) && !isWriting && !isGenerating && !isArchivingPage && !isPageArchived
    }

    private var hasDiaryToClear: Bool {
        hasEditableDiaryContent || records.contains {
            calendar.isDate($0.date, inSameDayAs: selectedDate)
            && !$0.diaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var isEmptyDiaryState: Bool {
        editableEntries.isEmpty && !isWriting && !isGenerating && generationError == nil
    }

    private var diaryHeaderActions: some View {
        HStack(spacing: 8) {
            HeaderIconButton(
                systemImage: "square.and.arrow.up",
                accessibilityLabel: String(localized: "分享日记")
            ) {
                performDiaryShareAction()
            }
            .disabled(!hasEditableDiaryContent || isWriting || isGenerating)
            .opacity(hasEditableDiaryContent && !isWriting && !isGenerating ? 1 : 0.4)
            .appCoachAnchor(.diaryShare)

            if AppFeatures.aiDiary, !isDiaryFinished {
                HeaderIconButton(
                    systemImage: "wand.and.stars",
                    accessibilityLabel: String(localized: "AI 重写日记")
                ) {
                    dismissKeyboard()
                    requestRegeneration()
                }
                .disabled(!canUseToolbarMagicWand)
                .opacity(canUseToolbarMagicWand ? 1 : 0.4)
                .appCoachAnchor(.diaryRegenerate)
            }

            // 已写好的日记也能删除：删除会同时清掉完成状态。
            HeaderIconButton(
                systemImage: "trash",
                accessibilityLabel: String(localized: "删除日记")
            ) {
                dismissKeyboard()
                showClearDiaryConfirm = true
            }
            .disabled(!hasDiaryToClear || isWriting || isGenerating)
            .opacity(hasDiaryToClear && !isWriting && !isGenerating ? 1 : 0.4)
        }
    }

    /// Face in use: a Pro face shows as the free default while Pro is inactive.
    private var handwriting: DiaryHandwriting {
        storedHandwriting.resolved(isPro: subscription.isProUser)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PaperTextureBackground()

                DiaryNotebookArchiveView(isOpen: isArchivingPage || isPageArchived)
                    .opacity(isArchivingPage || isPageArchived ? 1 : 0)
                    .scaleEffect(isArchivingPage || isPageArchived ? 1 : 0.86)
                    .offset(y: isArchivingPage || isPageArchived ? 246 : 300)
                    .animation(.spring(response: 0.55, dampingFraction: 0.82), value: isArchivingPage || isPageArchived)

                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        // Title + week strip collapse while typing to give the
                        // editor room; the style controls stay in one place.
                        if !isEditorFocused {
                            VStack(spacing: 0) {
                                StickerPageHeader(
                                    title: diaryHeaderTitle,
                                    subtitle: diaryHeaderSubtitle,
                                    closeSystemImage: "chevron.left",
                                    onClose: closeDiaryPage,
                                    titleFont: diaryHeaderTitleFont
                                ) {
                                    diaryHeaderActions
                                }
                                .padding(.horizontal, 24)
                                .padding(.top, 54)
                                .padding(.bottom, 14)

                                diaryWeekStrip
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 12)
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if !isDiaryFinished {
                        HStack(spacing: 10) {
                            diaryStyleControls
                            if isEditorFocused {
                                Button("完成") {
                                    dismissKeyboard()
                                }
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.48, green: 0.25, blue: 0.17))
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(.white.opacity(0.72), in: Capsule())
                                .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, isEditorFocused ? 8 : 0)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                        }

                        if showPaperColorPicker {
                            paperColorPickerOverlay
                                .padding(.horizontal, 20)
                                .padding(.bottom, 8)
                        }

                        if showFontPicker {
                            fontPickerOverlay
                                .padding(.horizontal, 20)
                                .padding(.bottom, 8)
                        }

                        if let floatingPrompt {
                            floatingPromptCard(floatingPrompt)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 8)
                        }

                        if isRichLayoutMode, !isWriting, !isArchivingPage, !isDiaryFinished {
                            richStickerToolbar(mode: .inline)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 8)
                        }
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id(diaryTopID)

                            if isGenerating || generationError != nil {
                                diaryGenerationStatus
                                    .padding(.horizontal, 20)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                                    .frame(minHeight: 520)
                            } else {
                                Group {
                                    if isEmptyDiaryState {
                                        emptyDiaryPaperContent
                                    } else if isRichLayoutMode {
                                        richLayoutContent
                                            .padding(.horizontal, layoutStyle.contentHorizontalPadding)
                                            .padding(.vertical, 34)
                                            .appCoachAnchor(.diaryGenerate)
                                    } else {
                                        VStack(alignment: .leading, spacing: 26) {
                                            ForEach(Array(editableEntries.enumerated()), id: \.element.id) { index, item in
                                                DiaryEntryRow(
                                                    entry: editableEntryBinding(index: index, fallback: item),
                                                    showSticker: visibleStickerCount > index,
                                                    layoutStyle: layoutStyle,
                                                    index: index,
                                                    isGenerating: activeGenerationStickerIndex == index,
                                                    animationStopToken: generationAnimationStopToken,
                                                    isEditable: !isWriting && !isArchivingPage && !isDiaryFinished,
                                                    isStickerEditable: isStickerLayoutMode && !isWriting && !isArchivingPage && !isDiaryFinished,
                                                    onStickerDragBegan: beginDiaryDeleteDrag,
                                                    onStickerDragChanged: { point in
                                                        updateDiaryDeleteTarget(for: point, in: geo.size)
                                                    },
                                                    onStickerDragEnded: { point in
                                                        let shouldDelete = diaryDeleteZoneFrame(in: geo.size).contains(point)
                                                        if shouldDelete {
                                                            deleteDiarySticker(at: index)
                                                        }
                                                        hideDiaryDeleteTarget()
                                                        return shouldDelete
                                                    },
                                                    onFocusChange: { focused in
                                                        if focused {
                                                            autoFocusBlankEntry = false
                                                            enterEditorFullscreen()
                                                        } else {
                                                            saveImmediately()
                                                            scheduleEditorFullscreenExit()
                                                        }
                                                    },
                                                    onTextChange: {
                                                        scheduleAutosave()
                                                    },
                                                    hadSticker: originalHadSticker.contains(index),
                                                    autoFocus: index == 0 && autoFocusBlankEntry,
                                                    dateStickerOptions: dateStickerOptions,
                                                    onAddSticker: {
                                                        onCaptureForDate(selectedDate)
                                                    },
                                                    onStickerTap: {
                                                        previewDiarySticker(at: index)
                                                    },
                                                    onDeleteEntry: {
                                                        deleteDiaryEntry(at: index)
                                                    },
                                                    canDeleteEntry: editableEntries.count > 1,
                                                    paperColor: paperColor,
                                                    placeholder: writingPlaceholder(for: index),
                                                    showsPlaceholder: index == placeholderEntryIndex
                                                )
                                                .id(diaryRowID(for: index))
                                                .background {
                                                    // The page may already hold entries when the tour
                                                    // reaches this step (e.g. the hand-written English
                                                    // page); point at the first paragraph then.
                                                    if index == 0 {
                                                        Color.clear.appCoachAnchor(.diaryGenerate)
                                                    }
                                                }
                                            }

                                            // Add new paragraph button
                                            if !editableEntries.isEmpty && !isWriting && !isArchivingPage && !isDiaryFinished {
                                                HStack(spacing: 8) {
                                                    Image(systemName: "plus")
                                                        .font(.system(size: 14, weight: .bold))
                                                    Text("添加段落")
                                                        .font(DiaryFont.display(size: 14, weight: .bold))
                                                }
                                                .foregroundStyle(Color(red: 0.52, green: 0.46, blue: 0.40))
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 44)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                        .stroke(Color(red: 0.52, green: 0.46, blue: 0.40).opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                                                )
                                                .contentShape(Rectangle())
                                                .onTapGesture {
                                                    addNewDiaryEntry()
                                                }
                                            }

                                            Color.clear
                                                .frame(height: 8)
                                                .id(diaryBottomID)
                                        }
                                        .padding(.horizontal, layoutStyle.contentHorizontalPadding)
                                        .padding(.vertical, 34)
                                    }
                                }
                                .allowsHitTesting(!isDiaryFinished)
                                .background(alignment: .top) {
                                    DiaryPaper(style: paperStyle, colorTheme: paperColor)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            dismissKeyboard()
                                        }
                                        .opacity(editableEntries.isEmpty ? 0 : 1)
                                }
                                .scaleEffect(isArchivingPage ? 0.42 : 1, anchor: .bottom)
                                .rotationEffect(.degrees(isArchivingPage ? -7 : 0))
                                .offset(x: isArchivingPage ? -18 : 0, y: isArchivingPage ? 220 : 0)
                                .opacity(isPageArchived ? 0 : 1)
                                .animation(.interpolatingSpring(stiffness: 130, damping: 14), value: isArchivingPage)
                                .animation(.easeInOut(duration: 0.18), value: isPageArchived)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 34)
                            }
                        }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if showsFinishToggle {
                                finishDiaryButton
                                    .padding(.top, 6)
                                    .padding(.bottom, 10)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: showsFinishToggle)
                        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: isDiaryFinished)
                        .coordinateSpace(name: "diaryScroll")
                        .id(diaryScrollViewID)
                        .scrollDisabled(isEmptyDiaryState)
                        .scrollDismissesKeyboard(.interactively)
                        .overlay {
                            // Tapping the page closes an open style picker instead of reaching the page.
                            if showPaperColorPicker || showFontPicker {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { dismissStylePickers() }
                            }
                        }
                        .onChange(of: visibleCharacters) { _, newValue in
                            scrollDuringWritingIfNeeded(newValue, proxy: proxy)
                        }
                        .onChange(of: layoutStyle) { _, newStyle in
                            handleDiaryLayoutStyleChange(newStyle, proxy: proxy)
                        }
                        .onChange(of: diaryScrollResetToken) { _, _ in
                            resetDiaryScroll(proxy: proxy)
                        }
                    }
                }
                .opacity(isPageArchived ? 0.88 : 1)

                if isDiaryDeleteTargetVisible {
                    VStack {
                        Spacer()
                        StickerDeleteTarget(isActive: isDiaryDeleteTargetActive)
                            .frame(width: 172, height: 74)
                            .padding(.bottom, 34)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(5)
                }

                if isPageArchived {
                    VStack(spacing: 12) {
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 44, weight: .semibold))
                        Text("已夹入日记本")
                            .font(DiaryFont.display(size: 20, weight: .bold))
                    }
                    .foregroundStyle(Color(red: 0.32, green: 0.22, blue: 0.17))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
                }
            }
            .background(AppCoachOriginReader())
            .onPreferenceChange(AppCoachOriginPreferenceKey.self) { origin in
                coachGlobalOrigin = origin
            }
            .onPreferenceChange(AppCoachFramePreferenceKey.self) { frames in
                coachFrames = frames
            }
            .overlay { diaryCoachOverlay }
        }
        .task {
            if editableEntries.isEmpty {
                showEntriesImmediately(currentEntries)
            }
        }
        .onChange(of: entries.map(\.id)) { _, _ in
            if generationRevision == lastAnimatedGenerationRevision && !isWriting {
                showEntriesImmediately(currentEntries)
            }
        }
        .onChange(of: generationRevision) { _, _ in
            lastAnimatedGenerationRevision = generationRevision
            saveState = .saved
            setDiaryTitle()
            restartAnimation()
        }
        .onChange(of: isEditorFocused) { _, focused in
            // The strip hides while typing; don't bring it back still expanded.
            if focused { isCalendarExpanded = false }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            retryNetworkRequestAfterReturningFromSettingsIfNeeded()
        }
        .alert("日记还在生成", isPresented: $showCloseDuringGenerationConfirm) {
            Button("继续等待", role: .cancel) {}
            Button("退出", role: .destructive) {
                closeWithoutSavingPartialGeneration()
            }
        } message: {
            Text("现在退出不会保存正在打字的半成品，生成完成后可以再回来查看。")
        }
        .alert("重新生成日记？", isPresented: $showRegenerateConfirm) {
            Button("重新生成", role: .destructive) {
                confirmRegeneration()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会覆盖当前页面里的手写或编辑内容。")
        }
        .alert("删除日记？", isPresented: $showClearDiaryConfirm) {
            Button("删除", role: .destructive) {
                clearDiaryPage()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除这篇日记吗？删除后无法恢复。")
        }
        .alert("贴纸太多啦", isPresented: $showStickerLimitAlert) {
            Button("我知道了", role: .cancel) {}
        } message: {
            Text("一篇日记最多支持 \(Self.maxDiaryStickers) 张贴纸，当前这天有 \(diaryStickerCount) 张。请先删除一些贴纸，再用 AI 写日记。")
        }
        .alert("需要打开网络权限", isPresented: $showNetworkPermissionAlert) {
            Button("去设置") {
                openAppSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("AI 写日记需要访问网络。请在系统设置里允许本 App 使用网络，然后回来重试。")
        }
        .fullScreenCover(isPresented: diaryStickerPreviewPresented) {
            StickerPagerPreview(
                items: diaryStickerPreviewItems,
                selectedID: $previewedDiaryStickerID,
                onClose: {
                    previewedDiaryStickerID = nil
                },
                onDelete: {
                    removePreviewedDiaryStickerUsage()
                }
            )
        }
        .fullScreenCover(item: $diarySharePreviewImage) { image in
            SharePreviewOverlay(
                image: image,
                activeCoachStep: activeCoachStep,
                onCoachCompleteClose: {
                    onCoachAction(.shareComplete)
                },
                watermarkEnabled: $diaryShareWatermark,
                rerender: {
                    let image = diaryShareImage()
                    lastDiaryShareImage = image
                    return image
                }
            ) {
                diarySharePreviewImage = nil
            } onShare: {
                diarySharePreviewImage = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showDiaryShareSheet = true
                }
            }
        }
        .environment(\.diaryFontID, "\(storedHandwriting.rawValue)-\(subscription.isProUser)")
        .onChange(of: storedHandwriting) { _, _ in
            WidgetCenter.shared.reloadAllTimelines()
        }
        .sheet(isPresented: $showDiaryShareSheet) {
            ShareSheetView(items: diaryShareItems)
        }
        .sheet(isPresented: $showSubscriptionFromQuota) {
            SubscriptionSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
                .presentationBackground(.white)
        }
        .sheet(isPresented: $showQuickPromptPicker) {
            QuickPromptPicker { _ in
                // Changing the writing prompt is a free setting. Quota / subscription
                // checks only belong to explicit AI generation actions.
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            .presentationBackground(.white)
        }
        .onDisappear {
            // Leaving for the camera / library etc.: make sure the parent holds
            // the latest text (a pending or disk-only autosave), but never save
            // a half-typed generation.
            if (needsFullSave || saveState == .saving), !isWriting, !isGenerating {
                saveImmediately()
            }
            autosaveTask?.cancel()
            saveStateResetTask?.cancel()
            editorExitTask?.cancel()
        }
    }

    private var emptyDiaryPaperContent: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 80)

            emptyDiaryPrimaryActions

            VStack(spacing: 18) {
                if !dateStickerImages.isEmpty {
                    DiaryStickerPilePreview(images: dateStickerImages)
                        .frame(height: 190)
                        .padding(.top, 4)
                        .padding(.horizontal, 16)
                }
            }
            .frame(height: 218, alignment: .top)

            Spacer(minLength: 80)
        }
        .frame(maxWidth: .infinity, minHeight: 430)
        .padding(.horizontal, 18)
        .padding(.vertical, 34)
    }

    private var emptyDiaryPrimaryActions: some View {
        VStack(spacing: 18) {
            Text("这天还没有日记")
                .font(DiaryFont.display(size: 21, weight: .bold))
                .foregroundStyle(Color(red: 0.52, green: 0.46, blue: 0.40))

            VStack(spacing: 12) {
                emptyDiaryStartButton

                Button {
                    onCaptureForDate(selectedDate)
                } label: {
                    Label("添加贴纸", systemImage: "plus")
                        .font(DiaryFont.display(size: 15))
                        .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))
                        .padding(.horizontal, 20)
                        .frame(height: 42)
                        .background(.white.opacity(0.72), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color(red: 0.34, green: 0.24, blue: 0.18).opacity(0.18), lineWidth: 1)
                        )
                        .proCrownBadge(isStickerPageFull, size: 9)
                }
                .buttonStyle(.plain)
                .disabled(isArchivingPage || isPageArchived)
            }

            // Daily quota hint
            if AppFeatures.aiDiary, !dateStickerImages.isEmpty {
                if DailyQuotaManager.isProUser {
                    HStack(spacing: 4) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 10))
                        Text("Pro · 无限生成")
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.95, green: 0.65, blue: 0.12))
                } else {
                    let remaining = DailyQuotaManager.remainingToday
                    Text("今日剩余 \(remaining) 次免费生成")
                        .font(DiaryFont.display(size: 12, weight: .semibold))
                        .foregroundStyle(remaining > 0
                            ? Color(red: 0.58, green: 0.50, blue: 0.44)
                            : Color(red: 0.85, green: 0.35, blue: 0.30))
                }
            }
        }
    }

    private var emptyDiaryStartButton: some View {
        let usesAI = AppFeatures.aiDiary && !dateStickerImages.isEmpty
        return Button {
            startDiaryFromEmptyState()
        } label: {
            Label(usesAI ? "AI写日记" : "开始写日记", systemImage: usesAI ? "wand.and.stars" : "pencil.line")
                .font(DiaryFont.display(size: 17))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 48)
                .background(Color(red: 0.34, green: 0.24, blue: 0.18), in: Capsule())
                .shadow(color: Color(red: 0.34, green: 0.24, blue: 0.18).opacity(0.18), radius: 14, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(isArchivingPage || isPageArchived)
        .appCoachAnchor(.diaryGenerate)
    }

    private func emptyDiaryIconButton(systemImage: String, label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(isEnabled ? Color(red: 0.34, green: 0.24, blue: 0.18) : Color(red: 0.60, green: 0.54, blue: 0.48))
                .frame(width: 48, height: 48)
                .background(.white.opacity(isEnabled ? 0.72 : 0.38), in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color(red: 0.34, green: 0.24, blue: 0.18).opacity(isEnabled ? 0.18 : 0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    private var isRichLayoutMode: Bool {
        layoutStyle == .inlineSticker
    }

    @ViewBuilder
    private var diaryCoachOverlay: some View {
        if let activeCoachStep, isDiaryCoachStep(activeCoachStep) {
            AppCoachOverlay(
                step: activeCoachStep,
                targetFrame: coachFrames[activeCoachStep.target],
                globalOrigin: coachGlobalOrigin,
                onAction: { performDiaryCoachAction(activeCoachStep) },
                onSkip: onCoachSkip
            )
            .transition(.opacity)
            .zIndex(30)
        }
    }

    /// English free plan: this page has no free sticker spots left.
    private var isStickerPageFull: Bool {
        !subscription.isProUser && PageStickerLimit.remaining { dateStickerOptions.count } == 0
    }

    /// Crown hints on the style buttons while some choices need Pro.
    private var hasLockedPaperColors: Bool {
        DiaryPaperColor.allCases.contains { $0.isLocked(isPro: subscription.isProUser) }
    }

    private var hasLockedHandwritings: Bool {
        DiaryHandwriting.available.contains { $0.isLocked(isPro: subscription.isProUser) }
    }

    /// Toolbar item sizing: plain HStack, no scrolling — everything fits one
    /// line even on 375pt-wide phones (English + 完成 button included).
    private var diaryToolButtonWidth: CGFloat { isEditorFocused ? 26 : 30 }
    private var diaryToolSpacing: CGFloat { isEditorFocused ? 2 : 3 }
    private var diaryToolDividerPadding: CGFloat { isEditorFocused ? 0 : 2 }
    private var diaryToolOuterPadding: CGFloat { isEditorFocused ? 2 : 8 }

    private var diaryStyleControls: some View {
        let inactive = Color(red: 0.62, green: 0.58, blue: 0.54)
        let pillBg = Color(red: 0.34, green: 0.24, blue: 0.18)

        return HStack(spacing: diaryToolSpacing) {
                ForEach(DiaryPaperStyle.allCases) { style in
                    let selected = paperStyle == style
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            paperStyle = style
                        }
                    } label: {
                        Image(systemName: style.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? .white : inactive)
                            .frame(width: diaryToolButtonWidth, height: 28)
                            .background(selected ? pillBg : Color.clear, in: Capsule())
                    }
                }

                if !isEditorFocused {
                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, diaryToolDividerPadding)
                }

                // 日记颜色选择按钮
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showFontPicker = false
                        showPaperColorPicker.toggle()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(paperColor.swatch)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5)
                            )
                            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    }
                    .frame(width: diaryToolButtonWidth, height: 28)
                    .proCrownBadge(hasLockedPaperColors)
                }

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showPaperColorPicker = false
                        showFontPicker.toggle()
                    }
                } label: {
                    Text("Aa")
                        .font(DiaryFont.font(size: 16, handwriting: handwriting))
                        .foregroundStyle(showFontPicker ? .white : inactive)
                        .frame(width: diaryToolButtonWidth, height: 28)
                        .background(showFontPicker ? pillBg : Color.clear, in: Capsule())
                        .proCrownBadge(hasLockedHandwritings)
                }
                .accessibilityLabel(String(localized: "手写字体"))

                if !isEditorFocused {
                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, diaryToolDividerPadding)
                }

                ForEach(DiaryLayoutStyle.allCases) { style in
                    let selected = layoutStyle == style
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            if style == .inlineSticker {
                                syncRichContentFromEditableEntries()
                            }
                            layoutStyle = style
                        }
                    } label: {
                        Image(systemName: style.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? .white : inactive)
                            .frame(width: diaryToolButtonWidth, height: 28)
                            .background(selected ? pillBg : Color.clear, in: Capsule())
                    }
                }

                if !isEditorFocused {
                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, diaryToolDividerPadding)
                }

                if AppFeatures.aiDiary {
                    // 提示语快捷切换
                    Button {
                        showQuickPromptPicker = true
                    } label: {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(inactive)
                            .frame(width: diaryToolButtonWidth, height: 28)
                    }
                } else {
                    Button {
                        showNextWritingPrompt()
                    } label: {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(inactive)
                            .frame(width: diaryToolButtonWidth, height: 28)
                    }
                    .accessibilityLabel(String(localized: "换一组写作提示"))
                }
            }
            .padding(.horizontal, 1)
        .padding(.horizontal, diaryToolOuterPadding)
        .padding(.vertical, 6)
        .background(Color(red: 0.92, green: 0.89, blue: 0.85), in: Capsule())
        .disabled(isArchivingPage || isPageArchived)
    }

    private func floatingPromptCard(_ prompt: String) -> some View {
        let ink = Color(red: 0.34, green: 0.24, blue: 0.18)

        return Button {
            hideFloatingPrompt()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.95, green: 0.65, blue: 0.12))
                Text(prompt)
                    .font(DiaryFont.font(size: 17))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(prompt)
                    .transition(.opacity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
    }

    /// Lightbulb: swap the placeholder of empty paragraphs, or, when every
    /// paragraph already has text (or in the inline layout), show a prompt card.
    private func showNextWritingPrompt() {
        if !isRichLayoutMode, placeholderEntryIndex != nil {
            withAnimation(.easeInOut(duration: 0.2)) {
                writingPromptShuffle += 1
            }
            return
        }

        dismissStylePickers()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            writingPromptShuffle += 1
            floatingPrompt = WritingPrompts.prompt(for: selectedDate, index: 0, shuffle: writingPromptShuffle)
        }
        floatingPromptHideTask?.cancel()
        floatingPromptHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            hideFloatingPrompt()
        }
    }

    private func hideFloatingPrompt() {
        floatingPromptHideTask?.cancel()
        floatingPromptHideTask = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            floatingPrompt = nil
        }
    }

    private var paperColorPickerOverlay: some View {
        let rows = [
            Array(DiaryPaperColor.allCases.prefix(5)),
            Array(DiaryPaperColor.allCases.dropFirst(5))
        ]

        return VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    ForEach(row) { color in
                        paperColorButton(color)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        )
        .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
    }

    private var fontPickerOverlay: some View {
        let ink = Color(red: 0.34, green: 0.24, blue: 0.18)

        return VStack(spacing: 2) {
            ForEach(DiaryHandwriting.available) { face in
                let isLocked = face.isLocked(isPro: subscription.isProUser)
                Button {
                    guard !isLocked else {
                        showFontPicker = false
                        showSubscriptionFromQuota = true
                        return
                    }
                    storedHandwriting = face
                    dismissStylePickersAfterSelection()
                } label: {
                    HStack(spacing: 10) {
                        Text(face.displayName)
                            .font(DiaryFont.font(size: 19, handwriting: face))
                            .foregroundStyle(ink.opacity(isLocked ? 0.55 : 1))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if handwriting == face {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(ink)
                        } else if isLocked {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Color(red: 0.95, green: 0.65, blue: 0.12), in: Circle())
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(
                        handwriting == face ? ink.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        )
        .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
    }

    private func paperColorButton(_ color: DiaryPaperColor) -> some View {
        let isLocked = color.isLocked(isPro: subscription.isProUser)
        return Button {
            guard !isLocked else {
                showPaperColorPicker = false
                showSubscriptionFromQuota = true
                return
            }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                selectedPaperColor = color
            }
            dismissStylePickersAfterSelection()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(color.swatch)
                        .frame(width: 38, height: 38)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    paperColor == color
                                        ? Color(red: 0.34, green: 0.24, blue: 0.18)
                                        : Color.black.opacity(0.08),
                                    lineWidth: paperColor == color ? 2.5 : 1
                                )
                        )
                        .shadow(color: .black.opacity(0.06), radius: 3, y: 2)

                    if paperColor == color {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))
                    } else if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(color.inkColor.opacity(0.55))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isLocked {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color(red: 0.95, green: 0.65, blue: 0.12), in: Circle())
                            .offset(x: 5, y: -5)
                    }
                }

                Text(color.title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.52, green: 0.46, blue: 0.42))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .multilineTextAlignment(.center)
                    .frame(width: 44, height: 24, alignment: .top)
            }
            .frame(width: 46, height: 67, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var diaryGenerationStatus: some View {
        Group {
            if isGenerating {
                diaryGenerationWaitingView
            } else {
                HStack(spacing: 12) {
                    let isQuotaExhausted = !DailyQuotaManager.canGenerate
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.34, green: 0.24, blue: 0.18).opacity(0.10))
                            .frame(width: 38, height: 38)

                        Image(systemName: isQuotaExhausted ? "cup.and.saucer" : (needsNetworkPermissionRecovery ? "wifi.exclamationmark" : "arrow.clockwise"))
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isQuotaExhausted ? "今日额度已用完" : (needsNetworkPermissionRecovery ? "需要网络权限" : "生成没有完成"))
                            .font(DiaryFont.display(size: 15))
                            .foregroundStyle(Color(red: 0.30, green: 0.22, blue: 0.17))

                        Text(isQuotaExhausted ? String(localized: "每天 \(DailyQuotaManager.maxFreeGenerations) 次免费额度已用完，你也可以手动写日记") : (needsNetworkPermissionRecovery ? String(localized: "允许无线数据后，再让 AI 继续写日记") : (generationError ?? String(localized: "生成遇到问题，请重试"))))
                            .font(DiaryFont.display(size: 12, weight: .semibold))
                            .foregroundStyle(Color(red: 0.58, green: 0.50, blue: 0.44))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    if !isQuotaExhausted {
                        Button {
                            attemptRegeneration(confirmIfNeeded: false)
                        } label: {
                            Text(needsNetworkPermissionRecovery ? "去设置" : "重试")
                                .font(DiaryFont.display(size: 13))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(height: 34)
                                .background(Color(red: 0.34, green: 0.24, blue: 0.18), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.72), lineWidth: 1)
                }
                .shadow(color: Color(red: 0.34, green: 0.24, blue: 0.18).opacity(0.10), radius: 16, y: 8)
                .onTapGesture {
                    attemptRegeneration(confirmIfNeeded: false)
                }
            }
        }
    }

    @State private var generationPulse = false

    private var diaryGenerationWaitingView: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 60)

            Image("StickerDiary")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .rotationEffect(.degrees(generationPulse ? -3 : 3))
                .scaleEffect(generationPulse ? 1.06 : 0.96)
                .shadow(color: Color(red: 0.73, green: 0.43, blue: 0.17).opacity(0.22), radius: generationPulse ? 18 : 8, y: generationPulse ? 8 : 4)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: generationPulse)

            VStack(spacing: 8) {
                Text("正在写日记...")
                    .font(DiaryFont.display(size: 18, weight: .bold))
                    .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))

                Text("AI 正在根据你的贴纸生成今天的日记")
                    .font(DiaryFont.display(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.58, green: 0.52, blue: 0.46))
            }
            .opacity(generationPulse ? 1 : 0.7)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: generationPulse)

            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color(red: 0.73, green: 0.43, blue: 0.17))
                        .frame(width: 7, height: 7)
                        .scaleEffect(generationPulse ? 1.0 : 0.5)
                        .opacity(generationPulse ? 1 : 0.3)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.2),
                            value: generationPulse
                        )
                }
            }

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .onAppear { generationPulse = true }
        .onDisappear {
            var t = Transaction(animation: nil)
            t.disablesAnimations = true
            withTransaction(t) { generationPulse = false }
        }
    }

    private var diaryWeekStrip: some View {
        DiaryCalendarStrip(
            selectedDate: selectedDate,
            markedDays: DiaryCalendarStrip.diaryDays(in: records),
            isExpanded: $isCalendarExpanded,
            collapsesOnSelect: true
        ) { date in
            switchToDate(date)
        }
    }

    /// Diary dates use the chosen handwriting face.
    private var diaryHeaderTitleFont: Font? {
        DiaryFont.font(size: 36, handwriting: handwriting)
    }

    private var diaryHeaderTitle: String {
        AppLocale.string(from: selectedDate, chinese: "M月d日", template: "MMMd")
    }

    private var displayedDiaryTitle: String {
        diaryHeaderTitle
    }

    private func storedDiaryTitle(for date: Date) -> String? {
        nil
    }

    private func setDiaryTitle(_ preferredTitle: String? = nil) {
        diaryCustomTitle = diaryHeaderTitle
    }

    private var diaryHeaderSubtitle: String {
        if isDiaryFinished { return String(localized: "已写好") }
        switch saveState {
        case .saving:
            return String(localized: "保存中")
        case .saved:
            return String(localized: "已保存")
        case .idle:
            return hasEditableDiaryContent ? String(localized: "已保存") : String(localized: "未保存")
        }
    }

    private var diaryStickerPreviewPresented: Binding<Bool> {
        Binding(
            get: { previewedDiaryStickerID != nil && !diaryStickerPreviewItems.isEmpty },
            set: { isPresented in
                if !isPresented {
                    previewedDiaryStickerID = nil
                }
            }
        )
    }

    private var diaryStickerPreviewItems: [RecentStickerPreview] {
        editableEntries.indices.compactMap { index in
            guard let image = editableEntries[index].sticker else { return nil }
            return RecentStickerPreview(
                entry: StickerEntry(
                    id: diaryStickerPreviewID(for: index),
                    title: String(localized: "日记贴纸"),
                    subtitle: String(localized: "当前日记使用中"),
                    timestamp: selectedDate.timeIntervalSince1970
                ),
                image: image
            )
        }
    }

    private func diaryStickerPreviewID(for index: Int) -> String {
        "diary-sticker-\(selectedDayID)-\(index)"
    }

    private func previewDiarySticker(at index: Int) {
        guard editableEntries.indices.contains(index), editableEntries[index].sticker != nil else { return }
        dismissKeyboard()
        previewedDiaryStickerID = diaryStickerPreviewID(for: index)
    }

    private func removePreviewedDiaryStickerUsage() {
        guard let previewedDiaryStickerID,
              let index = diaryStickerIndex(fromPreviewID: previewedDiaryStickerID) else { return }

        deleteDiarySticker(at: index)
        self.previewedDiaryStickerID = nil
    }

    private func diaryStickerIndex(fromPreviewID id: String) -> Int? {
        guard id.hasPrefix("diary-sticker-\(selectedDayID)-"),
              let suffix = id.split(separator: "-").last,
              let index = Int(suffix),
              editableEntries.indices.contains(index),
              editableEntries[index].sticker != nil else {
            return nil
        }
        return index
    }

    /// Reuses the image rendered for the preview instead of drawing it again.
    private var diaryShareItems: [Any] {
        [lastDiaryShareImage ?? diaryShareImage()]
    }

    private func diaryBlockText(for entry: DiaryEntry) -> String {
        joinedDiaryText(title: entry.title, text: entry.text)
    }

    private var diaryShareText: String {
        let body = editableEntries
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        guard !body.isEmpty else {
            return displayedDiaryTitle
        }

        return "\(displayedDiaryTitle)\n\n\(body)"
    }

    // MARK: Share image
    //
    // Drawn in the editor's own point space (the on-screen paper is the screen
    // width minus 20pt margins) and exported at 3x, so fonts, sticker sizes and
    // paper pattern spacing all match what the user sees while editing.

    private static let sharePaperWidth: CGFloat = 362
    private static let shareMinPaperHeight: CGFloat = 560
    private static let shareVerticalPadding: CGFloat = 34
    private static let shareTitleSpacing: CGFloat = 18
    private static let shareWatermarkHeight: CGFloat = 52
    private static let shareEntrySpacing: CGFloat = 26

    private func diaryShareImage() -> UIImage {
        let paperWidth = Self.sharePaperWidth
        let contentX = layoutStyle.contentHorizontalPadding
        let contentWidth = paperWidth - contentX * 2

        let titleAttributes = shareTitleAttributes
        let titleHeight = shareTextHeight(displayedDiaryTitle, width: contentWidth, attributes: titleAttributes)

        let contentHeight: CGFloat
        switch layoutStyle {
        case .classic:
            contentHeight = shareClassicContentHeight(width: contentWidth)
        case .timeline:
            contentHeight = shareTimelineContentHeight(width: contentWidth)
        case .inlineSticker:
            contentHeight = shareInlineContentHeight(width: contentWidth)
        }

        let showsWatermark = diaryShareWatermark
        let bottomHeight = showsWatermark ? Self.shareWatermarkHeight + 18 : Self.shareVerticalPadding
        let paperHeight = max(
            Self.shareMinPaperHeight,
            ceil(Self.shareVerticalPadding + titleHeight + Self.shareTitleSpacing + contentHeight + bottomHeight)
        )
        let size = CGSize(width: paperWidth, height: paperHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size)
            sharePaperBackgroundColor.setFill()
            context.fill(rect)
            drawSharePaperPattern(in: rect, context: context.cgContext)

            var y = Self.shareVerticalPadding
            NSAttributedString(string: displayedDiaryTitle, attributes: titleAttributes)
                .draw(in: CGRect(x: contentX, y: y, width: contentWidth, height: titleHeight))
            y += titleHeight + Self.shareTitleSpacing

            let origin = CGPoint(x: contentX, y: y)
            switch layoutStyle {
            case .classic:
                drawShareClassicContent(at: origin, width: contentWidth, context: context.cgContext)
            case .timeline:
                drawShareTimelineContent(at: origin, width: contentWidth, context: context.cgContext)
            case .inlineSticker:
                drawShareInlineContent(at: origin, width: contentWidth)
            }

            if showsWatermark {
                drawShareWatermark(in: CGRect(
                    x: 0,
                    y: rect.maxY - Self.shareWatermarkHeight - 8,
                    width: rect.width,
                    height: Self.shareWatermarkHeight
                ))
            }
        }
    }

    /// App icon plus "Sticker Diary", centered at the bottom of the page.
    private func drawShareWatermark(in rect: CGRect) {
        let iconSize: CGFloat = 22
        let spacing: CGFloat = 7
        let label = NSAttributedString(string: String(localized: "贴纸日记"), attributes: [
            .font: UIFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: paperColor.uiInkColor.withAlphaComponent(0.5)
        ])
        let labelSize = label.size()
        let icon = UIImage(named: "BrandAppIcon")
        let totalWidth = (icon == nil ? 0 : iconSize + spacing) + labelSize.width
        var x = rect.midX - totalWidth / 2

        if let icon {
            let iconRect = CGRect(x: x, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize)
            let path = UIBezierPath(roundedRect: iconRect, cornerRadius: iconSize * 0.225)
            UIGraphicsGetCurrentContext()?.saveGState()
            path.addClip()
            icon.draw(in: iconRect)
            UIGraphicsGetCurrentContext()?.restoreGState()
            UIColor.black.withAlphaComponent(0.06).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            x += iconSize + spacing
        }
        label.draw(at: CGPoint(x: x, y: rect.midY - labelSize.height / 2))
    }

    /// Same face and size as the date in the editor header.
    private var shareTitleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: DiaryFont.uiFont(size: 36, handwriting: handwriting),
            .foregroundColor: paperColor.uiInkColor
        ]
    }

    /// Matches `DiaryTextView` for the classic and timeline layouts.
    private var shareBodyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = layoutStyle.lineSpacing
        return [
            .font: DiaryFont.uiFont(size: layoutStyle.textSize),
            .foregroundColor: paperColor.uiInkColor,
            .paragraphStyle: paragraph
        ]
    }

    private var sharePaperBackgroundColor: UIColor {
        paperColor.uiBackground
    }

    private func shareTextHeight(_ text: String, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes)
        return ceil(attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
    }

    /// Same spacing as `DiaryPaperStyle.patternView` / `DiaryPaper`.
    private func drawSharePaperPattern(in rect: CGRect, context: CGContext) {
        let patternUI = UIColor(paperColor.patternColor)
        switch paperStyle {
        case .lined:
            context.setStrokeColor(patternUI.cgColor)
            context.setLineWidth(1)
            let spacing: CGFloat = 28
            var y = rect.minY + 46
            while y < rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y + 0.5))
                context.addLine(to: CGPoint(x: rect.maxX, y: y + 0.5))
                y += spacing
            }
            context.strokePath()
        case .grid:
            let spacing: CGFloat = 23
            context.setLineWidth(1)
            context.setStrokeColor(patternUI.withAlphaComponent(0.75).cgColor)
            var y = rect.minY + spacing
            while y < rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y.rounded() + 0.5))
                context.addLine(to: CGPoint(x: rect.maxX, y: y.rounded() + 0.5))
                y += spacing
            }
            context.strokePath()
            context.setStrokeColor(patternUI.withAlphaComponent(0.62).cgColor)
            var x = rect.minX + spacing
            while x < rect.maxX {
                context.move(to: CGPoint(x: x.rounded() + 0.5, y: rect.minY))
                context.addLine(to: CGPoint(x: x.rounded() + 0.5, y: rect.maxY))
                x += spacing
            }
            context.strokePath()
        case .dotted:
            context.setFillColor(patternUI.cgColor)
            let spacing: CGFloat = 21
            let dotSize: CGFloat = 3
            var y = rect.minY + spacing
            while y < rect.maxY {
                var x = rect.minX + spacing
                while x < rect.maxX {
                    context.fillEllipse(in: CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize))
                    x += spacing
                }
                y += spacing
            }
        }
        if paperStyle.showsMarginLine {
            context.setFillColor(UIColor(paperColor.accentColor).withAlphaComponent(0.18).cgColor)
            context.fill(CGRect(x: rect.minX + 48, y: rect.minY, width: 2, height: rect.height))
        }
    }

    /// Entries drawn in the share image: blank paragraphs (e.g. the empty
    /// trailing one) are left out, matching how the page looks on screen.
    private var shareEntries: [(index: Int, entry: EditableDiaryEntry)] {
        let entries = editableEntries.enumerated().filter { _, entry in
            entry.sticker != nil || !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { (index: $0.offset, entry: $0.element) }
        return entries.isEmpty ? editableEntries.prefix(1).map { (index: 0, entry: $0) } : entries
    }

    private var shareHasAnyText: Bool {
        editableEntries.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // Classic row (see `DiaryEntryRow.classicLayout`): 112pt sticker beside the
    // text, 14pt gap, text box at least `editorMinHeight`, row at least 132pt.
    private static let shareClassicStickerSize: CGFloat = 112
    private static let shareClassicGap: CGFloat = 14

    private func shareClassicRowMetrics(for entry: EditableDiaryEntry, width: CGFloat) -> (textWidth: CGFloat, textBox: CGFloat, row: CGFloat) {
        let hasSticker = entry.sticker != nil
        let textWidth = hasSticker ? width - Self.shareClassicStickerSize - Self.shareClassicGap : width
        let textHeight = shareTextHeight(shareShareableText(for: entry), width: textWidth, attributes: shareBodyAttributes)
        let textBox = max(layoutStyle.editorMinHeight, textHeight)
        let row = max(132, textBox, hasSticker ? Self.shareClassicStickerSize : 0)
        return (textWidth, textBox, row)
    }

    private func shareClassicContentHeight(width: CGFloat) -> CGFloat {
        let entries = shareEntries
        let rows = entries.reduce(CGFloat.zero) { $0 + shareClassicRowMetrics(for: $1.entry, width: width).row }
        return rows + CGFloat(max(0, entries.count - 1)) * Self.shareEntrySpacing
    }

    private func drawShareClassicContent(at origin: CGPoint, width: CGFloat, context: CGContext) {
        var y = origin.y
        for item in shareEntries {
            let entry = item.entry
            let metrics = shareClassicRowMetrics(for: entry, width: width)
            let stickerSize = Self.shareClassicStickerSize
            let stickerOnLeft = entry.stickerSide == .left
            let hasSticker = entry.sticker != nil
            let textX = origin.x + (hasSticker && stickerOnLeft ? stickerSize + Self.shareClassicGap : 0)
            let textY = y + (metrics.row - metrics.textBox) / 2

            NSAttributedString(string: shareShareableText(for: entry), attributes: shareBodyAttributes).draw(
                with: CGRect(x: textX, y: textY, width: metrics.textWidth, height: metrics.textBox),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )

            if let sticker = entry.sticker {
                let stickerX = origin.x + (stickerOnLeft ? 0 : width - stickerSize)
                drawShareSticker(
                    sticker,
                    in: CGRect(x: stickerX, y: y + (metrics.row - stickerSize) / 2, width: stickerSize, height: stickerSize),
                    rotation: stickerOnLeft ? -5 : 5,
                    entry: entry,
                    context: context
                )
            }
            y += metrics.row + Self.shareEntrySpacing
        }
    }

    // Timeline row (see `DiaryEntryRow.timelineLayout`): 11pt dot and 118pt
    // rule, 16pt gap, text then a 104pt sticker on the trailing edge.
    private static let shareTimelineRailWidth: CGFloat = 11
    private static let shareTimelineGap: CGFloat = 16
    private static let shareTimelineStickerSize: CGFloat = 104

    private func shareTimelineRowMetrics(for entry: EditableDiaryEntry, width: CGFloat) -> (textWidth: CGFloat, textBox: CGFloat, row: CGFloat) {
        let textWidth = width - Self.shareTimelineRailWidth - Self.shareTimelineGap
        let textHeight = shareTextHeight(shareShareableText(for: entry), width: textWidth, attributes: shareBodyAttributes)
        let textBox = max(layoutStyle.editorMinHeight, textHeight)
        let stickerBlock = entry.sticker == nil ? 0 : 12 + Self.shareTimelineStickerSize
        return (textWidth, textBox, max(170, textBox + stickerBlock))
    }

    private func shareTimelineContentHeight(width: CGFloat) -> CGFloat {
        let entries = shareEntries
        let rows = entries.reduce(CGFloat.zero) { $0 + shareTimelineRowMetrics(for: $1.entry, width: width).row }
        return rows + CGFloat(max(0, entries.count - 1)) * Self.shareEntrySpacing
    }

    private func drawShareTimelineContent(at origin: CGPoint, width: CGFloat, context: CGContext) {
        var y = origin.y
        let rail = Self.shareTimelineRailWidth
        let textX = origin.x + rail + Self.shareTimelineGap
        let accent = UIColor(red: 0.74, green: 0.38, blue: 0.25, alpha: 1)

        for item in shareEntries {
            let entry = item.entry
            let metrics = shareTimelineRowMetrics(for: entry, width: width)

            accent.withAlphaComponent(0.55).setFill()
            UIBezierPath(ovalIn: CGRect(x: origin.x, y: y + 8, width: rail, height: rail)).fill()
            accent.withAlphaComponent(0.18).setFill()
            UIBezierPath(rect: CGRect(x: origin.x + rail / 2 - 1, y: y + 8 + rail + 8, width: 2, height: 118)).fill()

            NSAttributedString(string: shareShareableText(for: entry), attributes: shareBodyAttributes).draw(
                with: CGRect(x: textX, y: y, width: metrics.textWidth, height: metrics.textBox),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )

            if let sticker = entry.sticker {
                let size = Self.shareTimelineStickerSize
                drawShareSticker(
                    sticker,
                    in: CGRect(x: origin.x + width - size, y: y + metrics.textBox + 12, width: size, height: size),
                    rotation: item.index % 2 == 0 ? -4 : 5,
                    entry: entry,
                    context: context
                )
            }
            y += metrics.row + Self.shareEntrySpacing
        }
    }

    /// Draws a sticker with the same tilt, pinch scale, drag offset and drop
    /// shadow as `DiaryEntryRow.stickerView`.
    private func drawShareSticker(_ image: UIImage, in rect: CGRect, rotation: Double, entry: EditableDiaryEntry, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.midX + entry.stickerOffset.width, y: rect.midY + entry.stickerOffset.height)
        context.rotate(by: rotation * .pi / 180)
        context.scaleBy(x: entry.stickerScale, y: entry.stickerScale)
        context.setShadow(offset: CGSize(width: 0, height: 5), blur: 10, color: UIColor.black.withAlphaComponent(0.18).cgColor)
        let local = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
        image.draw(in: aspectFitRect(for: image, in: local))
        context.restoreGState()
    }

    // Inline layout mirrors `InlineStickerTextView`: 17pt text, 8pt line
    // spacing, stickers 1.6 line heights tall, 8/4pt text insets.
    private static let shareInlineInsets = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)

    private func shareInlineContentHeight(width: CGFloat) -> CGFloat {
        let insets = Self.shareInlineInsets
        let attributed = shareInlineAttributedText()
        let textHeight = ceil(attributed.boundingRect(
            with: CGSize(width: width - insets.left - insets.right, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
        return textHeight + insets.top + insets.bottom
    }

    private func drawShareInlineContent(at origin: CGPoint, width: CGFloat) {
        let insets = Self.shareInlineInsets
        let attributed = shareInlineAttributedText()
        attributed.draw(
            with: CGRect(
                x: origin.x + insets.left,
                y: origin.y + insets.top,
                width: width - insets.left - insets.right,
                height: shareInlineContentHeight(width: width)
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
    }

    private func shareInlineAttributedText() -> NSAttributedString {
        let content = inlineContentFromEntries()
        let text = content.text
        let fontSize: CGFloat = 17
        let result = NSMutableAttributedString(
            string: text.isEmpty ? String(localized: "今天还没有写下文字。") : text,
            attributes: richDiaryBaseAttrs(fontSize: fontSize, lineSpacing: 8)
        )
        let font = richDiaryFont(size: fontSize)
        let stickerSize = font.lineHeight * 1.6
        let insertions = text.isEmpty ? [] : content.insertions

        for insertion in insertions.sorted(by: { $0.characterIndex > $1.characterIndex }) {
            let attachment = NSTextAttachment()
            attachment.image = resizeStickerImage(insertion.image, to: CGSize(width: stickerSize, height: stickerSize))
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - stickerSize) / 2 - 2, width: stickerSize, height: stickerSize)
            result.insert(NSAttributedString(attachment: attachment), at: min(insertion.characterIndex, result.length))
        }
        return result
    }

    private func shareShareableText(for entry: EditableDiaryEntry) -> String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The placeholder only stands in for a page with no writing at all.
        return text.isEmpty && !shareHasAnyText ? String(localized: "今天还没有写下文字。") : text
    }

    private func closeDiaryPage() {
        if isWriting || isGenerating {
            dismissKeyboard()
            showCloseDuringGenerationConfirm = true
            return
        }
        saveImmediately()
        dismissKeyboard()
        onClose()
    }

    private var finishDiaryButton: some View {
        let finished = isDiaryFinished
        let ink = Color(red: 0.22, green: 0.15, blue: 0.12)
        return Button(action: finished ? continueEditingDiary : finishDiary) {
            Label(finished ? String(localized: "继续编辑") : String(localized: "写好了"),
                  systemImage: finished ? "pencil" : "checkmark")
                .font(DiaryFont.display(size: 17))
                .foregroundStyle(finished ? ink : .white)
                .lineLimit(1)
                .padding(.horizontal, 32)
                .frame(height: 52)
                .background(finished ? Color.white : ink, in: Capsule())
                .overlay(Capsule().stroke(ink.opacity(finished ? 0.12 : 0), lineWidth: 1))
                .shadow(color: .black.opacity(finished ? 0.08 : 0.16), radius: 12, y: 6)
                .contentTransition(.opacity)
        }
        .buttonStyle(.plain)
    }

    /// Saves and locks the page; the parent checks achievements.
    private func finishDiary() {
        guard showsFinishToggle, !isDiaryFinished else { return }
        dismissStylePickers()
        saveImmediately()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        setDiaryFinished(true)
        onFinish(selectedDate)
    }

    private func continueEditingDiary() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        setDiaryFinished(false)
    }

    private func setDiaryFinished(_ finished: Bool, for dayID: String? = nil) {
        let id = dayID ?? selectedDayID
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            if finished { finishedDayIDs.insert(id) } else { finishedDayIDs.remove(id) }
        }
        DiaryFinishedDays.save(finishedDayIDs)
    }

    private func closeWithoutSavingPartialGeneration() {
        autosaveTask?.cancel()
        needsFullSave = false
        saveState = .idle
        isWriting = false
        activeGenerationStickerIndex = nil
        generationAnimationStopToken += 1
        dismissKeyboard()
        onClose()
    }

    private func shareDiary() {
        dismissKeyboard()
        saveImmediately()
        let image = diaryShareImage()
        lastDiaryShareImage = image
        diarySharePreviewImage = image
    }

    private func performDiaryShareAction() {
        shareDiary()
        if activeCoachStep == .diaryShare {
            onCoachAction(.diaryShare)
        }
    }

    private func performDiaryCoachAction(_ step: AppCoachStep) {
        switch step {
        case .diaryGenerate:
            if isEmptyDiaryState {
                startDiaryFromEmptyState()
            } else if !AppFeatures.aiDiary {
                if isRichLayoutMode {
                    richFocusRequest += 1
                } else {
                    autoFocusBlankEntry = true
                }
            } else {
                startDiaryFromEmptyState()
            }
            if !AppFeatures.aiDiary {
                onCoachAction(step)
            }
        case .diaryRegenerate:
            onCoachAction(step)
        case .diaryShare:
            performDiaryShareAction()
        default:
            onCoachAction(step)
        }
    }

    private func isDiaryCoachStep(_ step: AppCoachStep) -> Bool {
        step == .diaryGenerate || step == .diaryShare || step == .diaryRegenerate
    }

    // MARK: - Rich Layout (inline / wrap) combined content

    private func initializeRichContent() {
        guard !richContentInitialized else { return }
        syncRichContentFromEditableEntries()
    }

    private func rebuildRichContentIfNeeded() {
        richContentInitialized = false
        richCombinedText = ""
        richInlineInsertions = []
        richBlockEntryIDs = []
        richBlockTexts = []
        richCursorPosition = 0
        richContentRevision += 1

        if isRichLayoutMode {
            initializeRichContent()
        }
    }

    /// Builds the inline editor's content from the paragraph entries.
    ///
    /// Paragraphs are joined with a blank line. Blank paragraphs are hidden in
    /// this layout but stay in `editableEntries`. All offsets are UTF-16.
    private func inlineContentFromEntries() -> (text: String, insertions: [InlineStickerInsertion], blockIDs: [UUID], blockTexts: [String]) {
        var parts: [String] = []
        var ids: [UUID] = []
        var insertions: [InlineStickerInsertion] = []
        var cursor = 0

        for entry in editableEntries {
            let block = entry.text.trimmingCharacters(in: .newlines)
            guard !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let length = (block as NSString).length
            for placement in inlinePlacements(for: entry, blockText: block) {
                insertions.append(InlineStickerInsertion(
                    image: placement.image,
                    characterIndex: cursor + min(max(placement.offset, 0), length),
                    stickerID: placement.stickerID,
                    id: placement.id
                ))
            }
            parts.append(block)
            ids.append(entry.id)
            cursor += length + 2
        }

        return (parts.joined(separator: "\n\n"), Array(insertions.prefix(Self.maxDiaryStickers * 2)), ids, parts)
    }

    private func inlinePlacements(for entry: EditableDiaryEntry, blockText: String) -> [InlineStickerPlacement] {
        if let custom = entry.inlineStickers {
            return custom
        }
        guard let sticker = entry.sticker else { return [] }
        // Reuse the entry ID so the default placement keeps a stable identity.
        return [InlineStickerPlacement(
            id: entry.id,
            stickerID: entry.stickerID,
            image: sticker,
            offset: defaultInlineOffset(for: entry, in: blockText)
        )]
    }

    private func defaultInlineOffset(for entry: EditableDiaryEntry, in block: String) -> Int {
        let text = block as NSString
        if let anchor = entry.inlineAnchor?.trimmingCharacters(in: .whitespacesAndNewlines), !anchor.isEmpty {
            let range = text.range(of: anchor, options: .caseInsensitive)
            if range.location != NSNotFound {
                return range.location + range.length
            }
            // The model sometimes adds an adjective that isn't in the text
            // ("curious kitten" for "little orange kitten"). Fall back to its
            // words from the last one (usually the noun), as whole words.
            for word in anchor.split(separator: " ").reversed() where word.count >= 3 {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: String(word)) + "\\b"
                let wordRange = text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
                if wordRange.location != NSNotFound {
                    return wordRange.location + wordRange.length
                }
            }
        }
        let firstBreak = text.range(of: "\n")
        return firstBreak.location == NSNotFound ? text.length : min(firstBreak.location + 1, text.length)
    }

    private func syncRichContentFromEditableEntries() {
        let content = inlineContentFromEntries()
        richContentInitialized = true
        richBlockEntryIDs = content.blockIDs
        richBlockTexts = content.blockTexts
        if content.text != richCombinedText || content.insertions != richInlineInsertions {
            richCombinedText = content.text
            richInlineInsertions = content.insertions
            richContentRevision += 1
        }
    }

    /// Writes the inline editor's text and sticker positions back into
    /// `editableEntries`, one entry per blank-line-separated paragraph.
    ///
    /// Paragraphs whose text is unchanged keep their entry (and its classic
    /// layout sticker); changed paragraphs reuse the remaining entries in order.
    /// This replaces the old behaviour of dumping the whole text into entry 0,
    /// which duplicated every later paragraph on save.
    private func applyInlineEditsToEntries() {
        let blocks = DiaryInlineMapping.blocks(in: richCombinedText)

        var placements = Array(repeating: [InlineStickerPlacement](), count: blocks.count)
        for insertion in richInlineInsertions {
            let location = DiaryInlineMapping.locate(insertion.characterIndex, in: blocks)
            placements[location.block].append(InlineStickerPlacement(
                id: insertion.id,
                stickerID: insertion.stickerID,
                image: insertion.image,
                offset: location.offset
            ))
        }

        let oldIDs = richBlockEntryIDs
        let newTexts = blocks.map(\.text)
        let alignment = DiaryInlineMapping.align(old: richBlockTexts, new: newTexts)
        let assignment: [UUID?] = alignment.assignment.map { oldIndex in
            oldIndex.flatMap { oldIDs.indices.contains($0) ? oldIDs[$0] : nil }
        }
        var absorbedBy: [UUID: Int] = [:]
        for (oldIndex, absorber) in alignment.absorbedBy where oldIDs.indices.contains(oldIndex) {
            absorbedBy[oldIDs[oldIndex]] = absorber
        }

        let byID = Dictionary(editableEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var blockEntries: [EditableDiaryEntry] = blocks.indices.map { index in
            var entry = assignment[index].flatMap { byID[$0] }
                ?? EditableDiaryEntry(id: UUID(), text: "", sticker: nil, stickerSide: index % 2 == 0 ? .right : .left)
            entry.text = blocks[index].text
            entry.inlineStickers = placements[index]
            return entry
        }

        // A paragraph merged into its neighbour hands over its layout sticker
        // if the neighbour doesn't have one.
        for (removedID, absorber) in absorbedBy {
            guard let removed = byID[removedID], removed.sticker != nil,
                  blockEntries.indices.contains(absorber),
                  blockEntries[absorber].sticker == nil else { continue }
            blockEntries[absorber].sticker = removed.sticker
            blockEntries[absorber].stickerID = removed.stickerID
            blockEntries[absorber].hadStickerSlot = true
        }

        // Keep paragraphs hidden from the inline layout next to the paragraph
        // they followed.
        let visibleIDs = Set(oldIDs)
        var hiddenAfter: [UUID: [EditableDiaryEntry]] = [:]
        var leadingHidden: [EditableDiaryEntry] = []
        var lastVisibleID: UUID?
        for entry in editableEntries {
            if visibleIDs.contains(entry.id) {
                lastVisibleID = entry.id
            } else if let lastVisibleID {
                hiddenAfter[lastVisibleID, default: []].append(entry)
            } else {
                leadingHidden.append(entry)
            }
        }

        var result = leadingHidden
        for entry in blockEntries {
            result.append(entry)
            result.append(contentsOf: hiddenAfter.removeValue(forKey: entry.id) ?? [])
        }
        for entry in editableEntries {
            if let orphans = hiddenAfter.removeValue(forKey: entry.id) {
                result.append(contentsOf: orphans)
            }
        }

        editableEntries = result
        richBlockEntryIDs = blockEntries.map(\.id)
        richBlockTexts = newTexts
        if !isWriting {
            visibleStickerCount = max(visibleStickerCount, result.count)
        }
    }

    private func insertInlineSticker(_ option: DiaryStickerOption) {
        richInlineInsertions.append(InlineStickerInsertion(
            image: option.image,
            characterIndex: min(richCursorPosition, (richCombinedText as NSString).length),
            stickerID: option.stickerID
        ))
        applyInlineEditsToEntries()
        scheduleAutosave()
    }

    @ViewBuilder
    private var richLayoutContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            InlineStickerTextView(
                text: $richCombinedText,
                insertions: $richInlineInsertions,
                cursorPosition: $richCursorPosition,
                revision: richContentRevision,
                isEditable: !isWriting && !isArchivingPage && !isDiaryFinished,
                fontSize: 17,
                lineSpacing: 8,
                focusRequest: richFocusRequest,
                onFocusChange: { focused in
                    if focused {
                        enterEditorFullscreen()
                    } else {
                        saveImmediately()
                        scheduleEditorFullscreenExit()
                    }
                },
                onTextChange: {
                    applyInlineEditsToEntries()
                    scheduleAutosave()
                }
            )
            .id(richTextViewIdentity)
            .frame(minHeight: 400, maxHeight: .infinity, alignment: .top)
            .background {
                if !isWriting && !isArchivingPage {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { richFocusRequest += 1 }
                }
            }

        }
        .onAppear {
            if isWriting {
                syncRichContentFromEditableEntries()
            } else {
                initializeRichContent()
            }
        }
    }

    private var richTextViewIdentity: String {
        "inline-\(selectedDayID)"
    }

    private enum RichToolbarMode { case inline }

    private func richStickerToolbar(mode: RichToolbarMode) -> some View {
        let mutedInk = Color(red: 0.52, green: 0.46, blue: 0.42)
        let stickers = allAvailableStickers

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Label("点击插入文中", systemImage: "text.insert")
                .font(DiaryFont.display(size: 12, weight: .bold))
                .foregroundStyle(mutedInk)
                .padding(.leading, 4)

                ForEach(stickers.prefix(Self.maxDiaryStickers)) { option in
                    Button {
                        insertInlineSticker(option)
                    } label: {
                        Image(uiImage: option.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.96, green: 0.93, blue: 0.89).opacity(0.8))
        )
    }

    private func switchToDate(_ date: Date) {
        guard !calendar.isDate(date, inSameDayAs: selectedDate) else { return }
        saveImmediately()
        dismissKeyboard()
        isEditorFocused = false
        autoFocusBlankEntry = false
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            selectedDate = date
        }
        // Reload entries for new date
        let newEntries = onDateEntries(date)
        saveState = .idle
        setDiaryTitle(storedDiaryTitle(for: date))
        showEntriesImmediately(newEntries)
        rebuildRichContentIfNeeded()
    }

    private func startDiaryFromEmptyState() {
        if dateStickerImages.isEmpty {
            startBlankPage()
        } else if AppFeatures.aiDiary {
            attemptRegeneration(confirmIfNeeded: false)
        } else {
            startStickerPage()
        }
    }

    /// Hand-written diary (English app): one empty paragraph per sticker of the
    /// day, each showing its own writing prompt.
    private func startStickerPage() {
        reloadDateStickers()
        let newEntries = dateStickerOptions.enumerated().map { index, option in
            DiaryEntry(
                title: "",
                text: "",
                sticker: option.image,
                stickerSide: index % 2 == 0 ? .right : .left,
                hadStickerSlot: true,
                stickerID: option.stickerID
            )
        }
        guard !newEntries.isEmpty else {
            startBlankPage()
            return
        }
        isEditorFocused = false
        saveState = .idle
        setDiaryTitle()
        // No autosave yet: a page of stickers without words isn't a diary.
        showEntriesImmediately(newEntries)
    }

    private func startBlankPage() {
        isPageArchived = false
        isWriting = false
        isEditorFocused = false
        saveState = .idle
        visibleCharacters = 0
        visibleStickerCount = 1
        currentWritingIndex = 0
        activeGenerationStickerIndex = nil
        generationAnimationStopToken += 1
        editableEntries = [EditableDiaryEntry.blank()]
        originalHadSticker = []
        setDiaryTitle()

        reloadDateStickers()
        rebuildRichContentIfNeeded()

        // Auto-focus the text view so the cursor is immediately visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            autoFocusBlankEntry = true
        }
    }

    private func addNewDiaryEntry() {
        let newIndex = editableEntries.count
        let side: DiaryEntry.StickerSide = newIndex % 2 == 0 ? .right : .left
        let newEntry = EditableDiaryEntry(
            id: UUID(),
            text: "",
            sticker: nil,
            stickerSide: side,
            hadStickerSlot: true
        )
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            editableEntries.append(newEntry)
            visibleStickerCount = editableEntries.count
            currentWritingIndex = editableEntries.count - 1
        }
        scheduleAutosave()
    }

    private func deleteDiaryEntry(at index: Int) {
        guard editableEntries.count > 1 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            editableEntries.remove(at: index)
            visibleStickerCount = editableEntries.count
        }
        scheduleAutosave()
    }

    /// Number of stickers that would actually be sent to the AI for this date.
    private var diaryStickerCount: Int {
        dateStickerImages.count
    }

    private var exceedsStickerLimit: Bool {
        diaryStickerCount > Self.maxDiaryStickers
    }

    /// Single gate for all AI-generation entry points. Returns false (and shows
    /// an alert) when the sticker count is over the limit.
    @State private var showSubscriptionFromQuota = false

    private func attemptRegeneration(confirmIfNeeded: Bool) {
        if needsNetworkPermissionRecovery && !allowNextNetworkPermissionRetry {
            showNetworkPermissionAlert = true
            return
        }
        allowNextNetworkPermissionRetry = false
        if exceedsStickerLimit {
            showStickerLimitAlert = true
            return
        }
        if !DailyQuotaManager.canGenerate {
            showSubscriptionFromQuota = true
            return
        }
        if confirmIfNeeded, shouldConfirmRegeneration {
            showRegenerateConfirm = true
        } else {
            beginRegeneration()
        }
    }

    private var needsNetworkPermissionRecovery: Bool {
        generationError == String(localized: "请允许网络访问后重试")
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        allowNextNetworkPermissionRetry = true
        shouldRetryNetworkRequestOnActive = true
        UIApplication.shared.open(url)
    }

    private func retryNetworkRequestAfterReturningFromSettingsIfNeeded() {
        guard shouldRetryNetworkRequestOnActive,
              needsNetworkPermissionRecovery,
              !isGenerating,
              !isWriting,
              !isArchivingPage else { return }
        shouldRetryNetworkRequestOnActive = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard needsNetworkPermissionRecovery, !isGenerating else { return }
            attemptRegeneration(confirmIfNeeded: false)
        }
    }

    private func requestRegeneration() {
        attemptRegeneration(confirmIfNeeded: true)
    }

    private func confirmRegeneration() {
        showRegenerateConfirm = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            beginRegeneration()
        }
    }

    /// Leave the new selection visible for a moment, then pull the picker back.
    private func dismissStylePickersAfterSelection() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            dismissStylePickers()
        }
    }

    private func dismissStylePickers() {
        guard showPaperColorPicker || showFontPicker else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showPaperColorPicker = false
            showFontPicker = false
        }
    }

    private func enterEditorFullscreen() {
        editorExitTask?.cancel()
        editorExitTask = nil
        dismissStylePickers()
        guard !isEditorFocused else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            isEditorFocused = true
        }
    }

    /// Called when a text view loses focus. Waits briefly so moving the cursor
    /// to another paragraph doesn't flash the header in and out.
    private func scheduleEditorFullscreenExit() {
        editorExitTask?.cancel()
        editorExitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            exitEditorFullscreen()
        }
    }

    private func exitEditorFullscreen() {
        editorExitTask?.cancel()
        editorExitTask = nil
        guard isEditorFocused else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditorFocused = false
        }
    }

    private func scrollDuringWritingIfNeeded(_ visibleCount: Int, proxy: ScrollViewProxy) {
        guard isWriting, visibleCount % 8 < 2 || visibleCount >= writingTotalCharacters else { return }
        let target = currentWritingIndex >= editableEntries.count - 1
            ? diaryBottomID
            : diaryRowID(for: currentWritingIndex)
        withAnimation(.easeInOut(duration: 0.24)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private func resetDiaryScroll(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(diaryTopID, anchor: .top)
            }
        }
    }

    private func beginRegeneration() {
        autosaveTask?.cancel()
        needsFullSave = false
        saveStateResetTask?.cancel()
        dismissKeyboard()
        if hasEditableDiaryContent {
            onArchive(selectedDate, editableEntries, diaryCustomTitle)
            saveState = .saved
        }
        isPageArchived = false
        isWriting = false
        isEditorFocused = false
        isArchivingPage = false
        activeGenerationStickerIndex = nil
        generationAnimationStopToken += 1
        visibleCharacters = fullText.count
        visibleStickerCount = editableEntries.count
        currentWritingIndex = max(editableEntries.count - 1, 0)
        saveState = .idle
        onRegenerate(selectedDate)
    }

    private func clearDiaryPage() {
        autosaveTask?.cancel()
        needsFullSave = false
        saveStateResetTask?.cancel()
        onClearDiary(selectedDate)
        setDiaryFinished(false)
        isPageArchived = false
        isWriting = false
        isEditorFocused = false
        isArchivingPage = false
        activeGenerationStickerIndex = nil
        generationAnimationStopToken += 1
        visibleCharacters = 0
        visibleStickerCount = 0
        currentWritingIndex = 0
        saveState = .idle
        setDiaryTitle()
        editableEntries = []
        originalHadSticker = []
        richCombinedText = ""
        richInlineInsertions = []
        richBlockEntryIDs = []
        richBlockTexts = []
        richContentInitialized = false
        reloadDateStickers()
        diaryScrollResetToken += 1
    }

    private func scheduleAutosave() {
        guard !isWriting, !isGenerating, hasEditableDiaryContent else { return }
        autosaveTask?.cancel()
        saveStateResetTask?.cancel()
        // Only touch state when it actually changes: every @State write
        // re-evaluates this (large) view, and this runs on every keystroke.
        if saveState != .saving {
            saveState = .saving
        }

        let date = selectedDate
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled,
                  calendar.isDate(date, inSameDayAs: selectedDate),
                  hasEditableDiaryContent else { return }
            onAutosave(date, editableEntries, displayedDiaryTitle)
            needsFullSave = true
            markSaved()
        }
    }

    private func saveImmediately() {
        autosaveTask?.cancel()
        guard hasEditableDiaryContent else { return }
        onArchive(selectedDate, editableEntries, displayedDiaryTitle)
        needsFullSave = false
        markSaved()
    }

    private func markSaved() {
        saveStateResetTask?.cancel()
        saveState = .saved
        saveStateResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run {
                if saveState == .saved {
                    saveState = .idle
                }
            }
        }
    }

    private var diaryBottomID: String {
        "diary-bottom-\(selectedDayID)"
    }

    private var diaryTopID: String {
        "diary-top-\(selectedDayID)"
    }

    private var diaryScrollViewID: String {
        "diary-scroll-\(selectedDayID)-\(diaryScrollResetToken)"
    }

    private func diaryRowID(for index: Int) -> String {
        "diary-row-\(selectedDayID)-\(index)"
    }

    private var selectedDayID: String {
        String(Int(calendar.startOfDay(for: selectedDate).timeIntervalSince1970))
    }

    private func beginDiaryDeleteDrag() {
        guard !isWriting, !isArchivingPage else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            isDiaryDeleteTargetVisible = true
        }
    }

    private func updateDiaryDeleteTarget(for point: CGPoint, in size: CGSize) {
        let nextValue = diaryDeleteZoneFrame(in: size).contains(point)
        if nextValue != isDiaryDeleteTargetActive {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.74)) {
                isDiaryDeleteTargetActive = nextValue
            }
        }
    }

    private func hideDiaryDeleteTarget() {
        withAnimation(.easeOut(duration: 0.18)) {
            isDiaryDeleteTargetVisible = false
            isDiaryDeleteTargetActive = false
        }
    }

    private func handleDiaryLayoutStyleChange(_ newStyle: DiaryLayoutStyle, proxy: ScrollViewProxy) {
        if newStyle == .inlineSticker {
            syncRichContentFromEditableEntries()
        }
        guard isWriting else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.24)) {
                proxy.scrollTo(diaryRowID(for: currentWritingIndex), anchor: .bottom)
            }
        }
    }

    private func diaryDeleteZoneFrame(in size: CGSize) -> CGRect {
        CGRect(x: size.width / 2 - 86, y: size.height - 118, width: 172, height: 74)
    }

    private func editableEntryBinding(index: Int, fallback: EditableDiaryEntry) -> Binding<EditableDiaryEntry> {
        Binding(
            get: {
                editableEntries.indices.contains(index) ? editableEntries[index] : fallback
            },
            set: { newValue in
                guard editableEntries.indices.contains(index) else { return }
                editableEntries[index] = newValue
            }
        )
    }

    private func deleteDiarySticker(at index: Int) {
        guard editableEntries.indices.contains(index) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            editableEntries[index].hadStickerSlot = true
            editableEntries[index].setLayoutSticker(nil, stickerID: nil)
            editableEntries[index].stickerOffset = .zero
            editableEntries[index].stickerScale = 1
        }
        scheduleAutosave()
    }

    private func restartAnimation() {
        guard !isArchivingPage else { return }
        let source = currentEntries
        guard !source.isEmpty else { return }
        isPageArchived = false
        isWriting = true
        needsFullSave = false
        autosaveTask?.cancel()
        visibleCharacters = 0
        visibleStickerCount = 0
        currentWritingIndex = 0
        activeGenerationStickerIndex = nil
        generationAnimationStopToken += 1
        editableEntries = []
        writingTotalCharacters = max(totalCharacters(of: source) - 2, 0)
        originalHadSticker = Set(source.indices.filter { source[$0].hadStickerSlot || source[$0].sticker != nil })
        if isRichLayoutMode {
            richCombinedText = ""
            richInlineInsertions = []
            richContentInitialized = true
        }

        reloadDateStickers()

        Task {
            var writtenCharacters = 0

            for entryIndex in source.indices {
                let sourceEntry = source[entryIndex]
                let blockText = diaryBlockText(for: sourceEntry)

                await MainActor.run {
                    guard isWriting else { return }
                    currentWritingIndex = entryIndex
                    var editable = EditableDiaryEntry(sourceEntry)
                    editable.text = ""
                    editable.sticker = nil
                    editableEntries.append(editable)
                    originalHadSticker.insert(entryIndex)
                    if isRichLayoutMode {
                        syncRichContentFromEditableEntries()
                    }
                }

                // Two characters per 40ms tick: same typing speed as before with
                // half the view updates.
                let characters = Array(blockText)
                var characterCount = 0
                while characterCount < characters.count {
                    characterCount = min(characterCount + 2, characters.count)
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    let shown = characterCount
                    await MainActor.run {
                        guard isWriting, editableEntries.indices.contains(entryIndex) else { return }
                        editableEntries[entryIndex].text = String(characters[0..<shown])
                        visibleCharacters = writtenCharacters + shown
                        if isRichLayoutMode {
                            syncRichContentFromEditableEntries()
                        }
                    }
                }

                await MainActor.run {
                    guard isWriting, editableEntries.indices.contains(entryIndex) else { return }
                    editableEntries[entryIndex].text = blockText
                    editableEntries[entryIndex].sticker = sourceEntry.sticker
                    visibleStickerCount = entryIndex + 1
                    activeGenerationStickerIndex = sourceEntry.sticker == nil ? nil : entryIndex
                    if isRichLayoutMode {
                        syncRichContentFromEditableEntries()
                    }
                }

                let isLastEntry = entryIndex == source.indices.last
                if !isLastEntry {
                    try? await Task.sleep(nanoseconds: sourceEntry.sticker == nil ? 160_000_000 : 760_000_000)
                }

                await MainActor.run {
                    guard isWriting else { return }
                    if activeGenerationStickerIndex == entryIndex {
                        activeGenerationStickerIndex = nil
                    }
                }

                writtenCharacters += blockText.count + 2
            }

            await MainActor.run {
                guard isWriting else { return }
                visibleStickerCount = source.count
                currentWritingIndex = max(source.count - 1, 0)
                activeGenerationStickerIndex = nil
                isWriting = false
                generationAnimationStopToken += 1
                if isRichLayoutMode {
                    syncRichContentFromEditableEntries()
                }
                onDiaryGenerationAnimationComplete()
            }
        }
    }

    private func showEntriesImmediately(_ source: [DiaryEntry]) {
        isPageArchived = false
        isWriting = false
        activeGenerationStickerIndex = nil
        generationAnimationStopToken += 1
        visibleCharacters = fullText.count
        visibleStickerCount = source.count
        currentWritingIndex = max(source.count - 1, 0)
        editableEntries = source.map(EditableDiaryEntry.init)
        originalHadSticker = Set(source.indices.filter { source[$0].hadStickerSlot || source[$0].sticker != nil })
        setDiaryTitle()
        reloadDateStickers()
        if isRichLayoutMode {
            syncRichContentFromEditableEntries()
        } else {
            richContentInitialized = false
        }
    }

    private func archivePage() {
        guard !isArchivingPage else { return }
        isWriting = false
        activeGenerationStickerIndex = nil
        generationAnimationStopToken += 1
        dismissKeyboard()
        onArchive(selectedDate, editableEntries, displayedDiaryTitle)

        withAnimation(.spring(response: 0.58, dampingFraction: 0.82)) {
            isArchivingPage = true
        }

        Task {
            try? await Task.sleep(nanoseconds: 760_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.20)) {
                    isPageArchived = true
                }
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

enum DiarySaveState {
    case idle
    case saving
    case saved
}

struct EditableDiaryEntry: Identifiable {
    let id: UUID
    var text: String
    var sticker: UIImage?
    let stickerSide: DiaryEntry.StickerSide
    var hadStickerSlot: Bool = false
    var inlineAnchor: String?
    var stickerID: String?
    var stickerOffset: CGSize = .zero
    var stickerScale: CGFloat = 1
    /// Inline-layout sticker positions; `nil` until the user edits them.
    var inlineStickers: [InlineStickerPlacement]?

    init(
        id: UUID,
        text: String,
        sticker: UIImage?,
        stickerSide: DiaryEntry.StickerSide,
        hadStickerSlot: Bool = false,
        inlineAnchor: String? = nil,
        stickerID: String? = nil
    ) {
        self.id = id
        self.text = text
        self.sticker = sticker
        self.stickerSide = stickerSide
        self.hadStickerSlot = hadStickerSlot
        self.inlineAnchor = inlineAnchor
        self.stickerID = stickerID
    }

    init(_ entry: DiaryEntry) {
        id = entry.id
        text = joinedDiaryText(title: entry.title, text: entry.text)
        sticker = entry.sticker
        stickerSide = entry.stickerSide
        hadStickerSlot = entry.hadStickerSlot || entry.sticker != nil
        inlineAnchor = entry.inlineAnchor
        stickerID = entry.stickerID
        stickerOffset = entry.stickerOffset
        stickerScale = entry.stickerScale
        inlineStickers = entry.inlineStickers
    }

    /// Changes the paragraph's layout sticker and keeps its inline-layout copy
    /// in step (same position, new image; removed when the sticker is removed).
    mutating func setLayoutSticker(_ image: UIImage?, stickerID newID: String?) {
        let entryID = id
        sticker = image
        stickerID = newID
        guard var placements = inlineStickers else { return }
        let inlineOffset = placements.first { $0.id == entryID }?.offset
        placements.removeAll { $0.id == entryID }
        if let image, let inlineOffset {
            placements.append(InlineStickerPlacement(id: entryID, stickerID: newID, image: image, offset: inlineOffset))
        }
        inlineStickers = placements
    }

    static func blank() -> EditableDiaryEntry {
        EditableDiaryEntry(
            id: UUID(),
            text: "",
            sticker: nil,
            stickerSide: .right,
            hadStickerSlot: true
        )
    }
}

struct DiaryPaper: View {
    let style: DiaryPaperStyle
    var colorTheme: DiaryPaperColor = .classic

    var body: some View {
        let paperShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        paperShape
            .fill(colorTheme.background)
            .overlay {
                style.patternView(color: colorTheme.patternColor)
                    .clipShape(paperShape)
            }
            .overlay(alignment: .leading) {
                if style.showsMarginLine {
                    Rectangle()
                        .fill(colorTheme.accentColor.opacity(0.18))
                        .frame(width: 2)
                        .padding(.leading, 48)
                }
            }
            .clipShape(paperShape)
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}

struct DiaryEntryRow: View {
    @Binding var entry: EditableDiaryEntry
    let showSticker: Bool
    let layoutStyle: DiaryLayoutStyle
    let index: Int
    let isGenerating: Bool
    let animationStopToken: Int
    let isEditable: Bool
    let isStickerEditable: Bool
    let onStickerDragBegan: () -> Void
    let onStickerDragChanged: (CGPoint) -> Void
    let onStickerDragEnded: (CGPoint) -> Bool
    var onFocusChange: ((Bool) -> Void)? = nil
    var onTextChange: (() -> Void)? = nil
    var onReplaceStickerTap: (() -> Void)? = nil
    /// Tracks whether this entry originally had a sticker (so we show "+" after deletion)
    var hadSticker: Bool = false
    var autoFocus: Bool = false
    /// All stickers for this date, used in the replacement picker
    var dateStickerOptions: [DiaryStickerOption] = []
    var onAddSticker: (() -> Void)? = nil
    var onStickerTap: (() -> Void)? = nil
    var onDeleteEntry: (() -> Void)? = nil
    var canDeleteEntry: Bool = false
    var paperColor: DiaryPaperColor = .classic
    var placeholder: String = String(localized: "写下这一刻的感受…")
    var showsPlaceholder: Bool = true
    @State private var focusRequest = 0
    @Environment(\.diaryFontID) private var diaryFontID
    @State private var stickerDragStartOffset: CGSize = .zero
    @State private var stickerPinchStartScale: CGFloat = 1
    @State private var isDraggingSticker = false
    @State private var showStickerDeleteConfirm = false
    @State private var stickerJigglePhase = false
    @State private var generationTwistPhase = false
    @State private var generationTwistTask: Task<Void, Never>?
    @State private var showStickerPicker = false

    var body: some View {
        Group {
            switch layoutStyle {
            case .classic:
                classicLayout
            case .timeline, .inlineSticker:
                // Inline layout is rendered by DiaryBookView's InlineStickerTextView.
                timelineLayout
            }
        }
        .alert("删除贴纸", isPresented: $showStickerDeleteConfirm) {
            Button("删除", role: .destructive) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    entry.hadStickerSlot = true
                    entry.setLayoutSticker(nil, stickerID: nil)
                    entry.stickerOffset = .zero
                    entry.stickerScale = 1
                    stickerJigglePhase = false
                }
                onTextChange?()
            }
            Button("取消", role: .cancel) {
                withAnimation(.easeOut(duration: 0.18)) {
                    stickerJigglePhase = false
                }
            }
        } message: {
            Text("确定要删除这张贴纸吗？")
        }
        .sheet(isPresented: $showStickerPicker) {
            stickerPickerSheet
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: animationStopToken) { _, _ in
            stopGenerationTwist()
        }
    }

    @State private var showDeleteEntryConfirm = false

    private var classicLayout: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .center, spacing: 14) {
                if entry.stickerSide == .left {
                    stickerView(size: 112, rotation: entry.stickerSide == .left ? -5 : 5)
                }

                diaryText

                if entry.stickerSide == .right {
                    stickerView(size: 112, rotation: entry.stickerSide == .left ? -5 : 5)
                }
            }
            .frame(minHeight: 132)

            if canDeleteEntry && isEditable {
                Button {
                    showDeleteEntryConfirm = true
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, Color(red: 0.85, green: 0.35, blue: 0.30))
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                }
                .offset(x: 6, y: -6)
            }
        }
        .alert("删除段落", isPresented: $showDeleteEntryConfirm) {
            Button("删除", role: .destructive) {
                onDeleteEntry?()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除这个段落吗？")
        }
    }

    private var timelineLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 8) {
                Circle()
                    .fill(Color(red: 0.74, green: 0.38, blue: 0.25).opacity(0.55))
                    .frame(width: 11, height: 11)
                Rectangle()
                    .fill(Color(red: 0.74, green: 0.38, blue: 0.25).opacity(0.18))
                    .frame(width: 2, height: 118)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 12) {
                diaryText
                stickerView(size: 104, rotation: index % 2 == 0 ? -4 : 5)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(minHeight: 170)
    }

    private var diaryText: some View {
        DiaryTextView(
            text: $entry.text,
            isEditable: isEditable,
            fontSize: layoutStyle.textSize,
            lineSpacing: layoutStyle.lineSpacing,
            textColor: paperColor.uiInkColor,
            autoFocus: autoFocus,
            focusRequest: focusRequest,
            onFocusChange: onFocusChange,
            onTextChange: onTextChange
        )
            .frame(minHeight: autoFocus ? max(layoutStyle.editorMinHeight, 320) : layoutStyle.editorMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The text view is only as tall as its text; catch taps on the rest of
                // the editor box (e.g. on the prompt) so they don't hit the paper and
                // dismiss the keyboard.
                if isEditable {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { focusRequest += 1 }
                }
            }
            .overlay {
                if showsPlaceholder && isEditable && entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholder)
                        .font(DiaryFont.font(size: layoutStyle.textSize))
                        .id(diaryFontID)
                        .foregroundStyle(paperColor.mutedInkColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func stickerView(size: CGFloat, rotation: Double) -> some View {
        if let sticker = entry.sticker, showSticker {
            Image(uiImage: sticker)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .rotationEffect(.degrees(rotation + stickerMotionAngle))
                .scaleEffect(stickerMotionScale)
                .offset(entry.stickerOffset)
                .shadow(color: .black.opacity(0.18), radius: 7, y: 5)
                .transition(.scale(scale: 0.2).combined(with: .opacity))
                .contentShape(Rectangle())
                .gesture(isStickerEditable ? stickerDragGesture : nil)
                .simultaneousGesture(isStickerEditable ? stickerScaleGesture : nil)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4, maximumDistance: 10)
                        .onEnded { _ in
                            stickerJigglePhase = false
                            withAnimation(.easeInOut(duration: 0.11).repeatForever(autoreverses: true)) {
                                stickerJigglePhase = true
                            }
                            let haptic = UIImpactFeedbackGenerator(style: .medium)
                            haptic.impactOccurred()
                            showStickerDeleteConfirm = true
                        }
                )
                .onTapGesture {
                    onStickerTap?()
                }
                .onAppear {
                    stickerDragStartOffset = entry.stickerOffset
                    stickerPinchStartScale = entry.stickerScale
                    updateGenerationTwist(isActive: isGenerating)
                }
                .onChange(of: isGenerating) { _, newValue in
                    updateGenerationTwist(isActive: newValue)
                }
        } else if isEditable && entry.sticker == nil && (hadSticker || entry.hadStickerSlot) {
            // "+" placeholder after sticker deletion
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(red: 0.72, green: 0.66, blue: 0.60).opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color(red: 0.60, green: 0.54, blue: 0.48))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    showStickerPicker = true
                }
                .rotationEffect(.degrees(rotation))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
            Color.clear
                .frame(width: entry.sticker == nil ? 0 : size, height: entry.sticker == nil ? 0 : size)
        }
    }

    private var stickerJiggleAngle: Double {
        guard stickerJigglePhase else { return 0 }
        return stickerJigglePhase ? 2.5 : -2.5
    }

    private var generationTwistAngle: Double {
        guard isGenerating, !stickerJigglePhase else { return 0 }
        return generationTwistPhase ? -4.5 : 1.2
    }

    private var stickerPickerSheet: some View {
        let ink = Color(red: 0.34, green: 0.24, blue: 0.18)
        let mutedInk = Color(red: 0.52, green: 0.46, blue: 0.42)
        let paper = Color(red: 0.97, green: 0.95, blue: 0.92)

        return VStack(spacing: 20) {
            Text("选择贴纸")
                .font(DiaryFont.display(size: 22, weight: .bold))
                .foregroundStyle(ink)
                .padding(.top, 20)

            if dateStickerOptions.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(mutedInk.opacity(0.5))
                    Text("暂无可用贴纸")
                        .font(DiaryFont.display(size: 14, weight: .medium))
                        .foregroundStyle(mutedInk)
                    Text("拍照生成贴纸后，就可以添加到日记中")
                        .font(DiaryFont.display(size: 13, weight: .medium))
                        .foregroundStyle(mutedInk.opacity(0.7))
                        .multilineTextAlignment(.center)

                    if let onAddSticker {
                        Button {
                            showStickerPicker = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                onAddSticker()
                            }
                        } label: {
                            Label("去拍照", systemImage: "camera.fill")
                                .font(DiaryFont.display(size: 15))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 24)
                                .frame(height: 44)
                                .background(ink, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 12)], spacing: 12) {
                        ForEach(dateStickerOptions) { option in
                            let image = option.image
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    entry.setLayoutSticker(image, stickerID: option.stickerID)
                                    entry.hadStickerSlot = true
                                    entry.stickerOffset = .zero
                                    entry.stickerScale = 1
                                }
                                onTextChange?()
                                showStickerPicker = false
                            } label: {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 72, height: 72)
                                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paper)
    }

    private var stickerMotionAngle: Double {
        stickerJiggleAngle + generationTwistAngle
    }

    private var stickerMotionScale: CGFloat {
        if stickerJigglePhase {
            return 1.05
        }
        if isGenerating {
            return entry.stickerScale * (generationTwistPhase ? 1.025 : 0.99)
        }
        return entry.stickerScale
    }

    private func updateGenerationTwist(isActive: Bool) {
        guard isActive else {
            stopGenerationTwist()
            return
        }

        guard generationTwistTask == nil else { return }
        generationTwistTask = Task { @MainActor in
            generationTwistPhase = false
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.72)) {
                    generationTwistPhase.toggle()
                }
                try? await Task.sleep(nanoseconds: 720_000_000)
            }
        }
    }

    private func stopGenerationTwist() {
        generationTwistTask?.cancel()
        generationTwistTask = nil
        var t = Transaction(animation: nil)
        t.disablesAnimations = true
        withTransaction(t) {
            generationTwistPhase = false
        }
    }

    private var stickerDragGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                guard isStickerEditable else { return }
                if !isDraggingSticker {
                    isDraggingSticker = true
                    stickerDragStartOffset = entry.stickerOffset
                    onStickerDragBegan()
                }
                entry.stickerOffset = CGSize(
                    width: stickerDragStartOffset.width + value.translation.width,
                    height: stickerDragStartOffset.height + value.translation.height
                )
                onStickerDragChanged(value.location)
            }
            .onEnded { value in
                guard isStickerEditable else { return }
                let didDelete = onStickerDragEnded(value.location)
                isDraggingSticker = false
                guard !didDelete else { return }
                stickerDragStartOffset = entry.stickerOffset
            }
    }

    private var stickerScaleGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard isStickerEditable else { return }
                entry.stickerScale = max(0.55, min(1.75, stickerPinchStartScale * value))
            }
            .onEnded { _ in
                guard isStickerEditable else { return }
                stickerPinchStartScale = entry.stickerScale
            }
    }
}

struct DiaryTextView: UIViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    var textColor: UIColor = UIColor(red: 0.31, green: 0.24, blue: 0.20, alpha: 1)
    var autoFocus: Bool = false
    /// Bumped by the parent to focus the text view from a tap outside it.
    var focusRequest: Int = 0
    var onFocusChange: ((Bool) -> Void)? = nil
    var onTextChange: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textView.tintColor = UIColor(red: 0.48, green: 0.25, blue: 0.17, alpha: 1)
        context.coordinator.applyStyle(to: textView, fontSize: fontSize, lineSpacing: lineSpacing, textColor: textColor, fontID: context.environment.diaryFontID)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        textView.addGestureRecognizer(tap)

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyStyle(to: textView, fontSize: fontSize, lineSpacing: lineSpacing, textColor: textColor, fontID: context.environment.diaryFontID)

        // Only update text when the change came from the binding side, not from user typing
        if !context.coordinator.isUserEditing,
           textView.text != text,
           textView.markedTextRange == nil {
            UIView.performWithoutAnimation {
                let selectedRange = textView.selectedRange
                textView.text = text
                textView.selectedRange = clampedRange(selectedRange, in: text)
            }
        }

        textView.isEditable = isEditable
        textView.isSelectable = isEditable

        if autoFocus && isEditable && !textView.isFirstResponder {
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        }

        // A tap on the blank area around the text asks for focus.
        if focusRequest != context.coordinator.handledFocusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            if isEditable && !textView.isFirstResponder {
                DispatchQueue.main.async {
                    textView.becomeFirstResponder()
                    textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let targetSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let measuredSize = textView.sizeThatFits(targetSize)
        return CGSize(width: width, height: ceil(measuredSize.height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func clampedRange(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(range.location, length)
        let upperBound = min(location + range.length, length)
        return NSRange(location: location, length: upperBound - location)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: DiaryTextView
        var isUserEditing = false
        var handledFocusRequest = 0
        private let pencilCaret = PencilCaret()
        private var styleKey: String?

        init(parent: DiaryTextView) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
        }

        func applyStyle(to textView: UITextView, fontSize: CGFloat, lineSpacing: CGFloat, textColor: UIColor, fontID: String) {
            let nextKey = "\(fontSize)-\(lineSpacing)-\(textColor.description)-\(fontID)"
            guard styleKey != nextKey else { return }
            styleKey = nextKey

            let font = DiaryFont.uiFont(size: fontSize)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = lineSpacing

            textView.font = font
            textView.textColor = textColor
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
        }

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            parent.isEditable
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isUserEditing = true
            // Let the keyboard start presenting before the editor layout re-renders.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isUserEditing else { return }
                self.parent.onFocusChange?(true)
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isUserEditing = false
            pencilCaret.hide()
            parent.onFocusChange?(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            PencilSound.shared.play()
            pencilCaret.textDidChange(in: textView)
            parent.text = textView.text
            parent.onTextChange?()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView,
                  parent.isEditable, !textView.isFirstResponder else { return }
            textView.becomeFirstResponder()
        }

        // 当 textView 已经是第一响应者时（编辑中 / 有文字选中），
        // 不接管手势，让 UITextView 内置的手势来处理光标定位和取消选中。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let textView = gestureRecognizer.view as? UITextView else { return true }
            return !textView.isFirstResponder
        }
    }
}

// MARK: - Shared Rich Diary Helpers

/// A sticker inside the combined inline-layout text. `characterIndex` is a
/// UTF-16 offset into the plain text (attachments excluded), matching NSString
/// and UITextView ranges so emoji don't shift sticker positions.
struct InlineStickerInsertion: Identifiable, Equatable {
    let id: UUID
    let image: UIImage
    let stickerID: String?
    let characterIndex: Int

    init(image: UIImage, characterIndex: Int, stickerID: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.image = image
        self.stickerID = stickerID
        self.characterIndex = characterIndex
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.characterIndex == rhs.characterIndex && lhs.stickerID == rhs.stickerID
    }
}

/// Text attachment that remembers which sticker it shows, so edits in the text
/// view can be mapped back to the original full-resolution image and ID.
final class StickerTextAttachment: NSTextAttachment {
    var insertionID = UUID()
    var stickerID: String?
    var sourceImage: UIImage?
}

func richDiaryFont(size: CGFloat) -> UIFont {
    DiaryFont.uiFont(size: size)
}

func richDiaryBaseAttrs(fontSize: CGFloat, lineSpacing: CGFloat) -> [NSAttributedString.Key: Any] {
    let font = richDiaryFont(size: fontSize)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = lineSpacing
    return [
        .font: font,
        .foregroundColor: UIColor(red: 0.31, green: 0.24, blue: 0.20, alpha: 1),
        .paragraphStyle: paragraphStyle
    ]
}

func resizeStickerImage(_ image: UIImage, to size: CGSize) -> UIImage {
    // Default format uses the screen scale so inline stickers stay sharp.
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { _ in
        image.draw(in: aspectFitRect(for: image, in: CGRect(origin: .zero, size: size)))
    }
}

func aspectFitRect(for image: UIImage, in rect: CGRect) -> CGRect {
    guard image.size.width > 0, image.size.height > 0, rect.width > 0, rect.height > 0 else {
        return rect
    }

    let scale = min(rect.width / image.size.width, rect.height / image.size.height)
    let fittedSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    return CGRect(
        x: rect.midX - fittedSize.width / 2,
        y: rect.midY - fittedSize.height / 2,
        width: fittedSize.width,
        height: fittedSize.height
    )
}

// MARK: - Mode 1: Inline Sticker Text View (stickers as inline emoji)

struct InlineStickerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var insertions: [InlineStickerInsertion]
    @Binding var cursorPosition: Int
    let revision: Int
    let isEditable: Bool
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    /// Bumped by the parent to focus the text view from a tap outside it.
    var focusRequest: Int = 0
    var onFocusChange: ((Bool) -> Void)? = nil
    var onTextChange: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textView.tintColor = UIColor(red: 0.48, green: 0.25, blue: 0.17, alpha: 1)
        context.coordinator.fontID = context.environment.diaryFontID
        context.coordinator.applyContent(to: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.fontID = context.environment.diaryFontID
        context.coordinator.applyContent(to: textView)
        textView.isEditable = isEditable
        textView.isSelectable = isEditable

        // A tap on the blank area around the text asks for focus.
        if focusRequest != context.coordinator.handledFocusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            if isEditable && !textView.isFirstResponder {
                DispatchQueue.main.async {
                    textView.becomeFirstResponder()
                    textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(ceil(measured.height), 200))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InlineStickerTextView
        var isUserEditing = false
        var handledFocusRequest = 0
        private let pencilCaret = PencilCaret()
        /// Prevents programmatic selectedRange changes from overwriting the cursor binding.
        private var isProgrammaticChange = false
        private var appliedText = ""
        private var appliedInsertions: [InlineStickerInsertion] = []
        private var appliedRevision = -1
        /// Current handwriting face; a change restyles the whole text.
        var fontID = ""
        private var appliedFontID = ""
        /// Downscaled attachment images keyed by source image, so rebuilding the
        /// attributed text (e.g. every tick of the typing animation) doesn't
        /// re-render every sticker.
        private var thumbnailCache: [ObjectIdentifier: UIImage] = [:]

        init(parent: InlineStickerTextView) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
        }

        private func thumbnail(for image: UIImage, side: CGFloat) -> UIImage {
            let key = ObjectIdentifier(image)
            if let cached = thumbnailCache[key], cached.size.width == side { return cached }
            let resized = resizeStickerImage(image, to: CGSize(width: side, height: side))
            thumbnailCache[key] = resized
            return resized
        }

        func applyContent(to textView: UITextView) {
            // Allow rebuild when insertions changed (toolbar adds sticker while
            // the text view may already have resigned first responder).
            let needsRebuild = parent.text != appliedText || parent.insertions != appliedInsertions
                || parent.revision != appliedRevision || fontID != appliedFontID
            guard needsRebuild, textView.markedTextRange == nil else { return }
            appliedFontID = fontID
            appliedText = parent.text
            appliedInsertions = parent.insertions
            appliedRevision = parent.revision

            let font = richDiaryFont(size: parent.fontSize)
            let baseAttrs = richDiaryBaseAttrs(fontSize: parent.fontSize, lineSpacing: parent.lineSpacing)
            let result = NSMutableAttributedString(string: parent.text, attributes: baseAttrs)

            // Count how many stickers sit at or before the plain-text cursor
            // so we can offset the attributed-string cursor properly.
            let cursorPos = parent.cursorPosition
            var stickersBefore = 0

            let sorted = parent.insertions.sorted { $0.characterIndex > $1.characterIndex }
            let usedImages = Set(parent.insertions.map { ObjectIdentifier($0.image) })
            thumbnailCache = thumbnailCache.filter { usedImages.contains($0.key) }
            for insertion in sorted {
                let attachment = StickerTextAttachment()
                attachment.insertionID = insertion.id
                attachment.stickerID = insertion.stickerID
                attachment.sourceImage = insertion.image
                let stickerSize = font.lineHeight * 1.6
                attachment.image = thumbnail(for: insertion.image, side: stickerSize)
                attachment.bounds = CGRect(x: 0, y: (font.capHeight - stickerSize) / 2 - 2, width: stickerSize, height: stickerSize)
                let safeIndex = min(insertion.characterIndex, result.length)
                result.insert(NSAttributedString(attachment: attachment), at: safeIndex)
                if insertion.characterIndex <= cursorPos {
                    stickersBefore += 1
                }
            }

            isProgrammaticChange = true
            UIView.performWithoutAnimation {
                let attrCursor = min(cursorPos + stickersBefore, result.length)
                textView.attributedText = result
                textView.selectedRange = NSRange(location: attrCursor, length: 0)
            }
            isProgrammaticChange = false
            textView.typingAttributes = baseAttrs
        }

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            parent.isEditable
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isUserEditing = true
            // Let the keyboard start presenting before the editor layout re-renders.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isUserEditing else { return }
                self.parent.onFocusChange?(true)
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            // Capture cursor position one last time before marking editing done
            syncCursorPosition(from: textView)
            isUserEditing = false
            pencilCaret.hide()
            parent.onFocusChange?(false)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isProgrammaticChange else { return }
            syncCursorPosition(from: textView)
        }

        /// Convert the attributed-string cursor offset to a plain-text offset
        /// (skipping over attachment characters that represent inline stickers).
        private func syncCursorPosition(from textView: UITextView) {
            let rawOffset = textView.selectedRange.location
            guard rawOffset != NSNotFound else { return }
            let attributed = textView.attributedText ?? NSAttributedString()
            var plainOffset = 0
            let scanEnd = min(rawOffset, attributed.length)
            if scanEnd > 0 {
                attributed.enumerateAttributes(in: NSRange(location: 0, length: scanEnd)) { attrs, range, _ in
                    if attrs[.attachment] is NSTextAttachment {
                        // attachment = 1 char in attributed string, 0 in plain text
                    } else {
                        plainOffset += range.length
                    }
                }
            }
            parent.cursorPosition = plainOffset
        }

        func textViewDidChange(_ textView: UITextView) {
            PencilSound.shared.play()
            pencilCaret.textDidChange(in: textView)
            let attributed = textView.attributedText ?? NSAttributedString()
            var plain = ""
            var ins: [InlineStickerInsertion] = []
            var idx = 0

            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
                if let att = attrs[.attachment] as? StickerTextAttachment, let img = att.sourceImage ?? att.image {
                    ins.append(InlineStickerInsertion(
                        image: img,
                        characterIndex: idx,
                        stickerID: att.stickerID,
                        id: att.insertionID
                    ))
                } else if let att = attrs[.attachment] as? NSTextAttachment, let img = att.image {
                    // Pasted attachments from elsewhere: keep them as anonymous stickers.
                    ins.append(InlineStickerInsertion(image: img, characterIndex: idx))
                } else {
                    plain += (attributed.string as NSString).substring(with: range)
                    // UTF-16 length, consistent with NSString / selectedRange offsets.
                    idx += range.length
                }
            }
            appliedText = plain
            appliedInsertions = ins
            appliedRevision = parent.revision
            parent.text = plain
            parent.insertions = ins
            parent.onTextChange?()

            // Update cursor position after text change
            syncCursorPosition(from: textView)
        }
    }
}

struct DiaryNotebookArchiveView: View {
    let isOpen: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.40, green: 0.25, blue: 0.18),
                            Color(red: 0.24, green: 0.15, blue: 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 292, height: 210)
                .shadow(color: .black.opacity(0.18), radius: 22, y: 12)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.88, green: 0.78, blue: 0.62).opacity(0.88))
                .frame(width: 256, height: isOpen ? 188 : 26)
                .offset(y: isOpen ? -16 : -70)
                .rotationEffect(.degrees(isOpen ? -2.5 : 0))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.20), lineWidth: 2)
                .frame(width: 268, height: 188)

            Capsule()
                .fill(Color(red: 0.18, green: 0.10, blue: 0.08).opacity(0.34))
                .frame(width: 38, height: 174)
                .offset(x: -112)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Paper Color Presets

/// Case order is the picker order: distinctive colors first, the near-white
/// plain papers last.
enum DiaryPaperColor: String, CaseIterable, Identifiable {
    case eyeCare    // 护眼黄纸
    case kraft      // 牛皮纸
    case vintage    // 复古旧书
    case blush      // 樱粉
    case sky        // 天蓝
    case classic    // 经典纸张（原横线底色）
    case gridGray   // 方格灰（原方格底色）
    case dotGreen   // 点阵绿（原点阵底色）
    case minimal    // 极简灰白

    var id: String { rawValue }

    /// Themes beyond the basic four are Pro (see `AppFeatures.paperThemesRequirePro`).
    var isPremium: Bool {
        switch self {
        case .classic, .gridGray, .dotGreen, .minimal: false
        case .eyeCare, .kraft, .vintage, .blush, .sky: true
        }
    }

    func isLocked(isPro: Bool) -> Bool {
        isPremium && AppFeatures.paperThemesRequirePro && !isPro
    }

    var title: String {
        switch self {
        case .classic:  String(localized: "经典")
        case .gridGray: String(localized: "灰调")
        case .dotGreen: String(localized: "薄荷")
        case .eyeCare:  String(localized: "护眼")
        case .kraft:    String(localized: "牛皮纸")
        case .vintage:  String(localized: "复古")
        case .minimal:  String(localized: "极简")
        case .blush:    String(localized: "樱粉")
        case .sky:      String(localized: "天蓝")
        }
    }

    var background: Color {
        switch self {
        case .classic:  Color(red: 1.0,   green: 0.97,  blue: 0.90)   // 原横线底色
        case .gridGray: Color(red: 0.98,  green: 0.96,  blue: 0.91)   // 原方格底色
        case .dotGreen: Color(red: 0.96,  green: 0.98,  blue: 0.95)   // 原点阵底色
        case .eyeCare:  Color(red: 0.980, green: 0.953, blue: 0.827)   // #FAF3D3
        case .kraft:    Color(red: 0.839, green: 0.725, blue: 0.541)   // #D6B98A
        case .vintage:  Color(red: 0.898, green: 0.816, blue: 0.636)   // #E5D0A2
        case .minimal:  Color(red: 0.953, green: 0.953, blue: 0.945)   // #F3F3F1
        case .blush:    Color(red: 0.992, green: 0.914, blue: 0.914)   // #FDE9E9
        case .sky:      Color(red: 0.902, green: 0.945, blue: 0.984)   // #E6F1FB
        }
    }

    var uiBackground: UIColor {
        switch self {
        case .classic:  UIColor(red: 1.0,   green: 0.97,  blue: 0.90,  alpha: 1)
        case .gridGray: UIColor(red: 0.98,  green: 0.96,  blue: 0.91,  alpha: 1)
        case .dotGreen: UIColor(red: 0.96,  green: 0.98,  blue: 0.95,  alpha: 1)
        case .eyeCare:  UIColor(red: 0.980, green: 0.953, blue: 0.827, alpha: 1)
        case .kraft:    UIColor(red: 0.839, green: 0.725, blue: 0.541, alpha: 1)
        case .vintage:  UIColor(red: 0.898, green: 0.816, blue: 0.636, alpha: 1)
        case .minimal:  UIColor(red: 0.953, green: 0.953, blue: 0.945, alpha: 1)
        case .blush:    UIColor(red: 0.992, green: 0.914, blue: 0.914, alpha: 1)
        case .sky:      UIColor(red: 0.902, green: 0.945, blue: 0.984, alpha: 1)
        }
    }

    var swatch: Color { background }

    // 文字颜色：浅色 #2C2C2C，牛皮纸 #3A2E1F，复古 #4A3B2A
    var inkColor: Color {
        switch self {
        case .classic, .gridGray, .dotGreen, .eyeCare, .minimal, .blush, .sky:
            Color(red: 0.173, green: 0.173, blue: 0.173)   // #2C2C2C
        case .kraft:
            Color(red: 0.227, green: 0.180, blue: 0.122)   // #3A2E1F
        case .vintage:
            Color(red: 0.290, green: 0.231, blue: 0.165)   // #4A3B2A
        }
    }

    var uiInkColor: UIColor {
        switch self {
        case .classic, .gridGray, .dotGreen, .eyeCare, .minimal, .blush, .sky:
            UIColor(red: 0.173, green: 0.173, blue: 0.173, alpha: 1)
        case .kraft:
            UIColor(red: 0.227, green: 0.180, blue: 0.122, alpha: 1)
        case .vintage:
            UIColor(red: 0.290, green: 0.231, blue: 0.165, alpha: 1)
        }
    }

    /// 次要文字颜色（占位符等）
    var mutedInkColor: Color {
        inkColor.opacity(0.38)
    }

    /// 线条/纹理颜色
    var patternColor: Color {
        switch self {
        case .kraft:    Color(red: 0.58, green: 0.46, blue: 0.30).opacity(0.22)
        case .vintage:  Color(red: 0.55, green: 0.44, blue: 0.28).opacity(0.20)
        case .dotGreen: Color(red: 0.42, green: 0.54, blue: 0.40).opacity(0.16)
        case .gridGray: Color(red: 0.45, green: 0.58, blue: 0.66).opacity(0.14)
        case .blush:    Color(red: 0.78, green: 0.45, blue: 0.48).opacity(0.18)
        case .sky:      Color(red: 0.35, green: 0.55, blue: 0.75).opacity(0.18)
        default:        Color(red: 0.66, green: 0.50, blue: 0.36).opacity(0.16)
        }
    }

    /// 左侧装饰线颜色
    var accentColor: Color {
        switch self {
        case .classic:  Color(red: 0.80, green: 0.35, blue: 0.24)
        case .gridGray: Color(red: 0.45, green: 0.58, blue: 0.66)  // 原方格 accent
        case .dotGreen: Color(red: 0.42, green: 0.54, blue: 0.40)  // 原点阵 accent
        case .eyeCare:  Color(red: 0.72, green: 0.52, blue: 0.18)
        case .kraft:    Color(red: 0.60, green: 0.42, blue: 0.22)
        case .vintage:  Color(red: 0.62, green: 0.44, blue: 0.20)
        case .minimal:  Color(red: 0.58, green: 0.58, blue: 0.56)
        case .blush:    Color(red: 0.82, green: 0.42, blue: 0.47)
        case .sky:      Color(red: 0.32, green: 0.54, blue: 0.78)
        }
    }
}

enum DiaryPaperStyle: String, CaseIterable, Identifiable {
    case lined
    case grid
    case dotted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lined: String(localized: "横线")
        case .grid: String(localized: "方格")
        case .dotted: String(localized: "点阵")
        }
    }

    var icon: String {
        switch self {
        case .lined: "text.alignleft"
        case .grid: "square.grid.3x3"
        case .dotted: "circle.grid.3x3"
        }
    }

    var background: Color {
        switch self {
        case .lined:
            Color(red: 1.0, green: 0.97, blue: 0.90)
        case .grid:
            Color(red: 0.98, green: 0.96, blue: 0.91)
        case .dotted:
            Color(red: 0.96, green: 0.98, blue: 0.95)
        }
    }

    var accent: Color {
        switch self {
        case .lined:
            Color(red: 0.80, green: 0.35, blue: 0.24)
        case .grid:
            Color(red: 0.45, green: 0.58, blue: 0.66)
        case .dotted:
            Color(red: 0.42, green: 0.54, blue: 0.40)
        }
    }

    var showsMarginLine: Bool {
        self == .lined
    }

    @ViewBuilder
    func patternView(color: Color) -> some View {
        GeometryReader { geo in
            switch self {
            case .lined:
                let lineSpacing: CGFloat = 28
                let count = max(1, Int((geo.size.height - 46) / lineSpacing))
                VStack(spacing: lineSpacing - 1) {
                    ForEach(0..<count, id: \.self) { _ in
                        Rectangle()
                            .fill(color)
                            .frame(height: 1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 46)

            case .grid:
                let spacing: CGFloat = 23
                Canvas { context, size in
                    var horizontal = Path()
                    var y: CGFloat = spacing
                    while y < size.height {
                        horizontal.move(to: CGPoint(x: 0, y: y.rounded(.toNearestOrAwayFromZero) + 0.5))
                        horizontal.addLine(to: CGPoint(x: size.width, y: y.rounded(.toNearestOrAwayFromZero) + 0.5))
                        y += spacing
                    }
                    context.stroke(horizontal, with: .color(color.opacity(0.75)), lineWidth: 1)

                    var vertical = Path()
                    var x: CGFloat = spacing
                    while x < size.width {
                        vertical.move(to: CGPoint(x: x.rounded(.toNearestOrAwayFromZero) + 0.5, y: 0))
                        vertical.addLine(to: CGPoint(x: x.rounded(.toNearestOrAwayFromZero) + 0.5, y: size.height))
                        x += spacing
                    }
                    context.stroke(vertical, with: .color(color.opacity(0.62)), lineWidth: 1)
                }
                .frame(width: geo.size.width, height: geo.size.height)

            case .dotted:
                let dotSpacing: CGFloat = 21
                Canvas { context, size in
                    let dotSize: CGFloat = 3
                    var y: CGFloat = dotSpacing
                    while y < size.height {
                        var x: CGFloat = dotSpacing
                        while x < size.width {
                            let rect = CGRect(
                                x: x - dotSize / 2,
                                y: y - dotSize / 2,
                                width: dotSize,
                                height: dotSize
                            )
                            context.fill(Path(ellipseIn: rect), with: .color(color))
                            x += dotSpacing
                        }
                        y += dotSpacing
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

enum DiaryLayoutStyle: String, CaseIterable, Identifiable {
    case classic
    case timeline
    case inlineSticker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: String(localized: "经典")
        case .timeline: String(localized: "时间线")
        case .inlineSticker: String(localized: "内联")
        }
    }

    var icon: String {
        switch self {
        case .classic: "rectangle.split.2x1"
        case .timeline: "list.bullet.indent"
        case .inlineSticker: "text.insert"
        }
    }

    var contentHorizontalPadding: CGFloat {
        switch self {
        case .classic: 28
        case .timeline: 34
        case .inlineSticker: 24
        }
    }

    var textSize: CGFloat {
        switch self {
        case .classic: 18
        case .timeline: 17
        case .inlineSticker: 17
        }
    }

    var lineSpacing: CGFloat {
        switch self {
        case .classic: 7
        case .timeline: 7
        case .inlineSticker: 8
        }
    }

    var editorMinHeight: CGFloat {
        switch self {
        case .classic: 122
        case .timeline: 118
        case .inlineSticker: 200
        }
    }
}

/// Persists which days are marked "写好了" (keyed by start-of-day timestamp).
enum DiaryFinishedDays {
    private static let key = "finishedDiaryDayIDs"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    static func contains(_ date: Date) -> Bool {
        load().contains(dayID(for: date))
    }

    static func dayID(for date: Date) -> String {
        String(Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970))
    }

    static func remove(for date: Date) {
        var ids = load()
        guard ids.remove(dayID(for: date)) != nil else { return }
        save(ids)
    }
}

extension View {
    /// Small orange crown in the top-right corner marking a control with Pro options.
    func proCrownBadge(_ visible: Bool, size: CGFloat = 6.5) -> some View {
        overlay(alignment: .topTrailing) {
            if visible {
                Image(systemName: "crown.fill")
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(size * 0.4)
                    .background(Color(red: 0.95, green: 0.65, blue: 0.12), in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 1))
                    .offset(x: 1, y: -1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
