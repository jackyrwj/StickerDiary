import AVFoundation
import CoreImage
import MessageUI
import Network
import CoreImage.CIFilterBuiltins
import PhotosUI
import StoreKit
import SwiftUI
import UIKit
import Vision

struct DailyStickerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = StickerCameraModel()
    @State private var recentStickers: [(entry: StickerEntry, image: UIImage)] = []
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var showPhotosPicker = false
    @State private var sourceImage: UIImage?
    @State private var stickerImage: UIImage?
    @State private var isProcessing = false
    @State private var isBatchLoading = false
    @State private var errorMessage: String?
    @State private var isCameraMode = false
    @State private var showDiary = false
    @State private var showCalendar = false
    @State private var showStickerLibrary = false
    @State private var stickerLibraryTargetDate: Date?
    @State private var diaryEntries: [DiaryEntry] = []
    @State private var calendarRecords: [StickerCalendarRecord] = []
    @State private var diarySelectedDate: Date = .now
    @State private var activeBagDate: Date = .now
    @State private var isGeneratingDiary = false
    @State private var diaryGenerationError: String?
    @State private var diaryGenerationRevision = 0
    @State private var diaryGenerationToken = UUID()
    @State private var diaryGeneratedTitle: String?
    @State private var unlockedAchievement: AchievementUnlock?
    @State private var pendingAchievementUnlock: AchievementUnlock?
    @State private var pendingAchievementUnlockDate: Date?
    @State private var stickerRecognition: StickerRecognitionResult?
    @State private var showRecognitionReview = false
    @State private var pendingBatchImages: [UIImage] = []
    @State private var pendingBatchPhotoItems: [PhotosPickerItem] = []
    /// Images came from the share extension: backing out returns home, not to the camera.
    @State private var isSharedImport = false
    @State private var stickerProcessingPulse = false
    // Sticker id that should play the "stamp" animation when the library appears
    @State private var justStampedStickerID: String?
    @State private var previewedStickers: [RecentStickerPreview] = []
    @State private var previewedStickerID: String?
    @State private var showDeleteStickerConfirm = false
    @State private var homeSelectedDate: Date = .now
    @State private var showHome = true
    @State private var diaryReturnToCalendar = false
    @State private var pendingReviewAfterDiary = false
    @State private var returnToDiaryAfterCapture = false
    @State private var stickerCountBeforeDiaryCapture = 0
    @State private var calendarRefreshRevision = 0
    @State private var cameraActivationToken = UUID()
    @State private var showCameraPermissionAlert = false
    @State private var showPhotoPermissionAlert = false
    @State private var showStickerLimitPaywall = false
    @State private var showFirstLaunchPaywall = false
    @State private var activeAppCoachStep: AppCoachStep?
    @State private var isCoachWaitingForStickerCapture = false
    @State private var isCoachWaitingForDiaryAnimation = false
    @State private var shouldShowDiaryShareCoachAfterAchievement = false
    @AppStorage("hasSeenMainFlowCoachV1") private var hasSeenMainFlowCoach = false
    @AppStorage("shouldShowDiaryRegenerateHintAfterMainFlowCoachV1") private var shouldShowDiaryRegenerateHintAfterMainFlowCoach = false
    @AppStorage("hasShownFirstLaunchPaywallV1") private var hasShownFirstLaunchPaywall = false
    @AppStorage("didMigrateFirstLaunchPaywallV1") private var didMigrateFirstLaunchPaywall = false
    /// 英文版（手写日记）第一次点"写好了"后置为 true，回到首页放完礼花再清掉。
    @AppStorage("pendingFirstDiaryCelebrationV1") private var pendingFirstDiaryCelebration = false
    @AppStorage("hasCelebratedFirstDiaryV1") private var hasCelebratedFirstDiary = false
    /// Not read directly: observing it redraws when AI writing is toggled in Settings.
    @AppStorage(AppFeatures.aiDiaryEnabledKey) private var aiDiaryEnabled = true
    @State private var showFirstDiaryCelebration = false
    @State private var showWidgetGuide = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !previewedStickers.isEmpty {
                StickerPagerPreview(
                    items: previewedStickers,
                    selectedID: $previewedStickerID,
                    onClose: showStickerLibrary ? clearStickerPreview : closeRecentStickerPreview,
                    onDelete: { showDeleteStickerConfirm = true }
                )
                .alert("删除贴纸", isPresented: $showDeleteStickerConfirm) {
                    Button("删除", role: .destructive) {
                        deletePreviewedSticker()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("确定要删除这张贴纸吗？删除后无法恢复。")
                }
            } else if showHome {
                StickerHomeView(
                    recentStickers: recentStickers,
                    records: calendarRecords,
                    todayCount: todayStickerCount,
                    hasDiaryForSelectedDate: hasSavedDiaryRecord(for: homeSelectedDate),
                    selectedDate: $homeSelectedDate,
                    onCapture: { date in openCameraForDateFromHome(date) },
                    onDateSelected: { openDiaryForDate($0) },
                    onDiary: { date in openDiaryForDate(date) },
                    onCalendar: { openCalendarFromHome() },
                    onTodayBag: { openStickerLibraryFromHome() },
                    onStickerLibrary: { openStickerLibraryFromHome() },
                    activeCoachStep: activeAppCoachStep,
                    onCoachAction: handleCoachAction,
                    onCoachSkip: { finishMainFlowCoach() },
                    onStickerPreview: { items, selectedID in
                        openStickerPreview(items: items, selectedID: selectedID)
                    }
                )
            } else if showStickerLibrary {
                StickerLibraryPage(
                    importTargetDate: stickerLibraryTargetDate,
                    justAddedStickerID: justStampedStickerID,
                    scrollToDate: stickerLibraryTargetDate,
                    onImport: importLibraryStickersForDiary,
                    onClose: closeStickerLibrary,
                    onStampConsumed: { justStampedStickerID = nil },
                    onStickerTap: { entry, image in
                        openLibraryStickerPreview(entry: entry, image: image)
                    }
                )
            } else if showCalendar {
                StickerCalendarPage(
                    records: calendarRecords,
                    currentStickers: diaryStickerImages(),
                    refreshToken: calendarRefreshRevision,
                    onClose: {
                        showCalendar = false
                        showHome = true
                        presentFirstDiaryCelebrationIfNeeded()
                        presentFirstLaunchPaywallIfNeeded()
                    },
                    onOpenDiary: { date in
                        diaryReturnToCalendar = true
                        openDiaryForDate(date)
                    }
                )
            } else if showDiary {
                DiaryBookView(
                    entries: diaryEntries,
                    records: calendarRecords,
                    selectedDate: $diarySelectedDate,
                    isGenerating: isGeneratingDiary,
                    generationError: diaryGenerationError,
                    generationRevision: diaryGenerationRevision,
                    generatedTitle: diaryGeneratedTitle,
                    onArchive: saveDiaryRecord,
                    onAutosave: autosaveDiaryRecord,
                    onCaptureForDate: openCameraForDiaryDate,
                    onImportForDate: openStickerLibraryForDiaryDate,
                    onDateEntries: { date in
                        diaryEntriesForDate(date)
                    },
                    onRegenerate: regenerateDiaryForDate,
                    onClearDiary: clearDiaryForDate,
                    activeCoachStep: activeAppCoachStep,
                    onCoachAction: handleCoachAction,
                    onCoachSkip: { finishMainFlowCoach() },
                    onDiaryGenerationAnimationComplete: handleDiaryGenerationAnimationComplete,
                    onFinish: finishDiary,
                    onClose: closeDiaryScreen
                )
            } else if isProcessing || isBatchLoading {
                stickerProcessingWaitingView
            } else if showRecognitionReview, let stickerImage, let stickerRecognition {
                StickerRecognitionReview(
                    stickerImage: stickerImage,
                    sourceImage: sourceImage,
                    result: stickerRecognition,
                    onCancel: discardRecognizedSticker,
                    onConfirm: confirmRecognizedSticker
                )
            } else {
                cameraView
            }

            if let unlockedAchievement {
                AchievementUnlockOverlay(unlock: unlockedAchievement) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        self.unlockedAchievement = nil
                    }
                    continuePendingDiaryShareCoachIfNeeded()
                    requestReviewAfterAchievementIfNeeded(unlockedAchievement)
                    // 付费墙可能因为成就弹窗而被跳过，关掉后再检查一次。
                    presentFirstLaunchPaywallIfNeeded()
                }
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
                .zIndex(60)
            }

            if showFirstDiaryCelebration {
                CelebrationFireworksOverlay()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(70)
            }
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.86), value: stickerImage != nil)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: isProcessing || isBatchLoading)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: showHome)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: unlockedAchievement?.id)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if !didMigrateFirstLaunchPaywall {
                didMigrateFirstLaunchPaywall = true
                // 已走完引导的老用户升级上来：不补弹首启付费墙。
                if hasSeenMainFlowCoach { hasShownFirstLaunchPaywall = true }
            }
            startMainFlowCoachIfNeeded()
            // 引导结束后没回到首页就退出了 App：下次启动补弹。
            presentFirstLaunchPaywallIfNeeded()
            let initialContent = await Task.detached(priority: .utility) {
                SampleContentSeeder.seedIfNeeded()
                return (
                    records: DiaryRecordStore.shared.loadCalendarRecords(),
                    recentStickers: StickerStore.shared.loadRecentStickers(count: 6)
                )
            }.value
            guard !Task.isCancelled else { return }
            calendarRecords = initialContent.records
            recentStickers = initialContent.recentStickers
            syncDiarySnapshotsToWidget()
            importSharedImagesIfNeeded()
        }
        .alert("提示", isPresented: Binding(
            // The camera screen has its own alert; this one covers home after a shared import.
            get: { errorMessage != nil && showHome },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onOpenURL { url in
            guard url.scheme == ShareInbox.openURL.scheme else { return }
            importSharedImagesIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            // Fallback when the share extension couldn't open the app.
            if phase == .active { importSharedImagesIfNeeded() }
        }
        .onDisappear {
            stopCameraSession()
        }
        .onChange(of: selectedItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                await loadPhotos(newItems)
            }
        }
        .alert("需要打开相机权限", isPresented: $showCameraPermissionAlert) {
            Button("去设置") {
                openAppSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("拍照生成贴纸需要使用相机。请在系统设置里允许本 App 使用相机。")
        }
        .alert("需要打开相册权限", isPresented: $showPhotoPermissionAlert) {
            Button("去设置") {
                openAppSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("从照片导入贴纸需要访问相册。请在系统设置里允许本 App 读取照片。")
        }
        .sheet(isPresented: $showStickerLimitPaywall) {
            SubscriptionSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
                .presentationBackground(.white)
        }
        .sheet(isPresented: $showFirstLaunchPaywall) {
            SubscriptionSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
                .presentationBackground(.white)
        }
        .sheet(isPresented: $showWidgetGuide) {
            WidgetGuideSheet(isPrompt: true)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
                .presentationBackground(.white)
        }
    }

    /// 首次使用：新手引导（完成或跳过）结束、回到首页后弹一次付费墙。
    /// `allowOverDiary`：中文版引导在日记页走完最后一步，直接在日记页上弹。
    private func presentFirstLaunchPaywallIfNeeded(allowOverDiary: Bool = false) {
        guard !hasShownFirstLaunchPaywall, hasSeenMainFlowCoach else { return }
        // 有礼花要放时，等礼花结束再弹付费墙。
        let isCelebrating = showFirstDiaryCelebration || (pendingFirstDiaryCelebration && !hasCelebratedFirstDiary)
        let delay = isCelebrating && !reduceMotion ? 0.35 + Self.firstDiaryCelebrationDuration : 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !hasShownFirstLaunchPaywall,
                  hasSeenMainFlowCoach,
                  allowOverDiary ? showDiary : (showHome && !showDiary),
                  activeAppCoachStep == nil,
                  unlockedAchievement == nil
            else { return }
            hasShownFirstLaunchPaywall = true
            if !SubscriptionManager.shared.isProUser {
                showFirstLaunchPaywall = true
            }
        }
    }

    /// 解锁「一周记录者」「满月收藏馆」时再请求一次评分；和上次请求至少隔 30 天
    /// （系统本身每年最多弹 3 次）。
    private func requestReviewAfterAchievementIfNeeded(_ unlock: AchievementUnlock) {
        guard [7, 30].contains(unlock.tier.threshold) else { return }
        if let last = UserDefaults.standard.object(forKey: Self.lastReviewRequestKey) as? Date,
           Date().timeIntervalSince(last) < 30 * 24 * 60 * 60 { return }
        requestReviewAfterDiary(delay: 0.6)
    }

    private func requestReviewAfterDiary(delay: Double = 0.8) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 只有真正发出请求才记下“已请求”，没拿到前台窗口就留到下次关日记页再试。
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
            else { return }
            UserDefaults.standard.set(true, forKey: "hasRequestedReviewAfterDiary")
            UserDefaults.standard.set(Date(), forKey: Self.lastReviewRequestKey)
            AppStore.requestReview(in: scene)
        }
    }

    private func startMainFlowCoachIfNeeded() {
        guard !hasSeenMainFlowCoach else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
            guard !hasSeenMainFlowCoach, activeAppCoachStep == nil, showHome else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                activeAppCoachStep = .homeAddSticker
            }
        }
    }

    private func restartMainFlowCoach() {
        hasSeenMainFlowCoach = false
        isCoachWaitingForStickerCapture = false
        isCoachWaitingForDiaryAnimation = false
        shouldShowDiaryShareCoachAfterAchievement = false
        showHome = true
        showDiary = false
        showCalendar = false
        showStickerLibrary = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            withAnimation(.easeInOut(duration: 0.22)) {
                activeAppCoachStep = .homeAddSticker
            }
        }
    }

    private func finishMainFlowCoach(presentPaywallOverDiary: Bool = false) {
        let isStandaloneHint = activeAppCoachStep == .diaryRegenerate
        if !isStandaloneHint {
            hasSeenMainFlowCoach = true
        }
        isCoachWaitingForStickerCapture = false
        isCoachWaitingForDiaryAnimation = false
        shouldShowDiaryShareCoachAfterAchievement = false
        withAnimation(.easeInOut(duration: 0.2)) {
            activeAppCoachStep = nil
        }
        presentFirstLaunchPaywallIfNeeded(allowOverDiary: presentPaywallOverDiary)
    }

    private func handleCoachAction(_ step: AppCoachStep) {
        switch step {
        case .homeAddSticker:
            openCameraForDateFromHome(homeSelectedDate)
        case .homeWriteDiary:
            openDiaryForDate(homeSelectedDate)
        case .diaryGenerate:
            if AppFeatures.aiDiary {
                regenerateDiaryForDate(diarySelectedDate)
            } else {
                // The English app has no generation step; the diary page has
                // already opened the hand-written page, so the tour ends here.
                hasSeenMainFlowCoach = true
                finishMainFlowCoach()
            }
        case .diaryShare:
            hasSeenMainFlowCoach = true
            withAnimation(.easeInOut(duration: 0.18)) {
                activeAppCoachStep = .shareComplete
            }
        case .shareComplete:
            shouldShowDiaryRegenerateHintAfterMainFlowCoach = true
            // 引导走完：不等回首页，直接在日记页上弹付费墙。
            finishMainFlowCoach(presentPaywallOverDiary: true)
        case .diaryRegenerate:
            // 先触发重新生成（activeAppCoachStep 仍为 .diaryRegenerate，
            // 这样 regenerateDiaryForDate 能识别到引导态、跳过额度扣除）。
            attemptRegenerationFromCoach()
        case .settingsDiaryPrompt:
            withAnimation(.easeInOut(duration: 0.18)) {
                activeAppCoachStep = nil
            }
        }
    }

    private func handleDiaryGenerationAnimationComplete() {
        let willShowAchievement = presentPendingAchievementAfterDiaryAnimation()

        guard isCoachWaitingForDiaryAnimation else { return }
        isCoachWaitingForDiaryAnimation = false
        if willShowAchievement {
            shouldShowDiaryShareCoachAfterAchievement = true
        } else {
            scheduleDiaryShareCoach()
        }
    }

    private func closeDiaryScreen() {
        showDiary = false
        if diaryReturnToCalendar {
            diaryReturnToCalendar = false
            showCalendar = true
        } else {
            showHome = true
        }
        // 第一次写完自己的日记、关掉日记页时请求 App Store 评价（仅一次，中英版通用）。
        if !UserDefaults.standard.bool(forKey: "hasRequestedReviewAfterDiary"),
           isOwnSavedDiary(for: diarySelectedDate) {
            pendingReviewAfterDiary = true
        }
        let willShowFirstLaunchPaywall = !hasShownFirstLaunchPaywall && hasSeenMainFlowCoach
        let willCelebrate = pendingFirstDiaryCelebration && !hasCelebratedFirstDiary && !reduceMotion
        let willShowOtherPrompt = willShowFirstLaunchPaywall
            || pendingReviewAfterDiary
            || (pendingFirstDiaryCelebration && !hasCelebratedFirstDiary)
        if pendingReviewAfterDiary {
            pendingReviewAfterDiary = false
            if willShowFirstLaunchPaywall {
                // 刚关掉付费墙时不适合请求评分，留到下一次关日记页。
            } else {
                // 有礼花时等礼花放完再请求，避免评分弹窗盖在礼花上。
                requestReviewAfterDiary(delay: willCelebrate ? 0.35 + Self.firstDiaryCelebrationDuration : 0.8)
            }
        }
        presentFirstDiaryCelebrationIfNeeded()
        presentFirstLaunchPaywallIfNeeded()
        if !willShowOtherPrompt {
            presentWidgetGuideIfNeeded(afterDiaryFor: diarySelectedDate)
        }
    }

    /// A saved diary the user made themselves, not the seeded sample page.
    private func isOwnSavedDiary(for date: Date) -> Bool {
        guard hasSavedDiaryRecord(for: date) else { return false }
        if let sampleDate = SampleContentSeeder.sampleDiaryDate,
           Calendar.current.isDate(date, inSameDayAs: sampleDate) { return false }
        return true
    }

    /// Suggests the Home Screen widgets after the user has written a diary of their own,
    /// unless a widget is already there. Skipped when another prompt shows on this return.
    private func presentWidgetGuideIfNeeded(afterDiaryFor date: Date) {
        guard WidgetGuide.canPrompt, isOwnSavedDiary(for: date) else { return }
        Task { @MainActor in
            guard await WidgetGuide.installedKinds().isEmpty else { return }
            try? await Task.sleep(for: .seconds(0.6))
            guard showHome,
                  !showDiary,
                  activeAppCoachStep == nil,
                  unlockedAchievement == nil,
                  !showFirstDiaryCelebration,
                  !showFirstLaunchPaywall,
                  !showStickerLimitPaywall
            else { return }
            WidgetGuide.recordPrompt()
            showWidgetGuide = true
        }
    }

    /// 英文版没有引导完成卡片：写完第一篇日记、回到首页时放一轮礼花。
    private func presentFirstDiaryCelebrationIfNeeded() {
        guard pendingFirstDiaryCelebration, !hasCelebratedFirstDiary else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard pendingFirstDiaryCelebration, showHome, !showDiary else { return }
            pendingFirstDiaryCelebration = false
            hasCelebratedFirstDiary = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                showFirstDiaryCelebration = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstDiaryCelebrationDuration) {
                withAnimation(.easeOut(duration: 0.3)) {
                    showFirstDiaryCelebration = false
                }
            }
        }
    }

    private static let firstDiaryCelebrationDuration: Double = 3.0
    private static let lastReviewRequestKey = "lastReviewRequestDate"

    /// "写好了": the diary page already saved itself; hand-written diaries
    /// get their achievement check here (AI ones get it after generation).
    private func finishDiary(for date: Date) {
        if !AppFeatures.aiDiary, !hasCelebratedFirstDiary {
            pendingFirstDiaryCelebration = true
        }
        checkAndPresentAchievement(
            date: date,
            representativeSticker: StickerStore.shared.loadOrderedStickersForDate(date).first?.image
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            presentPendingAchievement()
        }
    }

    private func presentPendingAchievementAfterDiaryAnimation() -> Bool {
        guard showDiary else { return false }
        return presentPendingAchievement()
    }

    @discardableResult
    private func presentPendingAchievement() -> Bool {
        guard let unlock = pendingAchievementUnlock,
              let unlockDate = pendingAchievementUnlockDate else { return false }
        pendingAchievementUnlock = nil
        pendingAchievementUnlockDate = nil
        AchievementSystem.markUnlocked(threshold: unlock.tier.threshold, for: unlockDate)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            unlockedAchievement = unlock
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return true
    }

    private func continuePendingDiaryShareCoachIfNeeded() {
        guard shouldShowDiaryShareCoachAfterAchievement else { return }
        shouldShowDiaryShareCoachAfterAchievement = false
        scheduleDiaryShareCoach()
    }

    private func scheduleDiaryShareCoach() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard showDiary else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                activeAppCoachStep = .diaryShare
            }
        }
    }

    private var cameraView: some View {
        GeometryReader { geo in
            let horizontalPadding: CGFloat = 16
            let previewWidth = geo.size.width - horizontalPadding * 2
            let bottomBarHeight: CGFloat = 100
            let topInset: CGFloat = geo.safeAreaInsets.top + 12
            let bottomInset: CGFloat = geo.safeAreaInsets.bottom + 12
            let previewHeight = geo.size.height - topInset - bottomBarHeight - bottomInset - 24

            ZStack {
                Color(red: 0.96, green: 0.95, blue: 0.92)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    Spacer(minLength: 0).frame(height: topInset)

                    ZStack {
                        if camera.isReady {
                            CameraPreview(session: camera.session, isMirrored: camera.isUsingFrontCamera)
                        } else {
                            LinearGradient(
                                colors: [
                                    Color(red: 0.78, green: 0.78, blue: 0.72),
                                    Color(red: 0.48, green: 0.46, blue: 0.42)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            Image(systemName: "camera.metering.center.weighted")
                                .font(.system(size: 52, weight: .light))
                                .foregroundStyle(.white.opacity(0.72))
                        }

                        VStack {
                            HStack {
                                Spacer()
                                cameraSwitchButton
                            }
                            Spacer()
                        }
                        .padding(18)
                    }
                    .frame(width: previewWidth, height: previewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 18, y: 10)

                    cameraBottomBar
                        .padding(.horizontal, 40)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            }
        }
        .alert("提示", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var stickerProcessingWaitingView: some View {
        ZStack {
            Color(red: 0.95, green: 0.91, blue: 0.85)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer(minLength: 80)

                Image("AchieveTier5")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 118, height: 118)
                    .rotationEffect(.degrees(stickerProcessingPulse ? -4 : 4))
                    .scaleEffect(stickerProcessingPulse ? 1.06 : 0.96)
                    .shadow(
                        color: Color(red: 0.73, green: 0.43, blue: 0.17).opacity(0.22),
                        radius: stickerProcessingPulse ? 20 : 9,
                        y: stickerProcessingPulse ? 9 : 4
                    )
                    .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: stickerProcessingPulse)

                VStack(spacing: 8) {
                    Text(isBatchLoading ? "正在读取图片..." : "正在制作贴纸...")
                        .font(DiaryFont.display(size: 19, weight: .bold))
                        .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))

                    Text(isBatchLoading ? "把照片放进日记盒里" : "AI 正在把照片变成一枚小贴纸")
                        .font(DiaryFont.display(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 0.58, green: 0.52, blue: 0.46))
                }
                .opacity(stickerProcessingPulse ? 1 : 0.72)
                .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: stickerProcessingPulse)

                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(Color(red: 0.73, green: 0.43, blue: 0.17))
                            .frame(width: 7, height: 7)
                            .scaleEffect(stickerProcessingPulse ? 1.0 : 0.5)
                            .opacity(stickerProcessingPulse ? 1 : 0.3)
                            .animation(
                                .easeInOut(duration: 0.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.2),
                                value: stickerProcessingPulse
                            )
                    }
                }

                Spacer(minLength: 80)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
        }
        .onAppear { stickerProcessingPulse = true }
        .onDisappear {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                stickerProcessingPulse = false
            }
        }
    }

    private var cameraSwitchButton: some View {
        Button {
            camera.switchCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.56), in: Circle())
                .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(!camera.isReady || isProcessing || isBatchLoading)
        .opacity(camera.isReady ? 1 : 0.45)
        .accessibilityLabel("切换前后摄像头")
    }

    private var viewfinderOverlay: some View {
        ViewfinderCorners()
            .stroke(Color(red: 0.78, green: 0.42, blue: 0.28), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .frame(width: 252, height: 330)
            .shadow(color: .white.opacity(0.35), radius: 1)
    }

    private var cameraBottomBar: some View {
        HStack(alignment: .center) {
            Button {
                resetToCamera()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.38, green: 0.34, blue: 0.30))
                    .frame(width: 52, height: 52)
                    .background(Color(red: 0.92, green: 0.90, blue: 0.87), in: Circle())
            }

            Spacer()

            Button {
                camera.capturePhoto { image in
                    guard let image else {
                        errorMessage = String(localized: "当前设备无法拍照，请尝试从相册选择图片。")
                        return
                    }
                    let processingImage = image.resizedForStickerProcessing(maxDimension: 1200)
                    sourceImage = processingImage
                    process(processingImage)
                }
            } label: {
                Circle()
                    .fill(.white)
                    .frame(width: 72, height: 72)
                    .overlay(
                        Circle()
                            .stroke(Color(red: 0.22, green: 0.15, blue: 0.12), lineWidth: 4)
                            .frame(width: 82, height: 82)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            }
            .disabled(!camera.isReady || isProcessing || isBatchLoading)
            .opacity(camera.isReady ? 1 : 0.5)

            Spacer()

            Button {
                requestPhotoLibraryAccess()
            } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.38, green: 0.34, blue: 0.30))
                    .frame(width: 52, height: 52)
                    .background(Color(red: 0.92, green: 0.90, blue: 0.87), in: Circle())
            }
            .photosPicker(isPresented: $showPhotosPicker, selection: $selectedItems, maxSelectionCount: photoPickerSelectionLimit, matching: .images)
        }
    }

    private func requestPhotoLibraryAccess() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            showPhotosPicker = true
        case .notDetermined:
            Task {
                let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                await MainActor.run {
                    if result == .authorized || result == .limited {
                        showPhotosPicker = true
                    } else {
                        showPhotoPermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            showPhotoPermissionAlert = true
        @unknown default:
            showPhotoPermissionAlert = true
        }
    }

    private func requestCameraAccess(then action: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            action()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                await MainActor.run {
                    if granted {
                        action()
                    } else {
                        showCameraPermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            showCameraPermissionAlert = true
        @unknown default:
            showCameraPermissionAlert = true
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        errorMessage = nil
        isBatchLoading = true
        pendingBatchPhotoItems = Array(items.dropFirst())

        var remainingItems = items
        var firstImage: UIImage?
        var failedCount = 0

        while !remainingItems.isEmpty {
            let item = remainingItems.removeFirst()
            if let image = await Self.decodeSelectedPhoto(item) {
                firstImage = image
                break
            } else {
                failedCount += 1
                await MainActor.run {
                    pendingBatchPhotoItems = remainingItems
                }
            }
        }

        await MainActor.run {
            selectedItems = []
            isBatchLoading = false

            guard let firstImage else {
                pendingBatchPhotoItems = []
                errorMessage = String(localized: "无法读取这些图片。")
                return
            }

            sourceImage = firstImage
            if failedCount > 0 {
                errorMessage = String(localized: "有 \(failedCount) 张图片读取失败，其余图片会继续处理。")
            }
            process(firstImage, shouldContinueQueue: true)
        }
    }

    private static func decodeSelectedPhoto(_ item: PhotosPickerItem) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                return nil
            }
            return image.resizedForStickerProcessing(maxDimension: 1200)
        }.value
    }

    private static func decodeSelectedPhotos(_ items: [PhotosPickerItem]) async -> (images: [UIImage], failedCount: Int) {
        await Task.detached(priority: .userInitiated) {
            var images: [UIImage] = []
            var failedCount = 0

            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        failedCount += 1
                        continue
                    }
                    images.append(image.resizedForStickerProcessing(maxDimension: 1200))
                } catch {
                    failedCount += 1
                }
            }

            return (images, failedCount)
        }.value
    }

    private func enqueueBatchImages(_ images: [UIImage]) {
        pendingBatchImages.append(contentsOf: images)
        processNextQueuedImage()
    }

    /// Turns images from the share extension into stickers for today, using
    /// the same queue and review screen as picking photos from the library.
    private func importSharedImagesIfNeeded() {
        guard !ShareInbox.isEmpty else { return }
        let payloads = ShareInbox.takeAll()
        guard !payloads.isEmpty else { return }

        if activeAppCoachStep == .homeAddSticker {
            isCoachWaitingForStickerCapture = true
            activeAppCoachStep = nil
        }

        // Already mid-batch: just queue behind what's there.
        let isBusy = isProcessing || isBatchLoading || stickerImage != nil
        if !isBusy {
            clearStickerPreview()
            returnToDiaryAfterCapture = false
            diarySelectedDate = .now
            activeBagDate = .now
            showHome = false
            showDiary = false
            showCalendar = false
            showStickerLibrary = false
            stickerLibraryTargetDate = nil
            isCameraMode = false
            stopCameraSession()
            isSharedImport = true
            isBatchLoading = true
        }

        Task {
            let images = await Task.detached(priority: .userInitiated) {
                payloads.compactMap { UIImage(data: $0)?.resizedForStickerProcessing(maxDimension: 1200) }
            }.value
            await MainActor.run {
                if !isBusy { isBatchLoading = false }
                guard !images.isEmpty else {
                    errorMessage = String(localized: "无法读取这些图片。")
                    if !isBusy { returnToHomeAfterCapture() }
                    return
                }
                enqueueBatchImages(images)
            }
        }
    }

    private func processNextQueuedImage() {
        guard !isProcessing,
              stickerImage == nil else { return }

        // A shared or batched import can hold more photos than the page has
        // room for; stop before cutting out a sticker that can't be saved.
        if !pendingBatchImages.isEmpty || !pendingBatchPhotoItems.isEmpty,
           remainingStickerRoom(on: activeBagDate) == 0 {
            finishCaptureAtStickerLimit()
            return
        }

        if let nextImage = pendingBatchImages.first {
            pendingBatchImages.removeFirst()
            sourceImage = nextImage
            process(nextImage, shouldContinueQueue: true)
            return
        }

        guard let nextPhotoItem = pendingBatchPhotoItems.first else { return }

        pendingBatchPhotoItems.removeFirst()
        isBatchLoading = true
        Task {
            let image = await Self.decodeSelectedPhoto(nextPhotoItem)
            await MainActor.run {
                isBatchLoading = false
                guard let image else {
                    errorMessage = String(localized: "有 1 张图片读取失败，其余图片会继续处理。")
                    processNextQueuedImage()
                    return
                }

                sourceImage = image
                process(image, shouldContinueQueue: true)
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        errorMessage = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = String(localized: "无法读取这张图片。")
                return
            }
            let processingImage = image.resizedForStickerProcessing(maxDimension: 1200)
            sourceImage = processingImage
            process(processingImage)
        } catch {
            errorMessage = String(localized: "读取图片失败：\(error.localizedDescription)")
        }
    }

    private func process(_ image: UIImage, shouldContinueQueue: Bool = false) {
        isProcessing = true
        errorMessage = nil
        stickerImage = nil

        Task {
            do {
                let result = try await StickerMaker.makeSticker(from: image)
                await MainActor.run {

                    stickerImage = result.resizedForStickerProcessing(maxDimension: 720)
                    stickerRecognition = StickerRecognitionResult.makeDailySticker(for: activeBagDate)
                    showRecognitionReview = true
                    isProcessing = false
                    isCameraMode = false
                    stopCameraSession()
                }
            } catch {
                await MainActor.run {
                    errorMessage = String(localized: "抠图失败：请换一张主体更清晰、背景更简单的照片。")
                    isProcessing = false
                    if shouldContinueQueue {
                        processNextQueuedImage()
                    }
                    // A shared image has no camera to fall back to.
                    if isSharedImport, !isProcessing, !isBatchLoading, stickerImage == nil {
                        returnToHomeAfterCapture()
                    }
                }
            }
        }
    }

    private var todayStickerCount: Int {
        let calendar = Calendar.current
        return StickerStore.shared.loadEntries().filter { calendar.isDateInToday($0.date) }.count
    }

    private func openStickerPreview(items: [(entry: StickerEntry, image: UIImage)], selectedID: String) {
        previewedStickers = items.map { RecentStickerPreview(entry: $0.entry, image: $0.image) }
        previewedStickerID = selectedID
        showHome = false
        showDiary = false
        showCalendar = false
        showStickerLibrary = false
        stopCameraSession()
    }

    private func openLibraryStickerPreview(entry: StickerEntry, image: UIImage) {
        let allItems = StickerStore.shared.loadEntries().compactMap { item -> (entry: StickerEntry, image: UIImage)? in
            guard let image = StickerStore.shared.loadStickerImage(id: item.id) else { return nil }
            return (item, image)
        }
        previewedStickers = (allItems.isEmpty ? [(entry, image)] : allItems)
            .map { RecentStickerPreview(entry: $0.entry, image: $0.image) }
        previewedStickerID = entry.id
    }

    private func clearStickerPreview() {
        previewedStickers = []
        previewedStickerID = nil
    }

    private func closeRecentStickerPreview() {
        clearStickerPreview()
        showHome = true
    }

    private func startCameraWhenVisible() {
        let token = UUID()
        cameraActivationToken = token
        Task {
            await camera.configure()
            await MainActor.run {
                guard isCameraMode, cameraActivationToken == token else { return }
                camera.start()
            }
        }
    }

    private func stopCameraSession() {
        cameraActivationToken = UUID()
        camera.stop()
    }

    private func deletePreviewedSticker() {
        guard let selectedID = previewedStickerID,
              let selectedIndex = previewedStickers.firstIndex(where: { $0.id == selectedID }) else { return }
        let sticker = previewedStickers[selectedIndex]
        StickerStore.shared.deleteSticker(id: sticker.entry.id)
        syncCalendarRecordForStickerDate(sticker.entry.date)
        previewedStickers.remove(at: selectedIndex)
        previewedStickerID = previewedStickers.indices.contains(selectedIndex)
            ? previewedStickers[selectedIndex].id
            : previewedStickers.last?.id

        guard previewedStickers.isEmpty else { return }
        if showStickerLibrary {
            // Stay on library — it will reload
        } else {
            showHome = true
        }
    }

    private func syncCalendarRecordForStickerDate(_ date: Date) {
        let stickerCount = StickerStore.shared.orderedEntriesForDate(date).count
        let previewStickers = StickerStore.shared.firstOrderedSticker(for: date).map { [Optional($0.image)] } ?? []

        if let index = calendarRecords.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) {
            let isStickerOnlyRecord = calendarRecords[index].diaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || calendarRecords[index].diaryText == "每日贴纸"
            if stickerCount == 0,
               isStickerOnlyRecord {
                calendarRecords.remove(at: index)
            } else {
                calendarRecords[index].stickers = previewStickers
                calendarRecords[index].stickerCountOverride = stickerCount
            }
        } else if stickerCount > 0 {
            calendarRecords.append(
                StickerCalendarRecord(
                    date: date,
                    stickers: previewStickers,
                    diaryText: "每日贴纸",
                    stickerCountOverride: stickerCount
                )
            )
        }

        calendarRefreshRevision += 1
    }

    // MARK: Page sticker limit

    /// Free slots left on the page for `date`, or nil when the page has no limit.
    /// A page only uses its own day's stickers, so the day's count is the page's.
    private func remainingStickerRoom(on date: Date) -> Int? {
        PageStickerLimit.remaining { StickerStore.shared.orderedEntriesForDate(date).count }
    }

    /// Opens the paywall and returns false when `date` can't take another sticker.
    private func ensureStickerRoom(on date: Date) -> Bool {
        guard remainingStickerRoom(on: date) != 0 else {
            showStickerLimitPaywall = true
            return false
        }
        return true
    }

    private var photoPickerSelectionLimit: Int {
        max(1, min(20, remainingStickerRoom(on: activeBagDate) ?? 20))
    }

    /// Drops whatever is still queued, leaves the camera and opens the paywall.
    private func finishCaptureAtStickerLimit() {
        pendingBatchImages = []
        pendingBatchPhotoItems = []
        returnToHomeAfterCapture()
        showStickerLimitPaywall = true
    }

    private func openCameraFromHome() {
        guard ensureStickerRoom(on: .now) else { return }
        requestCameraAccess {
            openCameraFromHomeAfterPermission()
        }
    }

    private func openCameraFromHomeAfterPermission() {
        clearStickerPreview()
        returnToDiaryAfterCapture = false
        diarySelectedDate = .now
        activeBagDate = .now
        showHome = false
        showDiary = false
        showCalendar = false
        showStickerLibrary = false
        stickerLibraryTargetDate = nil
        isCameraMode = true
        startCameraWhenVisible()
    }

    private func openCameraForDateFromHome(_ date: Date) {
        guard ensureStickerRoom(on: date) else { return }
        requestCameraAccess {
            openCameraForDateFromHomeAfterPermission(date)
        }
    }

    private func openCameraForDateFromHomeAfterPermission(_ date: Date) {
        if activeAppCoachStep == .homeAddSticker {
            isCoachWaitingForStickerCapture = true
            withAnimation(.easeInOut(duration: 0.18)) {
                activeAppCoachStep = nil
            }
        }
        clearStickerPreview()
        returnToDiaryAfterCapture = false
        diarySelectedDate = date
        activeBagDate = date
        showHome = false
        showDiary = false
        showCalendar = false
        showStickerLibrary = false
        stickerLibraryTargetDate = nil
        isSharedImport = false
        isCameraMode = true
        startCameraWhenVisible()
    }

    private func openCalendarFromHome() {
        clearStickerPreview()
        showHome = false
        showCalendar = true
        showStickerLibrary = false
        stopCameraSession()
    }

    private func openStickerLibraryFromHome() {
        clearStickerPreview()
        showHome = false
        showDiary = false
        showCalendar = false
        stickerLibraryTargetDate = nil
        showStickerLibrary = true
        stopCameraSession()
    }

    private func closeStickerLibrary() {
        let targetDate = stickerLibraryTargetDate
        showStickerLibrary = false
        stickerLibraryTargetDate = nil
        if let targetDate {
            openDiaryForDate(targetDate)
        } else {
            showHome = true
        }
    }

    private func openDiaryForDate(_ date: Date) {
        clearStickerPreview()
        diarySelectedDate = date
        activeBagDate = date
        StickerStore.shared.preloadStickers(for: date)
        diaryEntries = diaryEntriesForDate(date)
        diaryGeneratedTitle = nil
        diaryGenerationError = nil
        isGeneratingDiary = false
        showHome = false
        showCalendar = false
        showStickerLibrary = false
        showDiary = true
        if activeAppCoachStep == .homeWriteDiary {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                guard showDiary, Calendar.current.isDate(diarySelectedDate, inSameDayAs: date) else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    activeAppCoachStep = .diaryGenerate
                }
            }
        } else {
            scheduleDiaryRegenerateHintAfterMainFlowIfNeeded(for: date)
        }
    }

    private func scheduleDiaryRegenerateHintAfterMainFlowIfNeeded(for date: Date) {
        guard AppFeatures.aiDiary,
              shouldShowDiaryRegenerateHintAfterMainFlowCoach,
              activeAppCoachStep == nil,
              hasSavedDiaryRecord(for: date),
              !StickerStore.shared.orderedEntriesForDate(date).isEmpty else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            guard shouldShowDiaryRegenerateHintAfterMainFlowCoach,
                  showDiary,
                  activeAppCoachStep == nil,
                  Calendar.current.isDate(diarySelectedDate, inSameDayAs: date) else { return }
            shouldShowDiaryRegenerateHintAfterMainFlowCoach = false
            withAnimation(.easeInOut(duration: 0.22)) {
                activeAppCoachStep = .diaryRegenerate
            }
        }
    }

    private func openCameraForDiaryDate(_ date: Date) {
        guard ensureStickerRoom(on: date) else { return }
        requestCameraAccess {
            openCameraForDiaryDateAfterPermission(date)
        }
    }

    private func openCameraForDiaryDateAfterPermission(_ date: Date) {
        clearStickerPreview()
        returnToDiaryAfterCapture = true
        stickerCountBeforeDiaryCapture = StickerStore.shared.orderedEntriesForDate(date).count
        diarySelectedDate = date
        activeBagDate = date
        showDiary = false
        showCalendar = false
        showStickerLibrary = false
        showHome = false
        isCameraMode = true
        startCameraWhenVisible()
    }

    private func openStickerLibraryForDiaryDate(_ date: Date) {
        clearStickerPreview()
        diarySelectedDate = date
        activeBagDate = date
        stickerLibraryTargetDate = date
        showDiary = false
        showCalendar = false
        showHome = false
        showStickerLibrary = true
        stopCameraSession()
    }

    private func recognitionResult(for entry: StickerEntry) -> StickerRecognitionResult {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"

        return StickerRecognitionResult(
            kind: .dailySticker,
            title: entry.title,
            subtitle: entry.subtitle,
            metrics: [
                RecognitionMetric(label: "日期", value: formatter.string(from: entry.date)),
                RecognitionMetric(label: "来源", value: "贴纸库"),
                RecognitionMetric(label: "类型", value: "贴纸"),
                RecognitionMetric(label: "状态", value: "已收藏")
            ],
            noteTitle: "preview",
            noteBody: "这张贴纸已经收进贴纸库，可以回到首页继续浏览最近收集。"
        )
    }

    private func importLibraryStickersForDiary(_ images: [UIImage], date: Date) {
        guard AppFeatures.aiDiary else {
            appendStickersToDiary(images, date: date)
            return
        }
        diarySelectedDate = date
        activeBagDate = date
        diaryEntries = []
        diaryGenerationError = nil
        showStickerLibrary = false
        stickerLibraryTargetDate = nil
        showDiary = true
        let sources = images.enumerated().map { index, image in
            DiaryStickerSource(title: String(localized: "贴纸 \(index + 1)"), subtitle: String(localized: "从贴纸库导入"), image: image)
        }
        generateDiary(for: date, sources: sources, force: true)
    }

    /// English app: imported stickers become new empty paragraphs after the
    /// ones already written, ready for the user's own words.
    private func appendStickersToDiary(_ images: [UIImage], date: Date) {
        let existing = diaryEntriesForDate(date)
        let added = images.enumerated().map { offset, image in
            let index = existing.count + offset
            return DiaryEntry(
                title: "",
                text: "",
                sticker: image,
                stickerSide: index % 2 == 0 ? .right : .left,
                hadStickerSlot: true
            )
        }
        diarySelectedDate = date
        activeBagDate = date
        diaryEntries = existing + added
        diaryGenerationError = nil
        isGeneratingDiary = false
        showStickerLibrary = false
        stickerLibraryTargetDate = nil
        showDiary = true
    }

    private func diaryEntriesForDate(_ date: Date) -> [DiaryEntry] {
        if let record = record(for: date) {
            // Sticker-only records (no real diary text) should show the empty diary state
            let rawText = record.diaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            let isStickerOnly = rawText.isEmpty || rawText == "每日贴纸" || rawText == "今日日记"
            if !isStickerOnly {
                let textEntries = makeDiaryEntries(fromRecord: record)
                if !textEntries.isEmpty {
                    return textEntries
                }
            }
        }
        return []
    }

    private func record(for date: Date) -> StickerCalendarRecord? {
        calendarRecords.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    private func hasSavedDiaryRecord(for date: Date) -> Bool {
        guard let record = record(for: date) else { return false }
        return isRealDiaryText(record.diaryText)
    }

    private func generateDiaryIfPossible(for date: Date) {
        let sources = diaryStickerSourcesForDate(date)
        guard !sources.isEmpty else {
            isGeneratingDiary = false
            return
        }
        generateDiary(for: date, sources: sources)
    }

    private func attemptRegenerationFromCoach() {
        regenerateDiaryForDate(diarySelectedDate)
    }

    private func regenerateDiaryForDate(_ date: Date) {
        let storedSources = diaryStickerSourcesForDate(date)
        let sources: [DiaryStickerSource]
        if !storedSources.isEmpty {
            sources = storedSources
        } else {
            sources = diaryEntries.compactMap { entry in
                guard let image = entry.sticker else { return nil }
                return DiaryStickerSource(title: entry.title, subtitle: String(localized: "当前日记贴纸"), image: image, stickerID: entry.stickerID)
            }
        }
        generateDiary(for: date, sources: sources, force: true)
    }

    private func diaryStickerSourcesForDate(_ date: Date) -> [DiaryStickerSource] {
        StickerStore.shared.loadOrderedStickersForDate(date)
            .map {
                DiaryStickerSource(title: $0.entry.title, subtitle: $0.entry.subtitle, image: $0.image, stickerID: $0.entry.id)
            }
    }

    private func clearDiaryForDate(_ date: Date) {
        diaryGenerationToken = UUID()
        isGeneratingDiary = false
        diaryGenerationError = nil
        diaryGeneratedTitle = nil
        diaryEntries = []
        calendarRecords.removeAll { Calendar.current.isDate($0.date, inSameDayAs: date) }
        DiaryRecordStore.shared.deleteDiary(for: date)
    }

    private func generateDiary(for date: Date, sources: [DiaryStickerSource], force: Bool = false) {
        // The English app is hand-written only; photos never go to the AI service.
        guard AppFeatures.aiDiary else {
            isGeneratingDiary = false
            return
        }
        guard !sources.isEmpty else {
            isGeneratingDiary = false
            diaryGenerationError = String(localized: "没有可用于生成的贴纸")
            return
        }
        guard force || !hasSavedDiaryRecord(for: date) else { return }
        // 引导流程里的生成（首次 + 重新生成）不计入、也不受每日免费额度限制。
        let isCoachGeneration = activeAppCoachStep == .diaryGenerate || activeAppCoachStep == .diaryRegenerate
        // Daily free quota check
        guard isCoachGeneration || DailyQuotaManager.canGenerate else {
            isGeneratingDiary = false
            diaryGenerationError = String(localized: "今日免费额度已用完（每天 \(DailyQuotaManager.maxFreeGenerations) 次），明天再来吧 ✨")
            return
        }
        if isCoachGeneration {
            // 主引导首次生成（.diaryGenerate）需要等动画结束后继续引导流程；
            // 独立提示的重新生成（.diaryRegenerate）不需要。
            if activeAppCoachStep == .diaryGenerate {
                isCoachWaitingForDiaryAnimation = true
            }
            // 立即隐藏引导卡片，避免与日记生成动画重叠。
            activeAppCoachStep = nil
        }
        let token = UUID()
        diaryGenerationToken = token
        isGeneratingDiary = true
        diaryGenerationError = nil

        Task {
            do {
                let generated = try await BailianDiaryGenerator().generateDiary(for: date, sources: sources)
                await MainActor.run {
                    guard diaryGenerationToken == token else { return }
                    if !isCoachGeneration {
                        DailyQuotaManager.consume()
                    }
                    diaryEntries = makeDiaryEntries(from: generated, sources: sources)
                    diaryGeneratedTitle = nil
                    saveDiaryEntriesRecord(for: date, entries: diaryEntries, title: nil)
                    checkAndPresentAchievement(date: date, representativeSticker: sources.first?.image)
                    ensureCoachFirstDiaryAchievementIfNeeded(date: date, representativeSticker: sources.first?.image)
                    isGeneratingDiary = false
                    diaryGenerationError = nil
                    diaryGenerationRevision += 1
                }
            } catch {
                await MainActor.run {
                    guard diaryGenerationToken == token else { return }
                    isGeneratingDiary = false
                    diaryGenerationError = userFacingDiaryGenerationError(for: error)
                    if isCoachWaitingForDiaryAnimation {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            activeAppCoachStep = nil
                        }
                    }
                }
            }
        }
    }

    private func userFacingDiaryGenerationError(for error: Error) -> String {
        switch error {
        case BailianDiaryError.invalidResponse:
            return String(localized: "这次没写好，再试一次")
        case BailianDiaryError.emptyContent:
            return String(localized: "这次没有写出来，再试一次")
        case BailianDiaryError.requestTimeout:
            return String(localized: "生成等太久了，请重试")
        case BailianDiaryError.invalidImage:
            return String(localized: "有张贴纸没处理好，换一张试试")
        case BailianDiaryError.missingAPIKey:
            return String(localized: "还没有配置 AI 写作")
        default:
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    return String(localized: "生成等太久了，请重试")
                case .notConnectedToInternet:
                    return String(localized: "请允许网络访问后重试")
                case .networkConnectionLost:
                    return String(localized: "网络不太稳定，请重试")
                default:
                    break
                }
            }
            return String(localized: "生成遇到点小问题，再试一次")
        }
    }

    private func resetToCamera() {
        let shouldReturnToDiary = returnToDiaryAfterCapture
        let targetDate = activeBagDate
        stickerImage = nil
        sourceImage = nil
        errorMessage = nil
        pendingBatchImages = []
        pendingBatchPhotoItems = []
        isBatchLoading = false
        stickerRecognition = nil
        showRecognitionReview = false

        isCameraMode = false
        showStickerLibrary = false
        stickerLibraryTargetDate = nil
        returnToDiaryAfterCapture = false
        stopCameraSession()

        if shouldReturnToDiary {
            openDiaryForDate(targetDate)
        } else {
            showHome = true
            // 取消相机、没有添加贴纸：不要推进引导，而是回到"添加贴纸"这一步，
            // 否则后续步骤会在没有贴纸的情况下乱套。
            restoreCoachAfterStickerCancelIfNeeded()
        }
    }

    private func restoreCoachAfterStickerCancelIfNeeded() {
        guard isCoachWaitingForStickerCapture else { return }
        isCoachWaitingForStickerCapture = false
        guard !hasSeenMainFlowCoach else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard showHome, activeAppCoachStep == nil, !hasSeenMainFlowCoach else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                activeAppCoachStep = .homeAddSticker
            }
        }
    }

    private func confirmRecognizedSticker() {
        guard remainingStickerRoom(on: activeBagDate) != 0 else {
            stickerImage = nil
            showRecognitionReview = false
            stickerRecognition = nil
            finishCaptureAtStickerLimit()
            return
        }

        // Persist the sticker and capture its store ID for later sync
        var savedID: String?
        if let image = stickerImage, let recognition = stickerRecognition {
            savedID = StickerStore.shared.saveSticker(
                image: image,
                title: recognition.title,
                subtitle: recognition.subtitle,
                date: activeBagDate
            )
            syncCalendarRecordForStickerDate(activeBagDate)
        }
        if let savedID { justStampedStickerID = savedID }

        stickerImage = nil
        showRecognitionReview = false
        stickerRecognition = nil


        // Keep working through a batch; return to home once the queue is empty.
        if !pendingBatchImages.isEmpty || !pendingBatchPhotoItems.isEmpty {
            processNextQueuedImage()
        } else {
            returnToHomeAfterCapture()
        }
    }

    private func discardRecognizedSticker() {
        stickerImage = nil
        sourceImage = nil
        stickerRecognition = nil
        showRecognitionReview = false

        if !pendingBatchImages.isEmpty || !pendingBatchPhotoItems.isEmpty {
            processNextQueuedImage()
        } else if isSharedImport {
            returnToHomeAfterCapture()
        } else {
            // Nothing left to review — go back to the camera to try again.
            isCameraMode = true
            showHome = false
            startCameraWhenVisible()
        }
    }

    private func returnToHomeAfterCapture() {
        let shouldReturnToDiary = returnToDiaryAfterCapture
        let targetDate = activeBagDate
        let previousCount = stickerCountBeforeDiaryCapture
        isSharedImport = false
        sourceImage = nil
        pendingBatchImages = []
        pendingBatchPhotoItems = []
        isCameraMode = false
        showDiary = false
        showCalendar = false
        showStickerLibrary = false
        stickerLibraryTargetDate = nil
        returnToDiaryAfterCapture = false
        stickerCountBeforeDiaryCapture = 0
        stopCameraSession()

        if shouldReturnToDiary {
            openDiaryForDate(targetDate)
            // If user added a new sticker while diary already existed, highlight the regenerate button
            let newCount = StickerStore.shared.orderedEntriesForDate(targetDate).count
            if AppFeatures.aiDiary, newCount > previousCount && hasSavedDiaryRecord(for: targetDate) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard showDiary, activeAppCoachStep == nil else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        activeAppCoachStep = .diaryRegenerate
                    }
                }
            }
        } else {
            showHome = true
            advanceCoachAfterStickerCaptureIfNeeded()
        }
    }

    private func advanceCoachAfterStickerCaptureIfNeeded() {
        guard isCoachWaitingForStickerCapture else { return }
        isCoachWaitingForStickerCapture = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            guard showHome else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                activeAppCoachStep = .homeWriteDiary
            }
        }
    }

    private func openStickerLibraryAfterCapture() {
        sourceImage = nil
        pendingBatchImages = []
        pendingBatchPhotoItems = []
        isCameraMode = false
        showHome = false
        showDiary = false
        showCalendar = false
        stickerLibraryTargetDate = nil
        showStickerLibrary = true
        stopCameraSession()
    }

    /// Full save: persists the diary and refreshes `calendarRecords`.
    /// Used on explicit save points (focus lost, close, date switch, share).
    private func saveDiaryRecord(for date: Date, from entries: [EditableDiaryEntry], title: String?) {
        guard let record = persistDiaryRecord(for: date, from: entries, title: title) else { return }
        if let index = calendarRecords.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: record.date) }) {
            calendarRecords[index] = record
        } else {
            calendarRecords.append(record)
        }
        syncDiarySnapshotsToWidget()
    }

    /// Autosave while typing: writes to disk only. Leaves `calendarRecords`
    /// alone so the whole home view isn't re-rendered on every typing pause;
    /// the next full save brings it up to date.
    private func autosaveDiaryRecord(for date: Date, from entries: [EditableDiaryEntry], title: String?) {
        persistDiaryRecord(for: date, from: entries, title: title)
    }

    private func saveDiaryEntriesRecord(for date: Date, entries: [DiaryEntry], title: String?) {
        saveDiaryRecord(for: date, from: entries.map(EditableDiaryEntry.init), title: title)
    }

    @discardableResult
    private func persistDiaryRecord(for date: Date, from entries: [EditableDiaryEntry], title: String?) -> StickerCalendarRecord? {
        let images: [UIImage?] = entries.map(\.sticker)
        let stickerSlots = entries.map { $0.sticker != nil }
        let hadStickerSlots = entries.map { $0.hadStickerSlot || $0.sticker != nil }
        let text = entries.map(\.text).joined(separator: "\n\n")
        let diaryTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = images.contains(where: { $0 != nil }) || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent else { return nil }
        let blocks = persistedDiaryBlocks(for: date, from: entries)

        DiaryRecordStore.shared.saveDiaryText(
            text,
            for: date,
            title: diaryTitle,
            stickerSlots: stickerSlots,
            hadStickerSlots: hadStickerSlots,
            blocks: blocks
        )
        return StickerCalendarRecord(
            date: date,
            stickers: images,
            diaryText: text,
            diaryTitle: diaryTitle?.isEmpty == false ? diaryTitle : nil,
            stickerSlots: stickerSlots,
            hadStickerSlots: hadStickerSlots,
            blocks: blocks
        )
    }

    private func persistedDiaryBlocks(for date: Date, from entries: [EditableDiaryEntry]) -> [PersistedDiaryBlock] {
        func resolvedID(_ image: UIImage?, _ id: String?) -> String? {
            if let id { return id }
            guard let image else { return nil }
            return StickerStore.shared.stickerID(matching: image, on: date)
        }

        return entries.map { entry in
            PersistedDiaryBlock(
                text: entry.text,
                stickerID: resolvedID(entry.sticker, entry.stickerID),
                hadStickerSlot: entry.hadStickerSlot || entry.sticker != nil,
                stickerOffsetX: Double(entry.stickerOffset.width),
                stickerOffsetY: Double(entry.stickerOffset.height),
                stickerScale: Double(entry.stickerScale),
                inlineStickers: entry.inlineStickers?.compactMap { placement in
                    resolvedID(placement.image, placement.stickerID).map {
                        PersistedInlineSticker(stickerID: $0, offset: placement.offset)
                    }
                }
            )
        }
    }

    private func syncDiarySnapshotsToWidget() {
        let records = calendarRecords
            .filter { isRealDiaryText($0.diaryText) }
            .map { record -> (date: Date, text: String, stickerID: String?) in
                let stickerID = StickerStore.shared.orderedEntriesForDate(record.date).first?.id
                return (date: record.date, text: record.diaryText, stickerID: stickerID)
            }
        StickerStore.syncDiaryToWidget(records: records)
    }

    private func checkAndPresentAchievement(date: Date, representativeSticker: UIImage?) {
        SampleContentSeeder.clearSampleMarkerIfNeeded(for: date)
        let count = AchievementSystem.currentMonthDiaryCount(records: calendarRecords, date: date)
        let alreadyUnlocked = AchievementSystem.unlockedThreshold(for: date)
        // Only trigger for a tier that hasn't been presented yet
        guard let tier = AchievementSystem.tiers.first(where: {
            $0.threshold == count && $0.threshold > alreadyUnlocked
        }) else { return }

        pendingAchievementUnlock = AchievementUnlock(tier: tier, representativeSticker: representativeSticker)
        pendingAchievementUnlockDate = date
    }

    private func ensureCoachFirstDiaryAchievementIfNeeded(date: Date, representativeSticker: UIImage?) {
        guard isCoachWaitingForDiaryAnimation,
              pendingAchievementUnlock == nil,
              let firstTier = AchievementSystem.tiers.first(where: { $0.threshold == 1 }) else { return }
        pendingAchievementUnlock = AchievementUnlock(tier: firstTier, representativeSticker: representativeSticker)
        pendingAchievementUnlockDate = date
    }

    private func diaryStickerImages() -> [UIImage] {
        StickerStore.shared.loadOrderedStickersForDate(activeBagDate).map(\.image)
    }

    private func makeDiaryEntries(from images: [UIImage]) -> [DiaryEntry] {
        let fallbackText = [
            String(localized: "把今天的一瞬间贴在这里，像给普通日子留下一个小小坐标。"),
            String(localized: "这张贴纸最像今天的心情，值得被认真收进日记里。"),
            String(localized: "后来又遇到一个新的片段，刚好适合写进今天的尾巴。"),
            String(localized: "这一页留给所有被看见、被保存、被记住的小事。")
        ]

        let sourceImages = images.isEmpty ? [] : images
        let count = max(sourceImages.count, 1)
        return (0..<count).map { index in
            DiaryEntry(
                title: index == 0 ? "今日日记" : "第 \(index + 1) 张贴纸",
                text: fallbackText[index % fallbackText.count],
                sticker: sourceImages.indices.contains(index) ? sourceImages[index] : nil,
                stickerSide: index % 2 == 0 ? .right : .left,
                hadStickerSlot: sourceImages.indices.contains(index)
            )
        }
    }

    private func makeDiaryEntries(fromRecord record: StickerCalendarRecord) -> [DiaryEntry] {
        if let blocks = record.blocks, !blocks.isEmpty {
            return makeDiaryEntries(fromBlocks: blocks, record: record)
        }

        let blocks = record.diaryText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .removingAdjacentDuplicateDiaryBlocks()

        let stickers = diaryStickers(for: record, entryCount: blocks.count)

        return blocks.enumerated().map { index, block in
            let body = diaryBodyRemovingLegacyTitle(from: block, index: index)
            return DiaryEntry(
                title: "",
                text: body,
                sticker: stickers.indices.contains(index) ? stickers[index]?.image : nil,
                stickerSide: index % 2 == 0 ? .right : .left,
                hadStickerSlot: record.hadStickerSlots.indices.contains(index)
                    ? record.hadStickerSlots[index]
                    : stickers.indices.contains(index) && stickers[index] != nil,
                stickerID: stickers.indices.contains(index) ? stickers[index]?.stickerID : nil
            )
        }
    }

    /// Restores paragraphs saved in the structured format, resolving sticker IDs
    /// against the stickers that still exist for that day.
    private func makeDiaryEntries(fromBlocks blocks: [PersistedDiaryBlock], record: StickerCalendarRecord) -> [DiaryEntry] {
        let sources = diaryStickerSourcesForDate(record.date)
        var imagesByID: [String: UIImage] = [:]
        for source in sources {
            if let id = source.stickerID { imagesByID[id] = source.image }
        }
        // Paragraphs whose sticker had no ID fall back to the legacy ordinal match.
        let legacyStickers = blocks.contains { $0.stickerID == nil && $0.hadStickerSlot }
            ? diaryStickers(for: record, entryCount: blocks.count)
            : []

        return blocks.enumerated().map { index, block in
            var sticker: UIImage?
            var stickerID: String?
            if let id = block.stickerID {
                sticker = imagesByID[id]
                stickerID = sticker == nil ? nil : id
            } else if legacyStickers.indices.contains(index), let legacy = legacyStickers[index] {
                sticker = legacy.image
                stickerID = legacy.stickerID
            }
            let inline = block.inlineStickers?.compactMap { placement -> InlineStickerPlacement? in
                guard let image = imagesByID[placement.stickerID] else { return nil }
                return InlineStickerPlacement(stickerID: placement.stickerID, image: image, offset: placement.offset)
            }
            return DiaryEntry(
                title: "",
                text: block.text,
                sticker: sticker,
                stickerSide: index % 2 == 0 ? .right : .left,
                hadStickerSlot: block.hadStickerSlot,
                stickerID: stickerID,
                stickerOffset: CGSize(width: block.stickerOffsetX, height: block.stickerOffsetY),
                stickerScale: CGFloat(block.stickerScale),
                inlineStickers: inline
            )
        }
    }

    private func diaryStickers(for record: StickerCalendarRecord, entryCount: Int) -> [DiaryStickerSource?] {
        let availableStickers = diaryStickerSourcesForDate(record.date)
        guard !record.stickerSlots.isEmpty else {
            if !record.stickers.isEmpty {
                return record.stickers.map { image in
                    image.map { DiaryStickerSource(title: "", subtitle: "", image: $0) }
                }
            }
            return (0..<entryCount).map { availableStickers.indices.contains($0) ? availableStickers[$0] : nil }
        }

        var availableIndex = 0
        return (0..<entryCount).map { index in
            guard record.stickerSlots.indices.contains(index), record.stickerSlots[index] else {
                return nil
            }
            guard availableStickers.indices.contains(availableIndex) else {
                return nil
            }
            let sticker = availableStickers[availableIndex]
            availableIndex += 1
            return sticker
        }
    }

    private func makeDiaryEntries(from generated: GeneratedDiary, sources: [DiaryStickerSource]) -> [DiaryEntry] {
        let entries = generated.entries.isEmpty
            ? [GeneratedDiary.Entry(title: "", text: generated.summary, stickerIndex: 0, inlineAnchor: nil)]
            : generated.entries
        var result: [DiaryEntry] = []

        for (offset, entry) in entries.enumerated() {
            guard offset < sources.count else { continue }
            let inlineAnchor = entry.inlineAnchor?.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = diaryBodyRemovingLegacyTitle(from: entry.text, index: offset)
            let indent = AppLocale.paragraphIndent
            let body: String
            if indent.isEmpty {
                body = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\u{3000}").union(.whitespaces))
            } else {
                body = raw.hasPrefix(indent) ? raw : indent + raw
            }

            result.append(DiaryEntry(
                title: "",
                text: body,
                sticker: sources[offset].image,
                stickerSide: result.count % 2 == 0 ? .right : .left,
                hadStickerSlot: true,
                inlineAnchor: inlineAnchor?.isEmpty == false ? inlineAnchor : nil,
                stickerID: sources[offset].stickerID
            ))
        }

        // Safety net: if the model returned fewer paragraphs than stickers,
        // append the leftover stickers so none of them get dropped.
        if result.count < sources.count {
            let leftoverFallbacks = [
                String(localized: "这张贴纸也想被记住，就一起收进今天的日记里。"),
                String(localized: "还有这一张，留作今天的另一个小注脚。"),
                String(localized: "顺手把它也贴上来，让今天更完整一点。")
            ].map { AppLocale.paragraphIndent + $0 }
            for index in result.count..<sources.count {
                let fallback = leftoverFallbacks[(index - 1) % leftoverFallbacks.count]
                result.append(DiaryEntry(
                    title: "",
                    text: fallback,
                    sticker: sources[index].image,
                    stickerSide: result.count % 2 == 0 ? .right : .left,
                    hadStickerSlot: true,
                    stickerID: sources[index].stickerID
                ))
            }
        }

        if result.isEmpty, let firstSource = sources.first {
            let fallbackRaw = generated.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let indent = AppLocale.paragraphIndent
            let fallbackBody = fallbackRaw.isEmpty ? String(localized: "今天收下了一张新的贴纸，先把这个小片段安静地放进日记里。") : fallbackRaw
            let fallbackText = fallbackBody.hasPrefix(indent) ? fallbackBody : indent + fallbackBody
            result.append(DiaryEntry(
                title: "",
                text: fallbackText,
                sticker: firstSource.image,
                stickerSide: .right,
                hadStickerSlot: true,
                stickerID: firstSource.stickerID
            ))
        }

        return result
    }

    private func diaryBodyRemovingLegacyTitle(from block: String, index: Int) -> String {
        var lines = block.components(separatedBy: .newlines)
        guard lines.count > 1 else {
            return block.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard isLegacyDiaryTitle(firstLine, index: index) else {
            return block.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        lines.removeFirst()
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? block.trimmingCharacters(in: .whitespacesAndNewlines) : body
    }

    private func isLegacyDiaryTitle(_ title: String, index: Int) -> Bool {
        guard !title.isEmpty else { return false }
        if title == "今日日记" || title == "今天的日记" || title == "第 \(index + 1) 段" {
            return true
        }
        if title.hasSuffix("的日记") || title.hasSuffix("日记") {
            return true
        }
        if title.range(of: #"^\d{4}年\d{1,2}月\d{1,2}日"#, options: .regularExpression) != nil {
            return true
        }
        if title.range(of: #"^\d{1,2}月\d{1,2}日"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

}

struct HeaderIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(red: 0.54, green: 0.48, blue: 0.44))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.52), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Home Page

struct RecentStickerPreview: Identifiable {
    var id: String { entry.id }
    let entry: StickerEntry
    let image: UIImage
}

struct StickerPagerPreview: View {
    let items: [RecentStickerPreview]
    @Binding var selectedID: String?
    let onClose: () -> Void
    let onDelete: () -> Void
    @State private var showShareSheet = false

    private let ink = Color(red: 0.22, green: 0.15, blue: 0.12)
    private let mutedInk = Color(red: 0.56, green: 0.50, blue: 0.46)

    private var currentIndex: Int {
        guard let selectedID,
              let index = items.firstIndex(where: { $0.id == selectedID }) else { return 0 }
        return index
    }

    private var selectedItem: RecentStickerPreview? {
        guard items.indices.contains(currentIndex) else { return items.first }
        return items[currentIndex]
    }

    var body: some View {
        ZStack {
            PaperTextureBackground()

            VStack(spacing: 0) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(ink)
                            .frame(width: 48, height: 48)
                            .background(.white.opacity(0.70), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("\(currentIndex + 1) / \(items.count)")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(mutedInk)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(.white.opacity(0.62), in: Capsule())

                    Spacer()

                    HStack(spacing: 10) {
                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(ink)
                                .frame(width: 48, height: 48)
                                .background(.white.opacity(0.70), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedItem == nil)

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(Color(red: 0.68, green: 0.18, blue: 0.14))
                                .frame(width: 48, height: 48)
                                .background(.white.opacity(0.70), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 54)

                TabView(selection: pageSelection) {
                    ForEach(items) { item in
                        stickerPage(item)
                            .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                if let selectedItem {
                    Text(previewCollectedText(for: selectedItem.entry))
                        .font(DiaryFont.display(size: 15, weight: .bold))
                        .foregroundStyle(mutedInk.opacity(0.72))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 34)
                    .transition(.opacity)
                }
            }
        }
        .onAppear {
            if selectedID == nil {
                selectedID = items.first?.id
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheetView(items: stickerShareItems)
        }
    }

    private var pageSelection: Binding<String> {
        Binding(
            get: { selectedID ?? items.first?.id ?? "" },
            set: { selectedID = $0 }
        )
    }

    private func stickerPage(_ item: RecentStickerPreview) -> some View {
        GeometryReader { geo in
            VStack {
                Spacer(minLength: 0)

                Image(uiImage: item.image)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: min(geo.size.width * 0.76, 310),
                        height: min(geo.size.height * 0.72, 390)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 12)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var stickerShareItems: [Any] {
        guard let selectedItem else { return [] }
        return [selectedItem.image]
    }

    private func previewCollectedText(for entry: StickerEntry) -> String {
        let time = AppLocale.string(from: entry.date, chinese: "M月d日 HH:mm", template: "MMMdjmm")
        return String(localized: "收集于 \(time)")
    }
}

struct AchievementTier: Identifiable {
    let threshold: Int
    let title: String
    let condition: String
    let imageName: String?

    init(threshold: Int, title: String, condition: String, imageName: String? = nil) {
        self.threshold = threshold
        self.title = title
        self.condition = condition
        self.imageName = imageName
    }

    var id: Int { threshold }
}

struct AchievementStatus {
    let diaryCount: Int
    let dayCount: Int
    let currentTier: AchievementTier
    let nextThreshold: Int
    let previousThreshold: Int
    let progress: CGFloat
    let representativeSticker: UIImage?

    func progress(to tier: AchievementTier) -> CGFloat {
        guard diaryCount < tier.threshold else { return 1 }
        let previous = AchievementSystem.threshold(before: tier.threshold)
        let span = max(tier.threshold - previous, 1)
        return min(max(CGFloat(diaryCount - previous) / CGFloat(span), 0), 1)
    }
}

struct AchievementUnlock: Identifiable, Equatable {
    let tier: AchievementTier
    let representativeSticker: UIImage?

    var id: Int { tier.threshold }

    static func == (lhs: AchievementUnlock, rhs: AchievementUnlock) -> Bool {
        lhs.id == rhs.id
    }
}

enum AchievementSystem {
    static let monthlyCap = 30
    private static let unlockedKey = "achievementUnlockedThreshold"

    /// The highest tier threshold already presented this month.
    static func unlockedThreshold(for date: Date = .now) -> Int {
        let dict = UserDefaults.standard.dictionary(forKey: unlockedKey) as? [String: Int] ?? [:]
        return dict[monthKey(for: date)] ?? 0
    }

    /// Record that a tier has been presented so it won't trigger again.
    static func markUnlocked(threshold: Int, for date: Date = .now) {
        var dict = UserDefaults.standard.dictionary(forKey: unlockedKey) as? [String: Int] ?? [:]
        let key = monthKey(for: date)
        dict[key] = max(dict[key] ?? 0, threshold)
        UserDefaults.standard.set(dict, forKey: unlockedKey)
    }

    private static func monthKey(for date: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }

    static let waitingTier = AchievementTier(
        threshold: 0,
        title: String(localized: "等待第一篇日记"),
        condition: String(localized: "本月生成第一篇日记。")
    )

    static let tiers: [AchievementTier] = [
        AchievementTier(threshold: 1, title: String(localized: "第一篇日记"), condition: String(localized: "本月生成 1 篇日记。"), imageName: "AchieveTier1"),
        AchievementTier(threshold: 3, title: String(localized: "记录起步"), condition: String(localized: "本月生成 3 篇日记。"), imageName: "AchieveTier2"),
        AchievementTier(threshold: 7, title: String(localized: "一周记录者"), condition: String(localized: "本月生成 7 篇日记。"), imageName: "AchieveTier3"),
        AchievementTier(threshold: 14, title: String(localized: "半月采集家"), condition: String(localized: "本月生成 14 篇日记。"), imageName: "AchieveTier4"),
        AchievementTier(threshold: 25, title: String(localized: "生活记录家"), condition: String(localized: "本月生成 25 篇日记。"), imageName: "AchieveTier5"),
        AchievementTier(threshold: 30, title: String(localized: "满月收藏馆"), condition: String(localized: "本月生成 30 篇日记。"), imageName: "AchieveTier6")
    ]

    static func status(diaryCount: Int, dayCount: Int, representativeSticker: UIImage?) -> AchievementStatus {
        let cappedCount = min(max(diaryCount, 0), monthlyCap)
        let currentTier = tiers.last(where: { cappedCount >= $0.threshold }) ?? waitingTier
        let nextThreshold = tiers.first(where: { $0.threshold > currentTier.threshold })?.threshold ?? monthlyCap
        let previousThreshold = threshold(before: nextThreshold)
        let span = max(nextThreshold - previousThreshold, 1)
        let progress = currentTier.threshold >= monthlyCap
            ? 1
            : min(max(CGFloat(cappedCount - previousThreshold) / CGFloat(span), 0), 1)

        return AchievementStatus(
            diaryCount: cappedCount,
            dayCount: dayCount,
            currentTier: currentTier,
            nextThreshold: nextThreshold,
            previousThreshold: previousThreshold,
            progress: progress,
            representativeSticker: representativeSticker
        )
    }

    static func threshold(before threshold: Int) -> Int {
        tiers.last(where: { $0.threshold < threshold })?.threshold ?? 0
    }

    static func currentMonthDiaryCount(records: [StickerCalendarRecord] = [], date: Date = .now) -> Int {
        let calendar = Calendar.current
        let diaryDays = records
            .filter {
                calendar.isDate($0.date, equalTo: date, toGranularity: .month)
                && isRealDiaryText($0.diaryText)
                && !SampleContentSeeder.isSampleDiary(on: $0.date)
            }
            .map { calendar.startOfDay(for: $0.date) }
        return min(Set(diaryDays).count, monthlyCap)
    }

    static func currentMonthProductionDayCount(records: [StickerCalendarRecord] = [], date: Date = .now) -> Int {
        currentMonthDiaryCount(records: records, date: date)
    }

    static func monthArchives(records: [StickerCalendarRecord], through endDate: Date = .now) -> [AchievementMonthArchive] {
        let calendar = Calendar.current
        let diaryRecords = records.filter { isRealDiaryText($0.diaryText) }
        guard let firstDate = diaryRecords.map(\.date).min() else { return [] }

        var month = calendar.date(from: calendar.dateComponents([.year, .month], from: firstDate)) ?? calendar.startOfDay(for: firstDate)
        let endMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: endDate)) ?? calendar.startOfDay(for: endDate)
        var archives: [AchievementMonthArchive] = []

        while month <= endMonth {
            archives.append(
                AchievementMonthArchive(
                    month: month,
                    count: currentMonthDiaryCount(records: records, date: month)
                )
            )
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = nextMonth
        }

        return archives
    }
}

struct AchievementMonthArchive: Identifiable {
    var id: Date { month }
    let month: Date
    let count: Int
}

enum AppCoachTarget: Hashable {
    case homeAddSticker
    case homeWriteDiary
    case diaryGenerate
    case diaryShare
    case shareComplete
    case diaryRegenerate
    case settingsDiaryPrompt
}

enum AppCoachStep: String, Equatable {
    case homeAddSticker
    case homeWriteDiary
    case diaryGenerate
    case diaryShare
    case shareComplete
    case diaryRegenerate
    case settingsDiaryPrompt

    var target: AppCoachTarget {
        switch self {
        case .homeAddSticker:
            return .homeAddSticker
        case .homeWriteDiary:
            return .homeWriteDiary
        case .diaryGenerate:
            return .diaryGenerate
        case .diaryShare:
            return .diaryShare
        case .shareComplete:
            return .shareComplete
        case .diaryRegenerate:
            return .diaryRegenerate
        case .settingsDiaryPrompt:
            return .settingsDiaryPrompt
        }
    }

    var title: String {
        switch self {
        case .homeAddSticker:
            return String(localized: "先添加一张贴纸")
        case .homeWriteDiary:
            return String(localized: "用贴纸写日记")
        case .diaryGenerate:
            return AppFeatures.aiDiary ? String(localized: "一键生成日记") : String(localized: "开始写这一页")
        case .diaryShare:
            return String(localized: "分享这篇日记")
        case .shareComplete:
            return String(localized: "第一篇日记完成啦")
        case .diaryRegenerate:
            return String(localized: "新贴纸已加入")
        case .settingsDiaryPrompt:
            return String(localized: "选择日记风格")
        }
    }

    var message: String {
        switch self {
        case .homeAddSticker:
            return String(localized: "点击这里拍照或选图，确认一张贴纸后回到首页。")
        case .homeWriteDiary:
            return String(localized: "贴纸准备好了，接下来把它写进今天。")
        case .diaryGenerate:
            return AppFeatures.aiDiary
                ? String(localized: "让 AI 根据今天的贴纸写一小段日记。")
                : String(localized: "每张贴纸都有自己的位置，写一句话，或者先跳过。")
        case .diaryShare:
            return String(localized: "生成完成啦，可以先看看分享预览。")
        case .shareComplete:
            return String(localized: "开始尽情探索贴纸日记吧。")
        case .diaryRegenerate:
            return String(localized: "点这里让 AI 结合所有贴纸重新写一篇日记。")
        case .settingsDiaryPrompt:
            return String(localized: "在这里可以按当天心情切换日记风格。")
        }
    }

    var buttonTitle: String {
        switch self {
        case .homeAddSticker:
            return String(localized: "添加贴纸")
        case .homeWriteDiary:
            return String(localized: "写日记")
        case .diaryGenerate:
            return AppFeatures.aiDiary ? String(localized: "生成日记") : String(localized: "开始写日记")
        case .diaryShare:
            return String(localized: "去分享")
        case .shareComplete:
            return String(localized: "知道了")
        case .diaryRegenerate:
            return String(localized: "重新生成")
        case .settingsDiaryPrompt:
            return String(localized: "去看看")
        }
    }
}

struct AppCoachFramePreferenceKey: PreferenceKey {
    static var defaultValue: [AppCoachTarget: CGRect] = [:]

    static func reduce(value: inout [AppCoachTarget: CGRect], nextValue: () -> [AppCoachTarget: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct AppCoachOriginPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero

    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

struct AppCoachOriginReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: AppCoachOriginPreferenceKey.self,
                value: proxy.frame(in: .global).origin
            )
        }
    }
}

extension View {
    func appCoachAnchor(_ target: AppCoachTarget) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AppCoachFramePreferenceKey.self,
                    value: [target: proxy.frame(in: .global)]
                )
            }
        }
    }
}

struct AppCoachOverlay: View {
    let step: AppCoachStep
    let targetFrame: CGRect?
    let globalOrigin: CGPoint
    let onAction: () -> Void
    let onSkip: () -> Void

    private let ink = Color(red: 0.24, green: 0.17, blue: 0.13)

    var body: some View {
        GeometryReader { geo in
            let overlayOrigin = geo.frame(in: .global).origin
            let fallbackFrame = CGRect(
                x: geo.size.width * 0.16,
                y: geo.size.height * 0.28,
                width: geo.size.width * 0.68,
                height: 112
            )
            let frame = targetFrame.map { normalizedFrame($0, relativeTo: overlayOrigin) } ?? fallbackFrame
            let spotlight = paddedFrame(frame, in: geo.size)

            ZStack {
                AppCoachCutoutShape(spotlight: spotlight, cornerRadius: cornerRadius(for: step.target))
                    .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))

                RoundedRectangle(cornerRadius: cornerRadius(for: step.target), style: .continuous)
                    .stroke(Color.white.opacity(0.92), lineWidth: 2)
                    .frame(width: spotlight.width, height: spotlight.height)
                    .position(x: spotlight.midX, y: spotlight.midY)
                    .shadow(color: .white.opacity(0.38), radius: 18)
                    .allowsHitTesting(false)

                coachBubble(geo: geo, target: spotlight)
            }
        }
        .ignoresSafeArea()
    }

    private func coachBubble(geo: GeometryProxy, target: CGRect) -> some View {
        let bubbleWidth = min(geo.size.width - 40, 330)
        let belowY = target.maxY + 18
        let aboveY = target.minY - 18
        let placeBelow = belowY + 158 < geo.size.height
        let centerY = placeBelow ? belowY + 79 : max(aboveY - 79, 118)
        let centerX = min(max(target.midX, bubbleWidth / 2 + 20), geo.size.width - bubbleWidth / 2 - 20)

        return VStack(alignment: .leading, spacing: 12) {
            Text(step.title)
                .font(DiaryFont.display(size: 20, weight: .black))
                .foregroundStyle(ink)

            Text(step.message)
                .font(DiaryFont.display(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.50, green: 0.43, blue: 0.38))
                .lineSpacing(4)

            HStack {
                Button("跳过", action: onSkip)
                    .font(DiaryFont.display(size: 14, weight: .bold))
                    .foregroundStyle(Color(red: 0.56, green: 0.50, blue: 0.46))

                Spacer()

                Button(action: onAction) {
                    Text(step.buttonTitle)
                        .font(DiaryFont.display(size: 15))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(ink, in: Capsule())
                }
            }
        }
        .padding(18)
        .frame(width: bubbleWidth)
        .background(Color(red: 0.98, green: 0.96, blue: 0.91), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 12)
        .position(x: centerX, y: centerY)
    }

    private func paddedFrame(_ frame: CGRect, in size: CGSize) -> CGRect {
        let padded = frame.insetBy(dx: -8, dy: -8)
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10)
        return padded.intersection(bounds)
    }

    private func normalizedFrame(_ frame: CGRect) -> CGRect {
        normalizedFrame(frame, relativeTo: globalOrigin)
    }

    private func normalizedFrame(_ frame: CGRect, relativeTo origin: CGPoint) -> CGRect {
        CGRect(
            x: frame.minX - origin.x,
            y: frame.minY - origin.y,
            width: frame.width,
            height: frame.height
        )
    }

    private func cornerRadius(for target: AppCoachTarget) -> CGFloat {
        switch target {
        case .homeAddSticker, .diaryGenerate:
            return 24
        case .homeWriteDiary:
            return 22
        case .diaryShare, .shareComplete:
            return 28
        case .diaryRegenerate:
            return 20
        case .settingsDiaryPrompt:
            return 22
        }
    }
}

struct AppCoachCutoutShape: Shape {
    let spotlight: CGRect
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(in: spotlight, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        return path
    }
}

struct StickerHomeView: View {
    let recentStickers: [(entry: StickerEntry, image: UIImage)]
    let records: [StickerCalendarRecord]
    let todayCount: Int
    let hasDiaryForSelectedDate: Bool
    @Binding var selectedDate: Date
    let onCapture: (Date) -> Void
    let onDateSelected: (Date) -> Void
    let onDiary: (Date) -> Void
    let onCalendar: () -> Void
    let onTodayBag: () -> Void
    let onStickerLibrary: () -> Void
    let activeCoachStep: AppCoachStep?
    let onCoachAction: (AppCoachStep) -> Void
    let onCoachSkip: () -> Void
    let onStickerPreview: ([(entry: StickerEntry, image: UIImage)], String) -> Void

    private let paper = Color(red: 0.97, green: 0.95, blue: 0.92)
    private let ink = Color(red: 0.22, green: 0.15, blue: 0.12)
    private let mutedInk = Color(red: 0.52, green: 0.46, blue: 0.42)
    private let cardBg = Color.white

    @State private var appeared = false
    @State private var selectedDateStickers: [(entry: StickerEntry, image: UIImage)] = []
    @State private var selectedDateCount: Int = 0
    @State private var showSettings = false
    @State private var showStickerLimitPaywall = false
    @ObservedObject private var subscription = SubscriptionManager.shared
    @State private var showAchievements = false
    @State private var isReorderingHeroStickers = false
    @State private var draggingHeroStickerID: String?
    @State private var draggedHeroStickerOffset: CGSize = .zero
    @State private var heroReorderOriginalIndex: Int?
    @State private var heroReorderTargetIndex: Int?
    @State private var coachFrames: [AppCoachTarget: CGRect] = [:]
    @State private var coachGlobalOrigin: CGPoint = .zero
    @State private var isCalendarExpanded = false

    private var isSelectedToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private var achievementStatus: AchievementStatus {
        AchievementSystem.status(
            diaryCount: AchievementSystem.currentMonthDiaryCount(records: records),
            dayCount: AchievementSystem.currentMonthDiaryCount(records: records),
            representativeSticker: recentStickers.first?.image
        )
    }

    private var recentDiaryRecords: [StickerCalendarRecord] {
        Array(records
            .filter { isRealDiaryText($0.diaryText) }
            .sorted { $0.date > $1.date }
            .prefix(8))
    }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 780
            // The ScrollView already insets its content below the safe area.
            let topPadding: CGFloat = compact ? 8 : 12
            let headerBottom = compact ? 12.0 : 16.0
            let weekBottom = compact ? 16.0 : 20.0
            let heroBottom = compact ? 14.0 : 16.0
            let actionsBottom = compact ? 14.0 : 16.0

            ZStack {
                PaperTextureBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Top: greeting + date
                        headerSection
                            .padding(.top, topPadding)
                            .padding(.bottom, headerBottom)

                        // Week strip
                        weekStrip
                            .padding(.bottom, weekBottom)

                        // Hero card
                        heroCard(compact: compact)
                            .padding(.horizontal, 20)
                            .padding(.bottom, heroBottom)

                        // Action cards row
                        actionCardsRow(compact: compact)
                            .padding(.horizontal, 20)
                            .padding(.bottom, actionsBottom)

                        // Recent diary previews
                        if !recentDiaryRecords.isEmpty {
                            recentDiarySection(compact: compact)
                                .padding(.bottom, max(geo.safeAreaInsets.bottom + 8, 16))
                        }

                        Spacer(minLength: 24)
                    }
                    .frame(width: geo.size.width, alignment: .top)
                }

                if showAchievements {
                    AchievementListPage(
                        status: achievementStatus,
                        records: records,
                        onClose: {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                                showAchievements = false
                            }
                        }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(18)
                }
            }
            .background(AppCoachOriginReader())
            .onPreferenceChange(AppCoachOriginPreferenceKey.self) { origin in
                coachGlobalOrigin = origin
            }
            .onPreferenceChange(AppCoachFramePreferenceKey.self) { frames in
                coachFrames = frames
            }
            .overlay {
                if let activeCoachStep, isHomeCoachStep(activeCoachStep) {
                    AppCoachOverlay(
                        step: activeCoachStep,
                        targetFrame: coachFrames[activeCoachStep.target],
                        globalOrigin: coachGlobalOrigin,
                        onAction: { onCoachAction(activeCoachStep) },
                        onSkip: onCoachSkip
                    )
                    .transition(.opacity)
                    .zIndex(30)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82).delay(0.1)) {
                appeared = true
            }
        }
        .task(id: Calendar.current.startOfDay(for: selectedDate)) {
            let target = selectedDate
            let stickers = await Task.detached(priority: .userInitiated) {
                StickerStore.shared.loadOrderedStickersForDate(target)
            }.value
            guard !Task.isCancelled else { return }
            selectedDateStickers = stickers
            selectedDateCount = stickers.count
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet {
                showSettings = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(44)
            .presentationBackground(.white)
        }
        .sheet(isPresented: $showStickerLimitPaywall) {
            SubscriptionSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
                .presentationBackground(.white)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(greetingText)
                    .font(DiaryFont.display(size: 17, weight: .semibold))
                    .foregroundStyle(self.mutedInk)

                Text(todayDateString)
                    .font(DiaryFont.display(size: 34, weight: .black))
                    .foregroundStyle(self.ink)
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(self.mutedInk)
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.52), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Week Strip

    private var weekStrip: some View {
        DiaryCalendarStrip(
            selectedDate: selectedDate,
            markedDays: DiaryCalendarStrip.diaryDays(in: records),
            isExpanded: $isCalendarExpanded
        ) { date in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                selectedDate = date
            }
        }
        .padding(.horizontal, 18)
    }

    // MARK: - Hero Card

    private func heroCard(compact: Bool) -> some View {
        let stickers = selectedDateStickers
        let count = selectedDateCount
        let hasStickers = count > 0
        let cardHeight: CGFloat = compact ? 164 : 178
        let previewHeight: CGFloat = compact ? 78 : 90
        let emptyBagSize: CGFloat = compact ? 76 : 84
        let titleSize: CGFloat = compact ? 20 : 21
        let subtitleSize: CGFloat = compact ? 13 : 14

        return ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.96, green: 0.91, blue: 0.84), Color(red: 0.92, green: 0.86, blue: 0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: cardHeight)

            VStack(alignment: .leading, spacing: compact ? 10 : 12) {
                if hasStickers {
                    heroStickerStrip(stickers: stickers, compact: compact)
                        .frame(height: previewHeight)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                } else {
                    HStack {
                        Spacer()
                        Image("StickerEmptyBag")
                            .resizable()
                            .scaledToFit()
                            .frame(width: emptyBagSize, height: emptyBagSize)
                            .rotationEffect(.degrees(-6))
                            .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
                        Spacer()
                    }
                    .frame(height: previewHeight)
                }

                // 英文文案较长：放得下时显示完整按钮，放不下时换成圆形 "+" 按钮，把宽度让给文字。
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        heroTextColumn(hasStickers: hasStickers, count: count, titleSize: titleSize, subtitleSize: subtitleSize)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        heroActions(stage: heroStage, iconOnly: false)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        heroTextColumn(hasStickers: hasStickers, count: count, titleSize: titleSize, subtitleSize: subtitleSize)
                        Spacer(minLength: 8)
                        heroActions(stage: heroStage, iconOnly: true)
                    }
                }
                .frame(height: compact ? 50 : 54)
            }
            .padding(.top, compact ? 12 : 14)
            .padding(.horizontal, 26)
            .padding(.bottom, compact ? 12 : 14)
            .frame(height: cardHeight)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .offset(y: appeared ? 0 : 30)
        .opacity(appeared ? 1 : 0)
    }

    private func heroTextColumn(hasStickers: Bool, count: Int, titleSize: CGFloat, subtitleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heroDateDisplay(date: selectedDate))
                .font(.system(size: subtitleSize - 1, weight: .semibold, design: .rounded))
                .foregroundStyle(self.mutedInk.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(hasStickers ? heroTitle(count: count) : heroEmptyTitle)
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                .foregroundStyle(self.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let upsell = heroStickerLimitUpsell {
                Button {
                    showStickerLimitPaywall = true
                } label: {
                    Label(upsell, systemImage: "crown.fill")
                        .font(.system(size: subtitleSize, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.86, green: 0.52, blue: 0.06))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.plain)
            } else {
                Text(heroSubtitle(hasStickers: hasStickers, count: count))
                    .font(.system(size: subtitleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(self.mutedInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// English free plan: free sticker spots left on the selected page, nil when unlimited.
    private var heroFreeStickerRoom: Int? {
        guard subscription.isProUser == false else { return nil }
        return PageStickerLimit.remaining { selectedDateCount }
    }

    /// Replaces the hero subtitle once the page is nearly full on the free plan.
    private var heroStickerLimitUpsell: String? {
        guard heroStage == .write || heroStage == .addSticker,
              let room = heroFreeStickerRoom, room <= 1 else { return nil }
        return room == 0
            ? String(localized: "这页贴满了 · 升级 Pro")
            : String(localized: "还剩 1 个位置 · 升级 Pro")
    }

    /// The day's next step drives the hero's primary button.
    private enum HeroStage {
        case addSticker, write, continueWriting, viewDiary
    }

    private var heroStage: HeroStage {
        if hasDiaryForSelectedDate {
            return DiaryFinishedDays.contains(selectedDate) ? .viewDiary : .continueWriting
        }
        return selectedDateCount > 0 ? .write : .addSticker
    }

    /// Shared by every hero button so the pair lines up.
    private let heroButtonHeight: CGFloat = 44

    @ViewBuilder
    private func heroActions(stage: HeroStage, iconOnly: Bool) -> some View {
        if stage == .addSticker {
            heroPrimaryButton(stage: stage, iconOnly: iconOnly)
                .appCoachAnchor(.homeAddSticker)
        } else {
            HStack(alignment: .center, spacing: 8) {
                heroAddStickerMiniButton
                    .appCoachAnchor(.homeAddSticker)
                heroPrimaryButton(stage: stage, iconOnly: iconOnly)
            }
        }
    }

    private func heroPrimaryButton(stage: HeroStage, iconOnly: Bool) -> some View {
        let title = heroPrimaryTitle(stage)
        let icon = heroPrimaryIcon(stage)
        return Button {
            if stage == .addSticker {
                onCapture(selectedDate)
            } else {
                onDiary(selectedDate)
            }
        } label: {
            Group {
                if iconOnly {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .black))
                        .frame(width: heroButtonHeight, height: heroButtonHeight)
                        .background(ink, in: Circle())
                } else {
                    Label(title, systemImage: icon)
                        .font(DiaryFont.display(size: 15))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 16)
                        .frame(height: heroButtonHeight)
                        .background(ink, in: Capsule())
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var heroAddStickerMiniButton: some View {
        Button {
            onCapture(selectedDate)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(ink)
                .frame(width: heroButtonHeight, height: heroButtonHeight)
                .background(Color.white.opacity(0.85), in: Circle())
                .overlay(Circle().stroke(ink.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                .proCrownBadge(heroFreeStickerRoom == 0, size: 9)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "添加贴纸"))
    }

    private func heroPrimaryTitle(_ stage: HeroStage) -> String {
        switch stage {
        case .addSticker: return String(localized: "添加贴纸")
        case .write: return String(localized: "写日记")
        case .continueWriting: return String(localized: "继续写")
        case .viewDiary: return String(localized: "查看日记")
        }
    }

    private func heroPrimaryIcon(_ stage: HeroStage) -> String {
        switch stage {
        case .addSticker: return "plus"
        case .write, .continueWriting: return "pencil"
        case .viewDiary: return "book"
        }
    }

    private func heroStickerStrip(stickers: [(entry: StickerEntry, image: UIImage)], compact: Bool) -> some View {
        let stickerSize: CGFloat = compact ? 64 : 72
        let itemWidth = stickerSize + 8

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(stickers.enumerated()), id: \.element.entry.id) { index, item in
                    Image(uiImage: item.image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: stickerSize, height: stickerSize)
                        .rotationEffect(.degrees(heroStickerRotation(index: index)))
                        .scaleEffect(draggingHeroStickerID == item.entry.id ? 1.08 : 1)
                        .opacity(isReorderingHeroStickers && draggingHeroStickerID != item.entry.id ? 0.76 : 1)
                        .shadow(
                            color: .black.opacity(draggingHeroStickerID == item.entry.id ? 0.22 : 0.12),
                            radius: draggingHeroStickerID == item.entry.id ? 15 : 10,
                            y: draggingHeroStickerID == item.entry.id ? 9 : 6
                        )
                        .offset(draggingHeroStickerID == item.entry.id ? draggedHeroStickerOffset : .zero)
                        .zIndex(draggingHeroStickerID == item.entry.id ? 5 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !isReorderingHeroStickers else { return }
                            onStickerPreview(stickers, item.entry.id)
                        }
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.55)
                                .onEnded { _ in
                                    beginHeroStickerReorder(id: item.entry.id)
                                }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard draggingHeroStickerID == item.entry.id else { return }
                                    updateHeroStickerDrag(
                                        id: item.entry.id,
                                        translation: value.translation,
                                        itemWidth: itemWidth
                                    )
                                }
                                .onEnded { _ in
                                    guard draggingHeroStickerID == item.entry.id else { return }
                                    endHeroStickerReorder()
                                }
                        )
                        .accessibilityLabel("预览贴纸")
                }
            }
            .padding(.trailing, 2)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: selectedDateStickers.map(\.entry.id))
        }
        .scrollDisabled(isReorderingHeroStickers)
    }

    private func beginHeroStickerReorder(id: String) {
        guard selectedDateStickers.count > 1 else { return }
        guard draggingHeroStickerID != id else { return }
        if draggingHeroStickerID == nil {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        isReorderingHeroStickers = true
        draggingHeroStickerID = id
        draggedHeroStickerOffset = .zero
        heroReorderOriginalIndex = selectedDateStickers.firstIndex { $0.entry.id == id }
        heroReorderTargetIndex = heroReorderOriginalIndex
    }

    private func updateHeroStickerDrag(id: String, translation: CGSize, itemWidth: CGFloat) {
        guard selectedDateStickers.count > 1 else { return }
        if draggingHeroStickerID == nil {
            beginHeroStickerReorder(id: id)
        }
        draggedHeroStickerOffset = translation
        guard let originalIndex = heroReorderOriginalIndex else {
            return
        }

        let desiredShift = Int((translation.width / itemWidth).rounded())
        let targetIndex = min(max(originalIndex + desiredShift, 0), selectedDateStickers.count - 1)
        if targetIndex != heroReorderTargetIndex {
            heroReorderTargetIndex = targetIndex
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func endHeroStickerReorder() {
        guard isReorderingHeroStickers else { return }
        if let originalIndex = heroReorderOriginalIndex,
           let targetIndex = heroReorderTargetIndex,
           originalIndex != targetIndex,
           selectedDateStickers.indices.contains(originalIndex),
           selectedDateStickers.indices.contains(targetIndex) {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                let item = selectedDateStickers.remove(at: originalIndex)
                selectedDateStickers.insert(item, at: targetIndex)
            }
        }

        StickerStore.shared.saveStickerOrder(ids: selectedDateStickers.map(\.entry.id), for: selectedDate)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        resetHeroStickerReorderState()
    }

    private func resetHeroStickerReorderState() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            draggedHeroStickerOffset = .zero
            draggingHeroStickerID = nil
            heroReorderOriginalIndex = nil
            heroReorderTargetIndex = nil
            isReorderingHeroStickers = false
        }
    }

    private func heroTitle(count: Int) -> String {
        return String(localized: "收集了 \(count) 张贴纸")
    }

    private var heroEmptyTitle: String {
        isSelectedToday ? String(localized: "今天还没有贴纸") : String(localized: "这天还没有贴纸")
    }

    private func heroSubtitle(hasStickers: Bool, count: Int) -> String {
        switch heroStage {
        case .viewDiary:
            return String(localized: "日记已写好 \u{2714}")
        case .continueWriting:
            return String(localized: "日记还没写完，继续写吧")
        case .write, .addSticker:
            break
        }
        if hasStickers {
            if count >= 2 {
                return isSelectedToday ? String(localized: "拍得够多了，可以写日记啦") : String(localized: "贴纸够多了，可以写日记啦")
            }
            return String(localized: "写几句，或者再拍几张")
        }
        return isSelectedToday ? String(localized: "记录一个小瞬间吧") : String(localized: "可以为这天补充贴纸")
    }

    private func heroDateDisplay(date: Date) -> String {
        let calendar = Calendar.current
        let dateText = AppLocale.string(from: date, chinese: "M月d日 EEEE", template: "MMMdEEEE")
        if calendar.isDateInToday(date) {
            return String(localized: "今天  \(dateText)")
        } else if calendar.isDateInYesterday(date) {
            return String(localized: "昨天  \(dateText)")
        }
        return dateText
    }

    private func heroDateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }
        return AppLocale.string(from: date, chinese: "d日", template: "MMMd")
    }

    // MARK: - Action Cards

    private func actionCardsRow(compact: Bool) -> some View {
        let status = achievementStatus

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            HomeActionCard(
                title: String(localized: "日记本"),
                subtitle: isSelectedToday ? String(localized: "今天的日记") : String(localized: "\(heroDateLabel(selectedDate))的日记"),
                stickerImage: "StickerDiary",
                compact: compact,
                action: { onDiary(selectedDate) }
            )
            .appCoachAnchor(.homeWriteDiary)
            HomeActionCard(
                title: String(localized: "日历"),
                subtitle: monthString,
                stickerImage: "StickerCalendar",
                compact: compact,
                action: onCalendar
            )
            HomeActionCard(
                title: String(localized: "成就"),
                subtitle: status.diaryCount == 0 ? String(localized: "待解锁") : status.currentTier.title,
                stickerImage: "StickerAchievement",
                compact: compact,
                action: {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        showAchievements = true
                    }
                }
            )
            HomeActionCard(
                title: String(localized: "贴纸库"),
                subtitle: String(localized: "查看全部"),
                stickerImage: "StickerLibraryIcon",
                compact: compact,
                action: onStickerLibrary
            )
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
    }

    private func isHomeCoachStep(_ step: AppCoachStep) -> Bool {
        step == .homeAddSticker || step == .homeWriteDiary
    }

    private func achievementSummaryCard(compact: Bool) -> some View {
        let status = achievementStatus

        return Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                showAchievements = true
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.92, green: 0.87, blue: 0.79))
                        .frame(width: compact ? 62 : 70, height: compact ? 62 : 70)

                    if let imgName = status.currentTier.imageName {
                        Image(imgName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: compact ? 52 : 58, height: compact ? 52 : 58)
                            .rotationEffect(.degrees(-5))
                            .shadow(color: .black.opacity(0.12), radius: 7, y: 4)
                    } else if status.diaryCount == 0 {
                        Image(systemName: "pencil.and.scribble")
                            .font(.system(size: compact ? 26 : 30, weight: .semibold))
                            .foregroundStyle(Color(red: 0.73, green: 0.43, blue: 0.17).opacity(0.6))
                    } else if let sticker = status.representativeSticker {
                        Image(uiImage: sticker)
                            .resizable()
                            .scaledToFit()
                            .frame(width: compact ? 52 : 58, height: compact ? 52 : 58)
                            .rotationEffect(.degrees(-5))
                            .shadow(color: .black.opacity(0.12), radius: 7, y: 4)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("成就")
                            .font(DiaryFont.display(size: 18, weight: .black))
                            .foregroundStyle(self.ink)

                        Text("\(status.diaryCount)/\(status.nextThreshold)")
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(Color(red: 0.73, green: 0.43, blue: 0.17))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Color.white.opacity(0.68), in: Capsule())
                    }

                    Text(status.diaryCount == 0 ? String(localized: "写一篇日记，开启成就之旅") : status.currentTier.title)
                        .font(DiaryFont.display(size: 14, weight: .bold))
                        .foregroundStyle(status.diaryCount == 0 ? Color(red: 0.73, green: 0.43, blue: 0.17).opacity(0.8) : self.mutedInk.opacity(0.82))
                        .lineLimit(1)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(red: 0.86, green: 0.82, blue: 0.75))
                            Capsule()
                                .fill(Color(red: 0.73, green: 0.43, blue: 0.17))
                                .frame(width: geo.size.width * status.progress)
                        }
                    }
                    .frame(height: 8)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(self.mutedInk.opacity(0.42))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, compact ? 14 : 16)
            .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.black.opacity(0.04), lineWidth: 1)
            }
        }
        .buttonStyle(HomeCardButtonStyle())
        .offset(y: appeared ? 0 : 18)
        .opacity(appeared ? 1 : 0)
    }

    // MARK: - Recent Diaries

    private func recentDiarySection(compact: Bool) -> some View {
        let columns = diaryPreviewColumns(from: recentDiaryRecords)

        return VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            HStack {
                Text("最近日记")
                    .font(DiaryFont.display(size: 20, weight: .bold))
                    .foregroundStyle(self.ink)

                Spacer()
            }
            .padding(.horizontal, 24)

            HStack(alignment: .top, spacing: 12) {
                ForEach(columns.indices, id: \.self) { columnIndex in
                    VStack(spacing: 12) {
                        ForEach(columns[columnIndex], id: \.date) { record in
                            diaryPreviewCard(record, compact: compact)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
        }
        .offset(y: appeared ? 0 : 16)
        .opacity(appeared ? 1 : 0)
    }

    private func diaryPreviewColumns(from records: [StickerCalendarRecord]) -> [[StickerCalendarRecord]] {
        var columns: [[StickerCalendarRecord]] = [[], []]
        for (index, record) in records.enumerated() {
            columns[index % 2].append(record)
        }
        return columns
    }

    private func diaryPreviewCard(_ record: StickerCalendarRecord, compact: Bool) -> some View {
        let stickers = diaryPreviewStickers(for: record.date)
        let lineLimit = diaryPreviewLineLimit(for: record)

        return Button {
            onDiary(record.date)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                if !stickers.isEmpty {
                    DiaryStickerPilePreview(images: stickers)
                        .frame(height: compact ? 106 : 122)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(red: 0.96, green: 0.92, blue: 0.86))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(diaryPreviewTitle(for: record))
                        .font(DiaryFont.display(size: 16))
                        .foregroundStyle(self.ink)
                        .lineLimit(1)

                    Text(diaryPreviewExcerpt(from: record.diaryText))
                        .font(DiaryFont.display(size: 13.5, weight: .medium))
                        .foregroundStyle(self.mutedInk.opacity(0.78))
                        .lineSpacing(4)
                        .lineLimit(lineLimit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 6) {
                    Text(recentDateString(record.date))
                    if record.stickerCount > 0 {
                        Circle()
                            .fill(self.mutedInk.opacity(0.22))
                            .frame(width: 4, height: 4)
                        Text("\(record.stickerCount) 张贴纸")
                    }
                }
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(self.mutedInk.opacity(0.48))
            }
            .padding(12)
            .background(cardBg.opacity(0.86), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.035), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 12, y: 6)
        }
        .buttonStyle(HomeCardButtonStyle())
        .accessibilityLabel("打开\(recentDateString(record.date))的日记")
    }

    // MARK: - Helpers

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 0..<6: return String(localized: "夜深了 🌙")
        case 6..<12: return String(localized: "早上好 ☀️")
        case 12..<14: return String(localized: "中午好 🌤")
        case 14..<18: return String(localized: "下午好 🧋")
        default: return String(localized: "晚上好 🌙")
        }
    }

    private var todayDateString: String {
        AppLocale.string(from: .now, chinese: "M月d日 EEEE", template: "MMMdEEEE")
    }

    private var monthString: String {
        AppLocale.string(from: .now, chinese: "M月", template: "MMMM")
    }

    private func recentDateString(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "今天") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }
        return AppLocale.string(from: date, chinese: "M/d", template: "Md")
    }

    private func diaryPreviewStickers(for date: Date) -> [UIImage] {
        StickerStore.shared.loadOrderedStickersForDate(date).prefix(5).map(\.image)
    }

    private func diaryPreviewTitle(for record: StickerCalendarRecord) -> String {
        let customTitle = record.diaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }
        return String(localized: "\(recentDateString(record.date))的日记")
    }

    private func diaryPreviewExcerpt(from text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return String(localized: "这一天还没有写下内容。") }

        let bodyLines: [String]
        if lines.count > 1, lines[0].count <= 12, !lines[0].contains("，"), !lines[0].contains("。") {
            bodyLines = Array(lines.dropFirst())
        } else {
            bodyLines = lines
        }

        return bodyLines.joined(separator: " ")
    }

    private func diaryPreviewLineLimit(for record: StickerCalendarRecord) -> Int {
        let day = Calendar.current.component(.day, from: record.date)
        return day.isMultiple(of: 2) ? 4 : 6
    }

    private func heroStickerRotation(index: Int) -> Double {
        let rotations: [Double] = [-4, 3, -3, 4, -2, 5, -3, 2]
        return rotations[index % rotations.count]
    }
}

struct HomeActionCard: View {
    let title: String
    let subtitle: String
    var stickerImage: String
    var compact: Bool = false
    let action: () -> Void

    private let ink = Color(red: 0.22, green: 0.15, blue: 0.12)
    private let mutedInk = Color(red: 0.52, green: 0.46, blue: 0.42)

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(DiaryFont.display(size: 18, weight: .bold))
                        .foregroundStyle(self.ink)

                    Text(subtitle)
                        .font(DiaryFont.display(size: 13, weight: .medium))
                        .foregroundStyle(self.mutedInk.opacity(0.72))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 22)
                .padding(.top, 22)
                .frame(maxHeight: .infinity, alignment: .top)

                Image(stickerImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: compact ? 58 : 66, height: compact ? 58 : 66)
                    .rotationEffect(.degrees(-6))
                    .offset(x: -14, y: -12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 94 : 104)
            .background(
                .white.opacity(0.82),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.black.opacity(0.04), lineWidth: 1)
            }
        }
        .buttonStyle(HomeCardButtonStyle())
    }
}

struct AchievementListPage: View {
    let status: AchievementStatus
    let records: [StickerCalendarRecord]
    let onClose: () -> Void

    private let paper = Color(red: 0.97, green: 0.95, blue: 0.92)
    private let ink = Color(red: 0.22, green: 0.15, blue: 0.12)
    private let mutedInk = Color(red: 0.52, green: 0.46, blue: 0.42)
    private let stampRed = Color(red: 0.60, green: 0.18, blue: 0.13)
    private let stampGold = Color(red: 0.75, green: 0.46, blue: 0.20)
    private let lockedInk = Color(red: 0.70, green: 0.67, blue: 0.62)

    private let columns = [
        GridItem(.flexible(), spacing: 22),
        GridItem(.flexible(), spacing: 22)
    ]

    private var monthArchives: [AchievementMonthArchive] {
        AchievementSystem.monthArchives(records: records)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AchievementPaperBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        header(safeTop: geo.safeAreaInsets.top)

                        LazyVGrid(columns: columns, alignment: .center, spacing: 34) {
                            ForEach(AchievementSystem.tiers) { tier in
                                achievementStamp(tier)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 42)

                        monthArchiveSection
                            .padding(.top, 34)
                            .padding(.horizontal, 24)
                            .padding(.bottom, max(geo.safeAreaInsets.bottom + 18, 32))
                    }
                }

                closeButton(safeTop: geo.safeAreaInsets.top)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.width > 90 && abs(value.translation.height) < 80 {
                        onClose()
                    }
                }
        )
    }

    private func header(safeTop: CGFloat) -> some View {
        VStack(spacing: 14) {
            Text("日记成就")
                .font(DiaryFont.display(size: 32, weight: .black))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .padding(.top, safeTop + 54)

            Text(status.diaryCount == 0 ? "写下第一篇日记，盖下第一枚成就章" : "本月已完成 \(status.diaryCount)/\(AchievementSystem.monthlyCap) 篇日记")
                .font(DiaryFont.display(size: 15, weight: .semibold))
                .foregroundStyle(mutedInk.opacity(0.72))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
    }

    private func closeButton(safeTop: CGFloat) -> some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(mutedInk)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.58), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.74), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")

                Spacer()
            }
            .padding(.leading, 22)
            .padding(.top, safeTop + 18)

            Spacer()
        }
    }

    private func achievementStamp(_ tier: AchievementTier) -> some View {
        let isUnlocked = status.diaryCount >= tier.threshold
        let progress = status.progress(to: tier)
        let titleColor = isUnlocked ? stampRed : lockedInk.opacity(0.42)
        let bodyColor = isUnlocked ? mutedInk.opacity(0.78) : lockedInk.opacity(0.54)

        return VStack(spacing: 12) {
            ZStack {
                if let imgName = tier.imageName {
                    Image(imgName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .saturation(isUnlocked ? 1 : 0)
                        .opacity(isUnlocked ? 1 : 0.24)
                        .rotationEffect(.degrees(isUnlocked ? -4 : 0))
                        .shadow(color: isUnlocked ? stampGold.opacity(0.24) : .clear, radius: 10, y: 6)
                        .offset(y: -10)
                } else {
                    Image(systemName: "seal")
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .offset(y: -10)
                }

                VStack(spacing: 0) {
                    Spacer()

                    Text(tier.title)
                        .font(DiaryFont.display(size: 16))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .frame(width: 146, height: 136)
            .background {
                Circle()
                    .fill(isUnlocked ? Color.white.opacity(0.12) : lockedInk.opacity(0.035))
                    .blur(radius: 0.5)
            }

            VStack(spacing: 5) {
                Text(tier.condition.replacingOccurrences(of: "。", with: ""))
                    .font(DiaryFont.display(size: 12, weight: .semibold))
                    .foregroundStyle(bodyColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(minHeight: 32)

                HStack(spacing: 7) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(lockedInk.opacity(0.16))
                            Capsule()
                                .fill(isUnlocked ? stampGold : lockedInk.opacity(0.42))
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 6)

                    Text("\(min(status.diaryCount, tier.threshold))/\(tier.threshold)")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(bodyColor)
                        .monospacedDigit()
                }
            }
            .frame(width: 146)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var monthArchiveSection: some View {
        if !monthArchives.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("月度收集")
                        .font(DiaryFont.display(size: 20, weight: .black))
                        .foregroundStyle(ink)

                    Text("从第一次生成日记的月份开始")
                        .font(DiaryFont.display(size: 12, weight: .semibold))
                        .foregroundStyle(mutedInk.opacity(0.66))
                }

                VStack(spacing: 12) {
                    ForEach(monthArchives) { archive in
                        monthArchiveRow(archive)
                    }
                }
            }
            .padding(18)
            .background(.white.opacity(0.36), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color(red: 0.50, green: 0.42, blue: 0.32).opacity(0.10), lineWidth: 1)
            }
        }
    }

    private func monthArchiveRow(_ archive: AchievementMonthArchive) -> some View {
        let progress = min(CGFloat(archive.count) / CGFloat(AchievementSystem.monthlyCap), 1)
        let isCurrentMonth = Calendar.current.isDate(archive.month, equalTo: .now, toGranularity: .month)
        let rowInk = archive.count > 0 ? ink : mutedInk.opacity(0.55)

        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(monthTitle(for: archive.month))
                    .font(DiaryFont.display(size: 15))
                    .foregroundStyle(rowInk)

                if isCurrentMonth {
                    Text("本月")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(stampGold.opacity(0.82), in: Capsule())
                }

                Spacer()

                Text("\(archive.count)/\(AchievementSystem.monthlyCap)")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(archive.count > 0 ? stampRed.opacity(0.82) : mutedInk.opacity(0.42))
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(lockedInk.opacity(0.13))
                    Capsule()
                        .fill(archive.count > 0 ? stampGold.opacity(0.86) : lockedInk.opacity(0.20))
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 7)
        }
    }

    private func monthTitle(for date: Date) -> String {
        AppLocale.string(from: date, chinese: "yyyy年M月", template: "yyyyMMMM")
    }
}

struct HomeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

enum RecognitionKind {
    case dailySticker
    case movieTicket
}

struct RecognitionMetric: Identifiable {
    let id = UUID()
    var label: String
    var value: String
}

struct StickerRecognitionResult {
    let kind: RecognitionKind
    var title: String
    var subtitle: String
    var metrics: [RecognitionMetric]
    var noteTitle: String
    var noteBody: String

    static func makeDailySticker(for date: Date) -> StickerRecognitionResult {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = AppLocale.locale

        // Count existing stickers for this date to generate a unique ordinal
        let existingCount = StickerStore.shared.orderedEntriesForDate(date).count
        let ordinal = existingCount + 1

        let title: String
        if calendar.isDateInToday(date) {
            title = String(localized: "今天第\(ordinal)张")
        } else {
            let day = AppLocale.string(from: date, chinese: "M月d日", template: "MMMd")
            title = String(localized: "\(day) 第\(ordinal)张")
        }

        formatter.dateFormat = "EEEE"
        let weekday = formatter.string(from: date)

        return StickerRecognitionResult(
            kind: .dailySticker,
            title: title,
            subtitle: weekday,
            metrics: [
                RecognitionMetric(label: "日期", value: calendar.isDateInToday(date) ? "今天" : "补录"),
                RecognitionMetric(label: "来源", value: "相机"),
                RecognitionMetric(label: "类型", value: "贴纸"),
                RecognitionMetric(label: "用途", value: "日记"),
                RecognitionMetric(label: "状态", value: "待收藏"),
                RecognitionMetric(label: "心情", value: "可编辑")
            ],
            noteTitle: "",
            noteBody: ""
        )
    }

    static let dailyStickerMock = StickerRecognitionResult(
        kind: .dailySticker,
        title: "今日贴纸",
        subtitle: "生活片段",
        metrics: [
            RecognitionMetric(label: "日期", value: "今天"),
            RecognitionMetric(label: "来源", value: "相机"),
            RecognitionMetric(label: "类型", value: "贴纸"),
            RecognitionMetric(label: "用途", value: "日记"),
            RecognitionMetric(label: "状态", value: "待收藏"),
            RecognitionMetric(label: "心情", value: "可编辑")
        ],
        noteTitle: "memo",
        noteBody: "这张照片已经被整理成贴纸。确认后会自动保存到贴纸库，也可以在日记里补上一段属于今天的记录。"
    )

    static let movieTicketMock = StickerRecognitionResult(
        kind: .movieTicket,
        title: "电影票",
        subtitle: "哈尔的移动城堡",
        metrics: [
            RecognitionMetric(label: "日期", value: "5月29日"),
            RecognitionMetric(label: "时间", value: "19:30"),
            RecognitionMetric(label: "影厅", value: "6号厅"),
            RecognitionMetric(label: "座位", value: "8排12座"),
            RecognitionMetric(label: "影院", value: "Mosh Cinema"),
            RecognitionMetric(label: "票价", value: "42元")
        ],
        noteTitle: "ticket",
        noteBody: "识别到这是一张电影票。后续接入大模型后，可以自动提取片名、影院、场次、座位和票价，并把它写进当天日记。"
    )
}

struct StickerRecognitionReview: View {
    let stickerImage: UIImage
    let sourceImage: UIImage?
    let result: StickerRecognitionResult
    var cancelSystemImage: String = "xmark"
    var confirmSystemImage: String = "checkmark"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var appeared = false

    private let bg = Color(red: 0.96, green: 0.94, blue: 0.91)
    private let ink = Color(red: 0.26, green: 0.20, blue: 0.17)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Center — sticker showcase
                Image(uiImage: stickerImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 320)
                    .shadow(color: .black.opacity(0.15), radius: 24, y: 16)
                    .scaleEffect(appeared ? 1 : 0.8)
                    .opacity(appeared ? 1 : 0)

                Spacer(minLength: 60)

                // Action buttons — cancel (✕/🗑) and confirm (✓)
                HStack(spacing: 48) {
                    Button(action: onCancel) {
                        Image(systemName: cancelSystemImage)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(self.ink.opacity(0.6))
                            .frame(width: 64, height: 64)
                            .background(.white.opacity(0.78), in: Circle())
                    }

                    Button(action: onConfirm) {
                        Image(systemName: confirmSystemImage)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(ink, in: Circle())
                            .shadow(color: ink.opacity(0.25), radius: 12, y: 6)
                    }
                }
                .padding(.bottom, 60)
            }

        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                appeared = true
            }
        }
    }
}

struct StickerDeleteTarget: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "trash.fill" : "trash")
                .font(.system(size: 22, weight: .bold))

            Text(isActive ? "松手删除" : "拖到这里删除")
                .font(DiaryFont.display(size: 16, weight: .bold))
        }
        .foregroundStyle(isActive ? .white : Color(red: 0.48, green: 0.12, blue: 0.09))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(isActive ? Color(red: 0.78, green: 0.18, blue: 0.12) : Color.white.opacity(0.88))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(isActive ? Color.white.opacity(0.62) : Color(red: 0.78, green: 0.18, blue: 0.12).opacity(0.30), lineWidth: 2)
        }
        .scaleEffect(isActive ? 1.08 : 1)
    }
}

struct CircularTrashDeleteTarget: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? Color(red: 0.18, green: 0.16, blue: 0.15) : Color.white.opacity(0.92))
                .shadow(color: .black.opacity(isActive ? 0.18 : 0.08), radius: isActive ? 18 : 10, y: isActive ? 10 : 5)

            Image(systemName: isActive ? "trash.fill" : "trash")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(isActive ? .white : .black)
        }
        .overlay {
            Circle()
                .stroke(.white.opacity(isActive ? 0.46 : 0.70), lineWidth: 1.5)
        }
        .scaleEffect(isActive ? 1.14 : 1)
    }
}

struct StickerCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.88), in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.92), lineWidth: 2)
                }
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}

struct StickerPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let closeSystemImage: String
    let onClose: () -> Void
    /// Overrides the rounded title face, e.g. the diary page's handwriting date.
    var titleFont: Font? = nil
    @ViewBuilder var actions: () -> Actions

    private let ink = Color(red: 0.24, green: 0.17, blue: 0.14)
    private let mutedInk = Color(red: 0.54, green: 0.48, blue: 0.44)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onClose) {
                Image(systemName: closeSystemImage)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(self.mutedInk)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.52), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Text(title)
                        .font(titleFont ?? DiaryFont.display(size: 34))
                        .foregroundStyle(self.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 10)

                    actions()
                }

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DiaryFont.display(size: 15, weight: .semibold))
                        .foregroundStyle(self.mutedInk.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }
        }
    }
}

struct HeaderPillButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(DiaryFont.display(size: 13))
                .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.white.opacity(0.74), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct DiaryEntry: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let sticker: UIImage?
    let stickerSide: StickerSide
    var hadStickerSlot: Bool = false
    var inlineAnchor: String? = nil
    var stickerID: String? = nil
    var stickerOffset: CGSize = .zero
    var stickerScale: CGFloat = 1
    var inlineStickers: [InlineStickerPlacement]? = nil

    enum StickerSide {
        case left
        case right
    }
}

func joinedDiaryText(title: String, text: String) -> String {
    [title, text]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

func normalizedDiaryTitleAndText(title: String, text: String) -> (title: String, text: String) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let compactTitle = trimmedTitle.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    let compactText = trimmedText.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)

    if !trimmedTitle.isEmpty,
       !trimmedText.isEmpty,
       (compactText == compactTitle || (compactTitle.count >= 10 && compactText.hasPrefix(compactTitle))) {
        return ("", trimmedText)
    }

    return (trimmedTitle, trimmedText)
}

extension Array where Element == String {
    func removingAdjacentDuplicateDiaryBlocks() -> [String] {
        var result: [String] = []
        var previousCompact = ""

        for block in self {
            let compact = block.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            guard !compact.isEmpty else { continue }
            if compact != previousCompact {
                result.append(block)
                previousCompact = compact
            }
        }

        return result
    }
}

struct DiaryStickerSource {
    let title: String
    let subtitle: String
    let image: UIImage
    var stickerID: String? = nil
}

/// A sticker placed inside the text of the inline layout.
/// `offset` is a UTF-16 offset into the owning paragraph's text.
struct InlineStickerPlacement: Identifiable, Equatable {
    var id = UUID()
    var stickerID: String?
    var image: UIImage
    var offset: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.stickerID == rhs.stickerID && lhs.offset == rhs.offset && lhs.image === rhs.image
    }
}

/// A sticker belonging to the diary's date, with its store ID when known.
struct DiaryStickerOption: Identifiable {
    let id: String
    let stickerID: String?
    let image: UIImage

    static func forDate(_ date: Date) -> [DiaryStickerOption] {
        StickerStore.shared.loadOrderedStickersForDate(date).map {
            DiaryStickerOption(id: $0.entry.id, stickerID: $0.entry.id, image: $0.image)
        }
    }
}

struct GeneratedDiary: Decodable {
    var title: String
    var summary: String
    var entries: [Entry]

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    }

    struct Entry: Decodable {
        var title: String
        var text: String
        var stickerIndex: Int?
        var inlineAnchor: String?

        enum CodingKeys: String, CodingKey {
            case title
            case text
            case content
            case body
            case paragraph
            case stickerIndex
            case index
            case inlineAnchor
        }

        init(title: String, text: String, stickerIndex: Int?, inlineAnchor: String?) {
            self.title = title
            self.text = text
            self.stickerIndex = stickerIndex
            self.inlineAnchor = inlineAnchor
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            text = try container.decodeIfPresent(String.self, forKey: .text)
                ?? container.decodeIfPresent(String.self, forKey: .content)
                ?? container.decodeIfPresent(String.self, forKey: .body)
                ?? container.decodeIfPresent(String.self, forKey: .paragraph)
                ?? ""
            stickerIndex = try container.decodeIfPresent(Int.self, forKey: .stickerIndex)
                ?? container.decodeIfPresent(Int.self, forKey: .index)
            inlineAnchor = try container.decodeIfPresent(String.self, forKey: .inlineAnchor)
        }
    }
}

enum BailianDiaryError: LocalizedError {
    case missingAPIKey
    case invalidImage
    case invalidResponse
    case emptyContent
    case requestTimeout

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(localized: "还没有配置 API Key，请到设置里填写")
        case .invalidImage:
            return String(localized: "图片处理失败，请重试")
        case .invalidResponse:
            return String(localized: "AI 返回内容异常，请重试")
        case .emptyContent:
            return String(localized: "AI 暂时没有灵感，请重试")
        case .requestTimeout:
            return String(localized: "生成超时，请重试")
        }
    }
}

/// 用 NWPathMonitor 等待网络变为可用。首次请求触发系统授权弹窗后，
/// 用户点「允许」会让网络变为可用，从而可以立即自动重试。
enum NetworkReachability {
    private final class WaitState: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let monitor: NWPathMonitor
        private let continuation: CheckedContinuation<Bool, Never>

        init(monitor: NWPathMonitor, continuation: CheckedContinuation<Bool, Never>) {
            self.monitor = monitor
            self.continuation = continuation
        }

        func finish(with value: Bool) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()

            monitor.cancel()
            continuation.resume(returning: value)
        }
    }

    /// 等待网络可用，最多 timeout 秒。返回 true 表示已可用，false 表示超时。
    static func waitUntilAvailable(timeout: TimeInterval) async -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.stickerdiary.reachability")

        if monitor.currentPath.status == .satisfied {
            monitor.cancel()
            return true
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let state = WaitState(monitor: monitor, continuation: continuation)

            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied { state.finish(with: true) }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { state.finish(with: false) }
        }
    }
}

// MARK: - Daily AI Usage Quota

@MainActor
enum DailyQuotaManager {
    static let maxFreeGenerations = 2
    private static let usageDateKey = "ai_usage_date"
    private static let usageCountKey = "ai_usage_count"

    /// Pro users bypass all quota limits.
    static var isProUser: Bool {
        SubscriptionManager.shared.isProUser
    }

    /// Today's remaining free generations. Pro users get Int.max.
    static var remainingToday: Int {
        if isProUser { return .max }
        resetIfNewDay()
        let used = UserDefaults.standard.integer(forKey: usageCountKey)
        return max(0, maxFreeGenerations - used)
    }

    /// Whether the user can still generate today.
    static var canGenerate: Bool {
        if isProUser { return true }
        return remainingToday > 0
    }

    /// Record one generation usage. Returns `true` if allowed, `false` if over quota.
    @discardableResult
    static func consume() -> Bool {
        if isProUser { return true } // Pro users don't consume quota
        resetIfNewDay()
        let used = UserDefaults.standard.integer(forKey: usageCountKey)
        guard used < maxFreeGenerations else { return false }
        UserDefaults.standard.set(used + 1, forKey: usageCountKey)
        return true
    }

    private static func resetIfNewDay() {
        let today = Calendar.current.startOfDay(for: Date())
        let stored = UserDefaults.standard.object(forKey: usageDateKey) as? Date ?? .distantPast
        if !Calendar.current.isDate(stored, inSameDayAs: today) {
            UserDefaults.standard.set(today, forKey: usageDateKey)
            UserDefaults.standard.set(0, forKey: usageCountKey)
        }
    }
}

struct BailianDiaryGenerator {
    /// Model Studio keys only work in the region that issued them, so each
    /// region carries its own endpoint and key.
    private struct Service {
        let endpoint: URL
        let headers: [String: String]
    }

    /// qwen-vl-plus writes good Chinese but often ignores the English style
    /// rules (it falls back to "Later... As evening approached..."), so English
    /// diaries use the stronger, pricier qwen-vl-max.
    private var model: String {
        AppLocale.isChinese ? "qwen-vl-plus" : "qwen-vl-max"
    }

    /// Cloudflare Worker (see proxy/) that holds the international Model
    /// Studio key server-side. Until it is deployed and set here, every user
    /// goes through the mainland endpoint, which also works from overseas.
    private let proxyEndpoint: URL? = nil
    /// Shared value the proxy checks in X-App-Token. Not a real secret (it ships
    /// in the app); it only keeps casual traffic off the proxy.
    private let proxyAppToken = "y3xXHorvwMNhl2VS_xL5OOUaIXFFlf84"

    static let chineseDefaultSystemPrompt = "你是一位温柔、具体、有生活观察力的中文日记作者。你会根据用户当天拍的照片，识别物品和场景，并写成自然、不夸张、可直接放进日记本的文字。绝对不要在日记正文中出现「贴纸」这个词。"

    static let englishDefaultSystemPrompt = "You are a warm, observant diary writer with an eye for everyday detail. Based on the photos the user took today, you recognize the objects and scenes and write natural, unpretentious diary text that could go straight into a personal journal. Never use the word \"sticker\" in the diary text."

    static var defaultSystemPrompt: String {
        AppLocale.isChinese ? chineseDefaultSystemPrompt : englishDefaultSystemPrompt
    }

    private static let customPromptKey = "custom_diary_system_prompt"

    /// The chosen style template's prompt in the current language, so switching
    /// the app's language doesn't leave a Chinese prompt driving an English
    /// diary. Prompts can only be picked from templates; a hand-edited prompt
    /// saved by an older version falls back to the default.
    static var currentSystemPrompt: String {
        get {
            guard let stored = UserDefaults.standard.string(forKey: customPromptKey),
                  let template = diaryPromptTemplates.first(where: { $0.chinesePrompt == stored || $0.englishPrompt == stored }) else {
                return defaultSystemPrompt
            }
            return template.prompt
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == chineseDefaultSystemPrompt || trimmed == englishDefaultSystemPrompt {
                UserDefaults.standard.removeObject(forKey: customPromptKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: customPromptKey)
            }
        }
    }

    /// From Config/Secrets.xcconfig (git-ignored) via Info.plist, so the key
    /// never lands in the repo.
    private var apiKey: String {
        get throws {
            let key = (Bundle.main.object(forInfoDictionaryKey: "DashScopeAPIKey") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty, !key.hasPrefix("$(") else { throw BailianDiaryError.missingAPIKey }
            return key
        }
    }

    func generateDiary(for date: Date, sources: [DiaryStickerSource]) async throws -> GeneratedDiary {
        let body = try JSONSerialization.data(withJSONObject: requestBody(for: date, sources: sources))
        let (data, response) = try await performRequest(body: body, retries: 2)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "BailianDiary", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let decoded = try JSONDecoder().decode(BailianChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw BailianDiaryError.emptyContent
        }
        return try parseGeneratedDiary(from: content)
    }

    /// Mainland users stay on the mainland endpoint (Cloudflare is unreliable
    /// in mainland China); everyone else goes through the proxy once deployed.
    private var service: Service {
        get throws {
            if let proxyEndpoint, Locale.current.region?.identifier != "CN" {
                return Service(endpoint: proxyEndpoint, headers: ["X-App-Token": proxyAppToken])
            }
            return Service(
                endpoint: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
                headers: ["Authorization": "Bearer \(try apiKey)"]
            )
        }
    }

    private func performRequest(body: Data, retries: Int) async throws -> (Data, URLResponse) {
        let service = try service
        var request = URLRequest(url: service.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        for (field, value) in service.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            // iOS 首次请求会触发系统网络授权弹窗，并把这个请求本身"牺牲"掉
            // （立即返回 notConnectedToInternet）。这里等网络真正可用后自动重试，
            // 用户点「允许」后即可无缝继续，无需手动点「去设置」。
            if retries > 0, isConnectivityError(error) {
                let available = await NetworkReachability.waitUntilAvailable(timeout: 15)
                // 即便已可用也稍等片刻，给系统授权落地留出缓冲。
                try await Task.sleep(nanoseconds: available ? 400_000_000 : 1_500_000_000)
                return try await performRequest(body: body, retries: retries - 1)
            }
            throw error
        }
    }

    private func isConnectivityError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .timedOut:
            return true
        default:
            return false
        }
    }

    private func requestBody(for date: Date, sources: [DiaryStickerSource]) throws -> [String: Any] {
        var userContent: [[String: Any]] = [
            ["type": "text", "text": prompt(for: date, sources: sources)]
        ]

        for source in sources.prefix(8) {
            guard let dataURL = source.image.diaryJPEGDataURL(maxDimension: 720) else {
                throw BailianDiaryError.invalidImage
            }
            userContent.append([
                "type": "image_url",
                "image_url": ["url": dataURL]
            ])
        }

        return [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": Self.currentSystemPrompt
                ],
                [
                    "role": "user",
                    "content": userContent
                ]
            ],
            "temperature": 0.78,
            "max_tokens": max(1200, sources.count * 400)
        ]
    }

    /// The diary is written in the app's UI language.
    private func prompt(for date: Date, sources: [DiaryStickerSource]) -> String {
        let dateText = AppLocale.string(from: date, chinese: "yyyy\u{5E74}M\u{6708}d\u{65E5} EEEE", template: "yyyyMMMMdEEEE")
        let visibleSources = Array(sources.prefix(8))
        let stickerList = visibleSources.enumerated().map { index, source in
            "\(index). \(source.title) / \(source.subtitle)"
        }.joined(separator: "\n")
        if AppLocale.isChinese {
            return chinesePrompt(dateText: dateText, stickerCount: visibleSources.count, stickerList: stickerList)
        }
        return englishPrompt(dateText: dateText, stickerCount: visibleSources.count, stickerList: stickerList)
    }

    private func englishPrompt(dateText: String, stickerCount: Int, stickerList: String) -> String {
        let example = """
        {
          "title": "",
          "summary": "A one-sentence summary of the day",
          "entries": [
            { "title": "", "text": "A natural diary paragraph of 40 to 80 words", "stickerIndex": 0, "inlineAnchor": "one noun copied from the text" }
          ]
        }
        """
        let photoWord = stickerCount == 1 ? "photo" : "photos"
        let entryWord = stickerCount == 1 ? "entry" : "entries"
        return """
        Write a diary entry in English for this day, based on the photos below.

        Date: \(dateText)
        Photos:
        \(stickerList)

        Requirements:
        1. First work out what each photo shows: an object, drink, ticket, food, or everyday scene.
        2. Don't invent specific places, names, or prices that can't be seen in the photos.
        3. Write like a private diary, in the first person and in natural, casual American English: warm, specific, never salesy.
        4. Keep it coherent, with smooth transitions between paragraphs, so it reads as one complete diary entry rather than a list.
        5. Don't organize the paragraphs by time of day. That turns into a log. Avoid openers like "Today started with", "Later", "Then", "As the day wound down", or "As evening approached". Connect the paragraphs through feelings, scenes, and mood, like a memory rather than a schedule, and give each paragraph a different kind of opening.
        6. [MOST IMPORTANT] Return exactly \(stickerCount) \(entryWord). There \(stickerCount == 1 ? "is" : "are") \(stickerCount) \(photoWord) today, and every photo must get exactly one entry: no more, no fewer. Even if a photo is hard to write about, write a paragraph for it. Never skip one.
        7. The entries must follow the photo numbering above exactly: the 1st entry is for photo 0, the 2nd for photo 1, and so on. Each entry's stickerIndex must equal its position in the entries array, counting from 0.
        8. Each entry is mainly about its own photo, but its tone and mood should flow with the rest of the diary instead of standing alone.
        9. [VERY IMPORTANT] The photo-to-paragraph mapping is only used for layout, and the reader must never notice it. Never use the words "photo", "picture", "image", "pic", or "sticker", never point at a photo with "this kitten" or "this latte" (write "a kitten", "my latte" instead), and don't enumerate things like "the first thing today... the second thing...". Even if something looks like a drawing, print, toy, or cutout, write about it as the real thing. Treat what's in the photos as things that really happened, that you really ate or saw, and weave them into a reflective, remembered narrative. Write a real diary, not captions for pictures.
        10. The top-level title and every entry's title must be empty strings.
        11. Each entry's text should be 40 to 80 words.
        12. Every entry must include an inlineAnchor: preferably a single noun (at most 2 words) copied character for character from that entry's text, such as "kitten" or "pretzel". Don't add adjectives that aren't directly next to it in the text. Prefer the name of the object, food, drink, ticket, or scene.
        13. The inlineAnchor must not be a heading, and must not be a word that doesn't appear in the text.
        14. Don't indent paragraphs.
        15. Output JSON only. No Markdown, no explanations.

        JSON format:
        \(example)
        """
    }

    private func chinesePrompt(dateText: String, stickerCount: Int, stickerList: String) -> String {
        // Short enough to read at a glance; more photos means shorter paragraphs.
        let length = stickerCount <= 2 ? (min: 50, max: 90) : stickerCount <= 4 ? (min: 40, max: 70) : (min: 25, max: 50)
        let q = "\u{22}"
        let jsonExample = "{\n  \(q)title\(q): \(q)\(q),\n  \(q)summary\(q): \(q)\u{4E00}\u{53E5}\u{8BDD}\u{603B}\u{7ED3}\(q),\n  \(q)entries\(q): [\n    { \(q)title\(q): \(q)\(q), \(q)text\(q): \(q)\u{65E5}\u{8BB0}\u{81EA}\u{7136}\u{6BB5}\u{FF0C}\(length.min)\u{5230}\(length.max)\u{4E2A}\u{4E2D}\u{6587}\u{5B57}\(q), \(q)stickerIndex\(q): 0, \(q)inlineAnchor\(q): \(q)\u{7269}\u{54C1}\u{77ED}\u{8BCD}\(q) }\n  ]\n}"
        var lines: [String] = []
        lines.append("请根据下面这一天拍的照片，写一篇中文日记。")
        lines.append("")
        lines.append("日期：\(dateText)")
        lines.append("照片列表：")
        lines.append(stickerList)
        lines.append("")
        lines.append("要求：")
        lines.append("1. 先理解每张照片里是什么物品、饮品、票据、食物或生活场景。")
        lines.append("2. 不要编造过于具体但照片中看不出的地点、人名、价格。")
        lines.append("3. 文风像私人日记，温柔、具体、自然，不要营销腔。")
        lines.append("4. 文字温柔、具体、连贯，段落之间自然过渡，整体读起来像一篇完整的日记，不要写成生硬的清单。")
        lines.append("5. 不要按上午/中午/下午/傍晚/晚上的时间顺序来组织段落，这样会变成流水账。应该用感受、场景、心情来串联，像回忆而不是日程表。")
        lines.append("6. 【最重要】必须返回正好 \(stickerCount) 个 entry：今天一共有 \(stickerCount) 张照片，每一张照片都必须对应一个 entry，不能多也不能少。哪怕某张照片不好写，也要为它写一段，绝对不能漏掉任何一张。")
        lines.append("7. entries 的顺序必须和上面照片列表的编号顺序完全一致：第 1 个 entry 对应编号 0 的照片，第 2 个 entry 对应编号 1 的照片，依此类推。每个 entry 的 stickerIndex 必须等于它在 entries 数组中的位置（从 0 开始计数），即第 i 个 entry 的 stickerIndex = i。")
        lines.append("8. 每个 entry 主要围绕它对应的那张照片来写，但语气和情绪要和整篇日记连贯，不要彼此孤立。")
        lines.append("9. 【非常重要】照片和段落的对应关系只是内部排版用的，读者完全感觉不到。绝对不要在正文里出现「第1张/第一张/这张/那张照片」「图片里/照片里/图中」「贴纸」之类描述图片本身的说法，也不要用「今天的第一件事/第二件事」这种逐条罗列的口吻。要把照片的内容当成当天真实发生、真实吃到、真实看到的事，自然地写进回忆式的叙述里，像真的在写日记，而不是在给图片配文字说明。")
        lines.append("10. 顶层 title 和每个 entry 的 title 都固定返回空字符串，不需要任何标题。")
        lines.append("11. 每段必须给出 inlineAnchor；inlineAnchor 必须是该段 text 中真实出现的短词或短语，优先选择物品名、食物名、饮品名、票据名或场景关键词。")
        lines.append("12. 不要把 inlineAnchor 写成段落标题，不要编造日记里没有出现的词。")
        lines.append("13. 每段 text 的开头加两个全角空格（\u{3000}\u{3000}），模拟中文段首缩进。")
        lines.append("14. 【重要】写短一点。每段 text 控制在 \(length.min) 到 \(length.max) 个中文字，一两句话点到为止，不要铺陈、不要堆砌形容词，宁短勿长。")
        lines.append("15. 只输出 JSON，不要 Markdown，不要解释。")
        lines.append("")
        lines.append("JSON 格式：")
        lines.append(jsonExample)
        return lines.joined(separator: "\n")
    }

    private func parseGeneratedDiary(from content: String) throws -> GeneratedDiary {
        let jsonString = extractJSONObject(from: content)
        guard let data = jsonString.data(using: .utf8) else {
            throw BailianDiaryError.invalidResponse
        }
        let decoder = JSONDecoder()
        if let diary = try? decoder.decode(GeneratedDiary.self, from: data) {
            return diary
        }
        if let repaired = tryRepairJSON(jsonString),
           let repairedData = repaired.data(using: .utf8),
           let diary = try? decoder.decode(GeneratedDiary.self, from: repairedData) {
            return diary
        }
        throw BailianDiaryError.invalidResponse
    }

    private func extractJSONObject(from text: String) -> String {
        var cleaned = text
        if let codeBlockRange = cleaned.range(of: "```json") ?? cleaned.range(of: "```") {
            cleaned = String(cleaned[codeBlockRange.upperBound...])
            if let endBlock = cleaned.range(of: "```") {
                cleaned = String(cleaned[..<endBlock.lowerBound])
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start <= end else {
            return text
        }
        return String(cleaned[start...end])
    }

    private func tryRepairJSON(_ text: String) -> String? {
        var s = text
        s = s.replacingOccurrences(of: ",\\s*\\}", with: "}", options: .regularExpression)
        s = s.replacingOccurrences(of: ",\\s*\\]", with: "]", options: .regularExpression)
        return s == text ? nil : s
    }
}

struct BailianChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}

struct StickerCalendarRecord: Identifiable {
    let id = UUID()
    var date: Date
    var stickers: [UIImage?]
    var diaryText: String
    var diaryTitle: String? = nil
    var stickerCountOverride: Int?
    var stickerSlots: [Bool] = []
    var hadStickerSlots: [Bool] = []
    var blocks: [PersistedDiaryBlock]? = nil

    var stickerCount: Int {
        stickerCountOverride ?? stickers.compactMap({ $0 }).count
    }

    /// Non-nil stickers only
    var availableStickers: [UIImage] {
        stickers.compactMap { $0 }
    }

    func withCalendarPreviewSticker() -> StickerCalendarRecord {
        guard availableStickers.isEmpty else { return self }
        var copy = self
        copy.stickers = StickerStore.shared.firstOrderedSticker(for: date).map { [Optional($0.image)] } ?? []
        return copy
    }
}

func isRealDiaryText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed != "每日贴纸" && trimmed != "今日日记"
}

struct DiaryStickerPilePreview: View {
    let images: [UIImage]

    private struct LayoutSpec {
        let x: CGFloat
        let y: CGFloat
        let rotation: Double
        let scale: CGFloat
    }

    private let specs: [LayoutSpec] = [
        LayoutSpec(x: -0.20, y: 0.10, rotation: -15, scale: 1.02),
        LayoutSpec(x: 0.06, y: 0.00, rotation: 10, scale: 1.10),
        LayoutSpec(x: 0.24, y: 0.13, rotation: -7, scale: 0.94),
        LayoutSpec(x: -0.02, y: 0.25, rotation: 17, scale: 0.88),
        LayoutSpec(x: -0.34, y: 0.26, rotation: 7, scale: 0.82),
        LayoutSpec(x: 0.36, y: 0.30, rotation: -18, scale: 0.78)
    ]

    var body: some View {
        GeometryReader { geo in
            let visible = Array(images.prefix(specs.count))
            let baseSize = min(geo.size.width * 0.34, 112)

            ZStack {
                ForEach(Array(visible.enumerated()), id: \.offset) { index, image in
                    let spec = specs[index]

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: baseSize * spec.scale, height: baseSize * spec.scale)
                        .shadow(color: .black.opacity(0.16), radius: 10, y: 6)
                        .rotationEffect(.degrees(spec.rotation))
                        .offset(x: geo.size.width * spec.x, y: geo.size.height * spec.y)
                        .zIndex(Double(specs.count - index))
                }

                if images.count > specs.count {
                    Text("+\(images.count - specs.count)")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))
                        .frame(width: 38, height: 30)
                        .background(.white.opacity(0.74), in: Capsule())
                        .offset(x: geo.size.width * 0.36, y: geo.size.height * 0.34)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel("当天贴纸")
    }
}

enum SampleContentSeeder {
    private static let seededKey = "stickerDiarySampleContentSeeded.v3"
    private static let sampleDateKey = "stickerDiarySampleDate"
    private static let firstLaunchDateKey = "stickerDiaryFirstLaunchDate"
    private static let removedSampleDiaryKey = "stickerDiarySampleDiaryRemoved.v2"
    private static let removedSampleStickersKey = "stickerDiarySampleStickersRemoved.v1"
    private static let legacySampleDiaryTitle = "欢迎来到贴纸日记"
    private static let legacySampleDiarySnippets = [
        "把每天遇到的小东西，收进一页日记里",
        "AI 会帮你识别并抠图",
        "小猫、小狗、卡皮巴拉",
        "普通但可爱的瞬间"
    ]
    private static let legacySampleStickers = [
        SampleSticker(title: "小猫", subtitle: "今天收进来的第一张贴纸", assetName: "SampleCat"),
        SampleSticker(title: "小狗", subtitle: "给日记加一点软乎乎的心情", assetName: "SampleDog"),
        SampleSticker(title: "卡皮巴拉", subtitle: "慢慢悠悠也值得记录", assetName: "SampleCapybara")
    ]

    /// The date of the sample diary (nil if none, or if the user has since generated a real diary on that day).
    static var sampleDiaryDate: Date? {
        let ts = UserDefaults.standard.double(forKey: sampleDateKey)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    /// Call when the user generates a real diary — if it lands on the sample date, clear the marker.
    static func clearSampleMarkerIfNeeded(for date: Date) {
        guard let sample = sampleDiaryDate else { return }
        if Calendar.current.isDate(date, inSameDayAs: sample) {
            UserDefaults.standard.removeObject(forKey: sampleDateKey)
        }
    }

    /// True for the seeded example day, so it doesn't count toward achievements.
    static func isSampleDiary(on date: Date) -> Bool {
        guard let sample = sampleDiaryDate else { return false }
        return Calendar.current.isDate(date, inSameDayAs: sample)
    }

    static func seedIfNeeded() {
        let defaults = UserDefaults.standard
        removeLegacySampleDiaryIfNeeded()
        removeLegacySampleStickersIfNeeded()
        guard !defaults.bool(forKey: seededKey) else { return }
        defaults.set(true, forKey: seededKey)

        // Fresh installs only: anyone who already has stickers or diaries keeps their app as is.
        guard StickerStore.shared.loadEntries().isEmpty,
              DiaryRecordStore.shared.loadCalendarRecords().isEmpty else { return }
        seedExampleDay()
    }

    /// Yesterday's page, so today stays empty for the user's own first sticker.
    private static func seedExampleDay() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let day = calendar.date(byAdding: .day, value: -1, to: today) else { return }

        let content = AppLocale.isChinese ? chineseExample : englishExample
        var blocks: [PersistedDiaryBlock] = []
        for sticker in content.stickers {
            guard let image = UIImage(named: sticker.assetName) else { return }
            let time = calendar.date(bySettingHour: sticker.hour, minute: sticker.minute, second: 0, of: day) ?? day
            let id = StickerStore.shared.saveSticker(
                image: image,
                title: sticker.title,
                subtitle: sticker.subtitle,
                date: time
            )
            blocks.append(PersistedDiaryBlock(
                text: AppLocale.paragraphIndent + sticker.paragraph,
                stickerID: id,
                hadStickerSlot: true,
                stickerOffsetX: 0,
                stickerOffsetY: 0,
                stickerScale: 1,
                inlineStickers: nil
            ))
        }

        DiaryRecordStore.shared.saveDiaryText(
            blocks.map(\.text).joined(separator: "\n\n"),
            for: day,
            title: content.title,
            stickerSlots: blocks.map { _ in true },
            hadStickerSlots: blocks.map { _ in true },
            blocks: blocks
        )
        var finished = DiaryFinishedDays.load()
        finished.insert(DiaryFinishedDays.dayID(for: day))
        DiaryFinishedDays.save(finished)
        UserDefaults.standard.set(day.timeIntervalSince1970, forKey: sampleDateKey)
    }

    /// Picked by UI language at seed time and stored as data, so no catalog entries.
    private static let chineseExample = ExampleDay(
        title: "毛茸茸的一天",
        stickers: [
            ExampleSticker(
                assetName: "SampleCat", title: "小橘猫", subtitle: "趴在树上看云",
                hour: 16, minute: 20,
                paragraph: "下午路过小区里那棵老树，一抬头就对上了一双圆溜溜的眼睛。一只小橘猫趴在树杈上，两只粉粉的肉垫搭在树皮上，一脸认真地研究着天上的云。"
            ),
            ExampleSticker(
                assetName: "SampleDog", title: "泰迪", subtitle: "在门口等我回家",
                hour: 18, minute: 40,
                paragraph: "回到家，泰迪早就蹲在门口等我了。它歪着脑袋看我，毛乱蓬蓬的，像一团刚出炉的棉花糖。今天被两只小毛球治愈了。"
            )
        ]
    )

    private static let englishExample = ExampleDay(
        title: "A Fluffy Kind of Day",
        stickers: [
            ExampleSticker(
                assetName: "SampleCat", title: "Kitten", subtitle: "Cloud-watching up a tree",
                hour: 16, minute: 20,
                paragraph: "Spotted a tiny orange kitten up in the old tree on my walk home. Paws on the bark, staring at the sky like it had big plans."
            ),
            ExampleSticker(
                assetName: "SampleDog", title: "Teddy", subtitle: "Waiting at the door",
                hour: 18, minute: 40,
                paragraph: "Teddy was waiting by the door when I got back, head tilted, fur everywhere. Two little fluffballs made my whole day."
            )
        ]
    )

    private struct ExampleDay {
        let title: String
        let stickers: [ExampleSticker]
    }

    private struct ExampleSticker {
        let assetName: String
        let title: String
        let subtitle: String
        let hour: Int
        let minute: Int
        let paragraph: String
    }

    private static func removeLegacySampleDiaryIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: removedSampleDiaryKey) else { return }
        defer { defaults.set(true, forKey: removedSampleDiaryKey) }

        let records = DiaryRecordStore.shared.loadCalendarRecords()
        for record in records where isLegacySampleDiary(record) {
            DiaryRecordStore.shared.deleteDiary(for: record.date)
            if Calendar.current.isDate(record.date, inSameDayAs: sampleDiaryDate ?? .distantPast) {
                defaults.removeObject(forKey: sampleDateKey)
            }
        }
    }

    private static func isLegacySampleDiary(_ record: StickerCalendarRecord) -> Bool {
        if record.diaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines) == legacySampleDiaryTitle {
            return true
        }

        let text = record.diaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        return legacySampleDiarySnippets.contains { text.contains($0) }
    }

    private static func removeLegacySampleStickersIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: removedSampleStickersKey) else { return }
        defer { defaults.set(true, forKey: removedSampleStickersKey) }

        let legacyPairs = Set(legacySampleStickers.map { "\($0.title)\u{1F}\($0.subtitle)" })
        for entry in StickerStore.shared.loadEntries() {
            let key = "\(entry.title)\u{1F}\(entry.subtitle)"
            if legacyPairs.contains(key) {
                StickerStore.shared.deleteSticker(id: entry.id)
            }
        }
    }

    private static func sampleDate() -> Date {
        let defaults = UserDefaults.standard
        if let existingDate = storedFirstLaunchDate(in: defaults) {
            return existingDate
        }

        let firstLaunchDate = sampleDate(on: Date())
        defaults.set(firstLaunchDate.timeIntervalSince1970, forKey: firstLaunchDateKey)
        return firstLaunchDate
    }

    private static func storedFirstLaunchDate(in defaults: UserDefaults) -> Date? {
        let timestamp = defaults.double(forKey: firstLaunchDateKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func sampleDate(on date: Date) -> Date {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(bySettingHour: 9, minute: 20, second: 0, of: startOfDay) ?? startOfDay
    }

    private struct SampleSticker {
        let title: String
        let subtitle: String
        let assetName: String
    }
}

struct StickerCalendarPage: View {
    let records: [StickerCalendarRecord]
    let currentStickers: [UIImage]
    let refreshToken: Int
    let onClose: () -> Void
    var onOpenDiary: ((Date) -> Void)?
    @State private var recapData: MonthlyRecapData?
    @State private var selectedDate: Date?
    @State private var cachedDisplayRecords: [StickerCalendarRecord] = []
    @State private var cachedDisplayStickers: [UIImage] = []
    @State private var cachedRecordsByDay: [Date: StickerCalendarRecord] = [:]
    @State private var cachedStickerCount = 0
    @State private var displayedMonth: Date = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 7)
    private let weekdaySymbols = AppLocale.veryShortWeekdaySymbols

    private var today: Date { .now }

    private var monthRecords: [StickerCalendarRecord] {
        records.filter { calendar.isDate($0.date, equalTo: displayedMonth, toGranularity: .month) }
    }

    private var isDisplayedMonthCurrent: Bool {
        calendar.isDate(displayedMonth, equalTo: today, toGranularity: .month)
    }

    private var stickerCount: Int {
        cachedStickerCount
    }

    var body: some View {
        ZStack {
            PaperTextureBackground()

            VStack(spacing: 18) {
                compactHeader
                    .padding(.top, 54)
                calendarCard
                monthSummaryCard
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 32)
        }
        .onAppear(perform: rebuildCalendarCache)
        .onChange(of: displayedMonth) { _, _ in
            rebuildCalendarCache()
        }
        .sheet(isPresented: Binding(
            get: { recapData != nil },
            set: { if !$0 { recapData = nil } }
        )) {
            if let recapData {
                MonthlyRecapSheet(data: recapData)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: refreshToken) { _, _ in
            rebuildCalendarCache()
        }
        .gesture(monthSwipeGesture)
    }

    private var compactHeader: some View {
        StickerPageHeader(
            title: String(localized: "日历"),
            subtitle: monthTitle,
            closeSystemImage: "chevron.left",
            onClose: onClose
        ) {
            HStack(spacing: 8) {
                HeaderIconButton(systemImage: "chevron.left", accessibilityLabel: String(localized: "上个月")) {
                    shiftDisplayedMonth(by: -1)
                }
                HeaderIconButton(systemImage: "chevron.right", accessibilityLabel: String(localized: "下个月")) {
                    shiftDisplayedMonth(by: 1)
                }
                if !isDisplayedMonthCurrent {
                    HeaderIconButton(systemImage: "calendar", accessibilityLabel: String(localized: "回到本月")) {
                        returnToCurrentMonth()
                    }
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isDisplayedMonthCurrent)
        }
    }

    private var calendarCard: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(weekdaySymbols.indices, id: \.self) { index in
                    Text(weekdaySymbols[index])
                        .font(DiaryFont.display(size: 15, design: .monospaced))
                        .foregroundStyle(Color(red: 0.50, green: 0.47, blue: 0.44))
                        .frame(height: 26)
                }

                let cells = monthCells()
                ForEach(cells.indices, id: \.self) { index in
                    let date = cells[index]
                    CalendarDayCell(
                        date: date,
                        isToday: date.map { calendar.isDate($0, inSameDayAs: today) } ?? false,
                        record: record(for: date),
                        onSelect: {
                            if let date {
                                openDayNotebook(for: date)
                            }
                        }
                    )
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 18, y: 9)
    }

    private var monthSummaryCard: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("本月")
                    .font(DiaryFont.display(size: 18, weight: .bold))
                    .foregroundStyle(Color(red: 0.42, green: 0.38, blue: 0.35))

                Spacer()

                Text("\(cachedDisplayRecords.count) 天")
                    .font(DiaryFont.display(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.54, green: 0.48, blue: 0.44))
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(stickerCount)")
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .foregroundStyle(Color(red: 0.19, green: 0.13, blue: 0.11))
                Text("张贴纸")
                    .font(DiaryFont.display(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.42, green: 0.38, blue: 0.35))

                Spacer()
            }

            if !cachedDisplayStickers.isEmpty {
                CalendarStickerScatter(images: cachedDisplayStickers)
                    .frame(height: 88)
                    .padding(.top, 2)

                monthlyRecapButton
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var monthTitle: String {
        AppLocale.string(from: displayedMonth, chinese: "yyyy年M月", template: "yyyyMMMM")
    }

    private var monthlyRecapButton: some View {
        Button {
            recapData = MonthlyRecapData.load(month: displayedMonth, records: records)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.square")
                Text("月度回顾")
            }
            .font(.system(size: 15, weight: .black, design: .rounded))
            .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(Color(red: 0.34, green: 0.24, blue: 0.18).opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func openDayNotebook(for date: Date) {
        onOpenDiary?(date)
    }

    private func record(for date: Date?) -> StickerCalendarRecord? {
        guard let date else { return nil }
        return cachedRecordsByDay[calendar.startOfDay(for: date)]
    }

    private func rebuildCalendarCache() {
        let storedRecords = makeStoredMonthRecords()
        var recordsByDay = Dictionary(uniqueKeysWithValues: storedRecords.map { (calendar.startOfDay(for: $0.date), $0) })

        for record in monthRecords {
            recordsByDay[calendar.startOfDay(for: record.date)] = record.withCalendarPreviewSticker()
        }

        if isDisplayedMonthCurrent, recordsByDay.isEmpty, !currentStickers.isEmpty {
            recordsByDay[calendar.startOfDay(for: today)] = StickerCalendarRecord(date: today, stickers: currentStickers, diaryText: "今日日记")
        }

        cachedRecordsByDay = recordsByDay
        cachedDisplayRecords = recordsByDay.values.sorted { $0.date < $1.date }

        // Show the most recently added stickers (newest first)
        let allMonthEntries = StickerStore.shared.loadEntries().filter {
            calendar.isDate($0.date, equalTo: displayedMonth, toGranularity: .month)
        }.sorted { $0.timestamp > $1.timestamp }
        let recentStickers = allMonthEntries.prefix(10).compactMap { StickerStore.shared.loadStickerImage(id: $0.id) }
        cachedDisplayStickers = recentStickers.isEmpty && isDisplayedMonthCurrent ? currentStickers : recentStickers
        cachedStickerCount = max(cachedDisplayRecords.reduce(0) { $0 + $1.stickerCount }, allMonthEntries.count, cachedDisplayRecords.count)
    }

    private func makeStoredMonthRecords() -> [StickerCalendarRecord] {
        let entries = StickerStore.shared.loadEntries().filter {
            calendar.isDate($0.date, equalTo: displayedMonth, toGranularity: .month)
        }
        let grouped = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.date)
        }

        return grouped.compactMap { day, entries in
            let sortedEntries = entries.sorted { $0.timestamp > $1.timestamp }
            guard let firstSticker = sortedEntries.lazy.compactMap({ StickerStore.shared.loadStickerImage(id: $0.id) }).first else { return nil }
            return StickerCalendarRecord(
                date: day,
                stickers: [firstSticker],
                diaryText: "每日贴纸",
                stickerCountOverride: entries.count
            )
        }
    }

    private func monthCells() -> [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let monthRange = calendar.range(of: .day, in: .month, for: displayedMonth) else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        var cells = Array<Date?>(repeating: nil, count: firstWeekday - 1)
        for day in monthRange {
            var components = calendar.dateComponents([.year, .month], from: displayedMonth)
            components.day = day
            cells.append(calendar.date(from: components))
        }
        while cells.count % 7 != 0 {
            cells.append(nil)
        }
        return cells
    }

    private var monthSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 28, coordinateSpace: .local)
            .onEnded { value in
                let width = value.translation.width
                let height = value.translation.height
                guard abs(width) > abs(height), abs(width) > 42 else { return }
                shiftDisplayedMonth(by: width < 0 ? 1 : -1)
            }
    }

    private func shiftDisplayedMonth(by offset: Int) {
        guard let nextMonth = calendar.date(byAdding: .month, value: offset, to: displayedMonth),
              let monthStart = calendar.dateInterval(of: .month, for: nextMonth)?.start else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            displayedMonth = monthStart
        }
    }

    private func returnToCurrentMonth() {
        guard let monthStart = calendar.dateInterval(of: .month, for: today)?.start else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            displayedMonth = monthStart
        }
    }
}

struct CalendarStickerScatter: View {
    let images: [UIImage]

    private struct Spec {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let rotation: Double
    }

    private let specs: [Spec] = [
        Spec(x: 0.00, y: 0.18, size: 58, rotation: -9),
        Spec(x: 0.10, y: 0.04, size: 66, rotation: 7),
        Spec(x: 0.21, y: 0.20, size: 64, rotation: -4),
        Spec(x: 0.32, y: 0.02, size: 68, rotation: 5),
        Spec(x: 0.43, y: 0.22, size: 62, rotation: -8),
        Spec(x: 0.54, y: 0.06, size: 66, rotation: 8),
        Spec(x: 0.64, y: 0.24, size: 58, rotation: -5),
        Spec(x: 0.73, y: 0.08, size: 64, rotation: 6),
        Spec(x: 0.82, y: 0.24, size: 56, rotation: -10),
        Spec(x: 0.90, y: 0.10, size: 60, rotation: 9)
    ]

    var body: some View {
        GeometryReader { geo in
            let visible = Array(images.prefix(specs.count))
            let extraCount = max(images.count - specs.count, 0)

            ZStack(alignment: .leading) {
                ForEach(Array(visible.enumerated()), id: \.offset) { index, image in
                    let spec = specs[index]
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: spec.size, height: spec.size)
                        .rotationEffect(.degrees(spec.rotation))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                        .position(
                            x: 24 + geo.size.width * spec.x,
                            y: geo.size.height * spec.y + spec.size / 2
                        )
                        .zIndex(Double(index))
                }

                if extraCount > 0 {
                    Text("+\(extraCount)")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))
                        .frame(width: 42, height: 30)
                        .background(.white.opacity(0.76), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color(red: 0.34, green: 0.24, blue: 0.18).opacity(0.10), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
                        .position(x: geo.size.width - 22, y: 20)
                        .zIndex(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .accessibilityLabel("本月贴纸预览")
    }
}

struct CalendarDayCell: View {
    let date: Date?
    let isToday: Bool
    let record: StickerCalendarRecord?
    let onSelect: () -> Void

    private var dayNumber: String {
        guard let date else { return "" }
        return String(Calendar.current.component(.day, from: date))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isToday ? Color(red: 0.78, green: 0.46, blue: 0.18) : Color(red: 0.88, green: 0.87, blue: 0.83))
                .opacity(date == nil ? 0 : 1)

            if let sticker = record?.availableStickers.first {
                Image(uiImage: sticker)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 3)
            } else if date != nil {
                Text(dayNumber)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.26, green: 0.23, blue: 0.21))
            }

            if let count = record?.stickerCount, count > 1 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color(red: 0.77, green: 0.55, blue: 0.30), in: Circle())
                    .offset(x: 22, y: -24)
            }
        }
        .aspectRatio(0.86, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture {
            guard date != nil else { return }
            onSelect()
        }
    }
}


struct AchievementUnlockOverlay: View {
    let unlock: AchievementUnlock
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .onTapGesture(perform: onDone)

            AchievementPopup(
                title: unlock.tier.title,
                subtitle: unlock.tier.condition.replacingOccurrences(of: "。", with: ""),
                imageName: unlock.tier.imageName,
                sticker: unlock.representativeSticker,
                onDone: onDone
            )
            .padding(.horizontal, 22)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
            .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .onTapGesture {}
        }
    }
}

struct AchievementPopup: View {
    let title: String
    let subtitle: String
    let imageName: String?
    let sticker: UIImage?
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(red: 0.91, green: 0.87, blue: 0.80))
                        .frame(width: 118, height: 118)
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(Color.white.opacity(0.62), lineWidth: 1.5)
                        }

                    if let imageName {
                        Image(imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 96, height: 96)
                            .rotationEffect(.degrees(-6))
                            .shadow(color: .black.opacity(0.13), radius: 8, y: 5)
                    } else if let sticker {
                        Image(uiImage: sticker)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 96, height: 96)
                            .rotationEffect(.degrees(-6))
                            .shadow(color: .black.opacity(0.13), radius: 8, y: 5)
                    } else {
                        Image(systemName: "pencil.and.scribble")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(Color(red: 0.74, green: 0.48, blue: 0.24).opacity(0.6))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("收集成就")
                        .font(DiaryFont.display(size: 14))
                        .foregroundStyle(Color(red: 0.70, green: 0.42, blue: 0.18))

                    Text(title)
                        .font(DiaryFont.display(size: 27, weight: .black))
                        .foregroundStyle(Color(red: 0.20, green: 0.13, blue: 0.11))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Text(subtitle)
                        .font(DiaryFont.display(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.49, green: 0.44, blue: 0.40))
                        .lineLimit(2)
                }
            }

            Button(action: onDone) {
                Text("知道了")
                    .font(DiaryFont.display(size: 18))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color(red: 0.76, green: 0.47, blue: 0.22), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(Color(red: 0.96, green: 0.95, blue: 0.92), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(.white.opacity(0.68), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 24, y: 14)
    }
}

struct PaperTextureBackground: View {
    var body: some View {
        AchievementPaperBackground()
    }
}

struct AchievementPaperBackground: View {
    @State private var texture: Image? = PaperTextureCache.cached

    var body: some View {
        ZStack {
            Color(red: 0.955, green: 0.935, blue: 0.875)

            LinearGradient(
                colors: [
                    .white.opacity(0.40),
                    Color(red: 0.90, green: 0.84, blue: 0.73).opacity(0.26),
                    Color(red: 0.76, green: 0.68, blue: 0.55).opacity(0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // 程序化纸张纹理：离屏渲染一次后缓存复用，首帧不阻塞。
            if let texture {
                texture
                    .resizable()
                    .blendMode(.multiply)
                    .transition(.opacity)
            }

            RadialGradient(
                colors: [
                    .clear,
                    Color(red: 0.54, green: 0.46, blue: 0.36).opacity(0.16)
                ],
                center: .center,
                startRadius: 120,
                endRadius: 620
            )
            .blendMode(.multiply)
        }
        .ignoresSafeArea()
        .task {
            guard texture == nil else { return }
            // Let SwiftUI commit the inexpensive gradient first. ImageRenderer
            // is main-actor-only and otherwise may run before the first frame.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            if let rendered = await PaperTextureCache.render() {
                withAnimation(.easeOut(duration: 0.4)) {
                    texture = rendered
                }
            }
        }
    }
}

/// 把昂贵的程序化纸张纹理离屏渲染成一张图，整个 app 只渲染一次后复用，
/// 避免每个页面（含启动首帧）都在主线程重画近千个图元。
@MainActor
enum PaperTextureCache {
    static private(set) var cached: Image?

    static func render() async -> Image? {
        if let cached { return cached }
        // 纹理是无序噪点，固定分辨率渲染后拉伸铺满即可，与具体屏幕尺寸无关。
        let size = CGSize(width: 640, height: 1280)
        let renderer = ImageRenderer(content: PaperTextureCanvas(size: size).frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let uiImage = renderer.uiImage else { return nil }
        let image = Image(uiImage: uiImage)
        cached = image
        return image
    }
}

struct PaperTextureCanvas: View {
    let size: CGSize

    var body: some View {
        Canvas { context, size in
            for index in 0..<760 {
                let x = CGFloat((index * 53) % 1193) / 1193 * size.width
                let y = CGFloat((index * 97) % 1187) / 1187 * size.height
                let dotSize = CGFloat((index % 5) + 1) * 0.62
                let opacity = 0.028 + Double(index % 6) * 0.008
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: dotSize, height: dotSize)),
                    with: .color(Color(red: 0.34, green: 0.28, blue: 0.22).opacity(opacity))
                )
            }

            for index in 0..<170 {
                let x = CGFloat((index * 137) % 1103) / 1103 * size.width
                let y = CGFloat((index * 191) % 1097) / 1097 * size.height
                let length = CGFloat(28 + (index % 9) * 12)
                let angle = CGFloat(index % 13) * .pi / 52 - .pi / 8
                var path = Path()
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length))
                context.stroke(
                    path,
                    with: .color(Color(red: 0.42, green: 0.34, blue: 0.25).opacity(index % 4 == 0 ? 0.070 : 0.045)),
                    lineWidth: CGFloat(index % 3 == 0 ? 0.95 : 0.55)
                )
            }

            for index in 0..<18 {
                let x = CGFloat((index * 223) % 977) / 977 * size.width
                let y = CGFloat((index * 311) % 991) / 991 * size.height
                let radius = CGFloat(64 + (index % 5) * 34)
                context.stroke(
                    Path(ellipseIn: CGRect(x: x - radius / 2, y: y - radius / 2, width: radius, height: radius)),
                    with: .color(Color(red: 0.50, green: 0.42, blue: 0.32).opacity(index % 3 == 0 ? 0.040 : 0.026)),
                    lineWidth: 1.35
                )
            }

            for index in 0..<34 {
                let x = CGFloat((index * 313) % 1009) / 1009 * size.width
                let y = CGFloat((index * 419) % 1013) / 1013 * size.height
                let width = CGFloat(90 + (index % 6) * 42)
                let height = CGFloat(20 + (index % 5) * 13)
                let rect = CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(Color(red: 0.68, green: 0.58, blue: 0.44).opacity(0.018))
                )
            }
        }
    }
}

struct StickerDiaryOnboardingView: View {
    let onFinish: () -> Void

    @State private var selection = 0
    @State private var animate = false

    private let pages = StickerOnboardingPage.allCases
    private let ink = Color(red: 0.22, green: 0.15, blue: 0.12)
    private let mutedInk = Color(red: 0.52, green: 0.46, blue: 0.42)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PaperTextureBackground()

                VStack(spacing: 0) {
                    TabView(selection: $selection) {
                        ForEach(pages) { page in
                            StickerOnboardingPageView(page: page, animate: animate)
                                .tag(page.rawValue)
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    bottomBar
                        .padding(.horizontal, 24)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom + 16, 28))
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == selection ? ink : mutedInk.opacity(0.24))
                        .frame(width: index == selection ? 24 : 7, height: 7)
                        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: selection)
                }
            }

            Spacer()

            Button {
                if selection < pages.count - 1 {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        selection += 1
                    }
                } else {
                    onFinish()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(selection == pages.count - 1 ? "开始收集" : "继续")
                    Image(systemName: selection == pages.count - 1 ? "sparkles" : "arrow.right")
                }
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 48)
                .background(ink, in: Capsule())
                .shadow(color: .black.opacity(0.14), radius: 12, y: 7)
            }
            .buttonStyle(.plain)
        }
    }
}

enum StickerOnboardingPage: Int, CaseIterable, Identifiable {
    case collect
    case write

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .collect: return String(localized: "拍一张")
        case .write: return String(localized: "贴进日记")
        }
    }

    var subtitle: String {
        switch self {
        case .collect:
            return String(localized: "拍下今天的小物件，自动变成一张贴纸。")
        case .write:
            return String(localized: "用贴纸和文字，收藏难忘的瞬间。")
        }
    }
}

struct StickerOnboardingPageView: View {
    let page: StickerOnboardingPage
    let animate: Bool

    private let ink = Color(red: 0.22, green: 0.15, blue: 0.12)
    private let mutedInk = Color(red: 0.52, green: 0.46, blue: 0.42)

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            onboardingArt
                .frame(maxWidth: .infinity)
                .frame(height: 390)
                .padding(.horizontal, 22)

            VStack(spacing: 14) {
                Text(page.title)
                    .font(DiaryFont.display(size: 36, weight: .black))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)

                Text(page.subtitle)
                    .font(DiaryFont.display(size: 16, weight: .bold))
                    .foregroundStyle(mutedInk)
                    .lineSpacing(5)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 310)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 116)
        }
    }

    @ViewBuilder
    private var onboardingArt: some View {
        switch page {
        case .collect:
            CollectStickerOnboardingArt(animate: animate)
        case .write:
            WriteDiaryOnboardingArt(animate: animate)
        }
    }
}

struct CollectStickerOnboardingArt: View {
    let animate: Bool

    var body: some View {
        ZStack {
            OnboardingCutoutTransition(animate: animate)

            OnboardingFloatingSticker(imageName: "StickerCalendar", size: 84, rotation: animate ? -18 : -8)
                .offset(x: animate ? -144 : -130, y: animate ? -142 : -126)

            OnboardingFloatingSticker(imageName: "AchieveTier1Cutout", size: 72, rotation: animate ? 16 : 4)
                .offset(x: animate ? 138 : 116, y: animate ? 116 : 96)

            ForEach(0..<8, id: \.self) { index in
                Circle()
                    .fill(Color(red: 0.82, green: 0.52, blue: 0.20).opacity(0.18))
                    .frame(width: CGFloat(5 + index % 3), height: CGFloat(5 + index % 3))
                    .offset(
                        x: CGFloat([-118, -88, -58, 95, 118, 74, -102, 36][index]),
                        y: CGFloat([-116, 92, 126, -88, 64, 118, -30, -132][index]) + (animate ? -5 : 5)
                    )
            }
        }
    }
}

struct OnboardingCutoutTransition: View {
    let animate: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let cycle = 4.2
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
            let cutoutProgress = smoothstep((phase - 0.18) / 0.34)
            let resetProgress = smoothstep((phase - 0.86) / 0.14)
            let progress = cutoutProgress * (1 - resetProgress)

            ZStack {
                Image("OnboardingOriginalPhoto")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 250, height: 318)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .opacity(1 - progress)
                    .scaleEffect(1 - 0.08 * progress)
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 10)

                Image("OnboardingStickerPreview")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 286, height: 318)
                    .opacity(progress)
                    .scaleEffect(0.88 + 0.12 * progress)
                    .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
            }
        }
    }

    private func smoothstep(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

struct OnboardingCutoutStickerWindow: View {
    let imageName: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
    }
}

struct OnboardingStickerWindow: View {
    let imageName: String
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let animate: Bool

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFill()
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
    }
}

struct OnboardingFloatingSticker: View {
    let imageName: String
    let size: CGFloat
    let rotation: Double

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .shadow(color: .black.opacity(0.16), radius: 12, y: 7)
    }
}

struct WriteDiaryOnboardingArt: View {
    let animate: Bool

    private struct Paragraph {
        let text: String
        let stickerName: String?
        let stickerOnRight: Bool
    }

    /// Chinese app: the AI writes the whole page in one go.
    private static let aiParagraphs: [Paragraph] = [
        Paragraph(text: String(localized: "下午在回家的路上，看到一只橘色的小奶猫。它趴在路边，眼睛睁得大大的，好奇地看着来往的行人。"), stickerName: "SampleCat", stickerOnRight: true),
        Paragraph(text: String(localized: "到家后小狗已经在门口等了好久，一看到我就摇着尾巴扑过来，毛茸茸的脑袋蹭个不停。"), stickerName: "SampleDog", stickerOnRight: false),
    ]

    /// English app: you place a sticker, read its prompt, and jot a line by hand.
    /// English-only, so no catalog entries.
    private static let handwrittenParagraphs: [Paragraph] = [
        Paragraph(text: "Tiny orange kitten on the way home. Those big curious eyes!", stickerName: "SampleCat", stickerOnRight: true),
        Paragraph(text: "My pup was waiting at the door, tail going crazy. Best welcome ever.", stickerName: "SampleDog", stickerOnRight: false),
    ]
    private static let handwrittenPrompts = ["Why did this catch your eye?", "What made you smile today?"]

    /// By edition, not the AI toggle: the hand-written sample is English-only.
    private static var handwritten: Bool { !AppFeatures.aiDiaryAvailable }
    private static var paragraphs: [Paragraph] { handwritten ? handwrittenParagraphs : aiParagraphs }
    private static var fullLength: Int { paragraphs.map(\.text.count).reduce(0, +) }

    /// Pencil drawn inline after the last letter, like the caret pencil in the editor.
    private static let inlinePencil: UIImage? = {
        guard let image = UIImage(named: "PencilCaret") else { return nil }
        let side: CGFloat = 17
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }()

    @State private var visibleChars = 0
    @State private var typingTimer: Timer?
    @State private var placedStickers = 0
    @State private var promptParagraph: Int?
    @State private var isWriting = false
    @State private var handwritingTask: Task<Void, Never>?

    private let ink = Color(red: 0.30, green: 0.24, blue: 0.18)
    private let lineColor = Color(red: 0.82, green: 0.78, blue: 0.72).opacity(0.45)
    private let marginColor = Color(red: 0.85, green: 0.52, blue: 0.48).opacity(0.25)
    private let paper = Color(red: 0.98, green: 0.96, blue: 0.92)

    private let cardWidth: CGFloat = 306
    private let cardHeight: CGFloat = 370

    var body: some View {
        ZStack {
            // Paper card with ruled lines
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(paper)
                .frame(width: cardWidth, height: cardHeight)
                .overlay(ruledLines)
                .overlay(marginLine)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color(red: 0.86, green: 0.82, blue: 0.76), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 22, y: 12)

            // Content overlay
            VStack(alignment: .leading, spacing: 0) {
                // Date header
                Text("6月3日")
                    .font(DiaryFont.display(size: 18, weight: .black))
                    .foregroundStyle(ink)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                    .padding(.leading, 46)

                // Paragraphs
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(Self.paragraphs.enumerated()), id: \.offset) { index, para in
                        diaryParagraph(para, index: index)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.leading, 24)

                Spacer()
            }
            .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        }
        .onAppear {
            if Self.handwritten {
                handwritingTask = Task { await runHandwriting() }
            } else {
                startTyping()
            }
        }
        .onDisappear {
            typingTimer?.invalidate()
            handwritingTask?.cancel()
        }
    }

    private var ruledLines: some View {
        Canvas { context, size in
            let lineSpacing: CGFloat = 28
            var y: CGFloat = 52
            while y < size.height - 16 {
                context.stroke(
                    Path { path in
                        path.move(to: CGPoint(x: 16, y: y))
                        path.addLine(to: CGPoint(x: size.width - 16, y: y))
                    },
                    with: .color(lineColor),
                    lineWidth: 0.5
                )
                y += lineSpacing
            }
        }
    }

    private var marginLine: some View {
        Canvas { context, size in
            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: 42, y: 12))
                    path.addLine(to: CGPoint(x: 42, y: size.height - 12))
                },
                with: .color(marginColor),
                lineWidth: 1
            )
        }
    }

    private func diaryParagraph(_ para: Paragraph, index: Int) -> some View {
        let charsBefore = Self.paragraphs.prefix(index).map(\.text.count).reduce(0, +)
        let charsForThis = max(0, min(para.text.count, visibleChars - charsBefore))
        let visibleText = String(para.text.prefix(charsForThis))
        let showSticker = Self.handwritten ? index < placedStickers : charsForThis > 6

        return HStack(alignment: .top, spacing: 8) {
            if para.stickerOnRight {
                paragraphText(visibleText, index: index, isEmpty: charsForThis == 0)
                if showSticker, let name = para.stickerName {
                    stickerImage(name, wiggleOffset: index)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            } else {
                if showSticker, let name = para.stickerName {
                    stickerImage(name, wiggleOffset: index)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                paragraphText(visibleText, index: index, isEmpty: charsForThis == 0)
            }
        }
    }

    @ViewBuilder
    private func paragraphText(_ text: String, index: Int, isEmpty: Bool) -> some View {
        if !Self.handwritten {
            textView(text)
        } else if isEmpty {
            // The gray writing prompt an empty paragraph shows in the real editor.
            Text(verbatim: promptParagraph == index ? Self.handwrittenPrompts[index] : "")
                .font(DiaryFont.font(size: 15))
                .foregroundStyle(ink.opacity(0.35))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.25), value: promptParagraph)
        } else {
            handwrittenText(text, showsPencil: isWriting && isCurrentLine(index))
        }
    }

    private func isCurrentLine(_ index: Int) -> Bool {
        let charsBefore = Self.paragraphs.prefix(index).map(\.text.count).reduce(0, +)
        return visibleChars > charsBefore && visibleChars <= charsBefore + Self.paragraphs[index].text.count
    }

    private func handwrittenText(_ text: String, showsPencil: Bool) -> some View {
        var line = Text(verbatim: text)
        if showsPencil, let pencil = Self.inlinePencil {
            // Tip sits at the image's bottom-left, so it rests on the baseline.
            line = line + Text(Image(uiImage: pencil))
        }
        return line
            .font(DiaryFont.font(size: 15))
            .foregroundStyle(ink)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func textView(_ text: String) -> some View {
        Text(text)
            .font(DiaryFont.display(size: 12.5, weight: .medium, design: .default))
            .foregroundStyle(ink)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stickerImage(_ name: String, wiggleOffset: Int) -> some View {
        let baseAngle = wiggleOffset % 2 == 0 ? -5.0 : 5.0
        return Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: 80, height: 80)
            .rotationEffect(.degrees(animate ? baseAngle : -baseAngle))
            .shadow(color: .black.opacity(0.14), radius: 8, y: 5)
    }

    private func startTyping() {
        visibleChars = 0
        let total = Self.fullLength
        let charInterval = 3.6 / Double(total)

        typingTimer = Timer.scheduledTimer(withTimeInterval: charInterval, repeats: true) { timer in
            if visibleChars < total {
                visibleChars += 1
            } else {
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    visibleChars = 0
                    startTyping()
                }
            }
        }
    }

    /// Place a sticker, show its prompt, then write at an uneven, human pace.
    private func runHandwriting() async {
        func pause(_ seconds: Double) async -> Bool {
            try? await Task.sleep(for: .seconds(seconds))
            return !Task.isCancelled
        }

        while !Task.isCancelled {
            visibleChars = 0
            placedStickers = 0
            promptParagraph = nil
            guard await pause(0.5) else { return }

            for (index, paragraph) in Self.paragraphs.enumerated() {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                    placedStickers = index + 1
                }
                guard await pause(0.45) else { return }
                promptParagraph = index
                guard await pause(1.1) else { return }
                promptParagraph = nil
                isWriting = true
                for character in paragraph.text {
                    visibleChars += 1
                    let delay: Double
                    switch character {
                    case ".", "!", "?": delay = 0.38
                    case ",", ";": delay = 0.2
                    case " ": delay = Double.random(in: 0.04...0.09)
                    default: delay = Double.random(in: 0.025...0.055)
                    }
                    guard await pause(delay) else { return }
                }
                isWriting = false
                guard await pause(0.5) else { return }
            }
            guard await pause(2.5) else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                placedStickers = 0
                visibleChars = 0
            }
            guard await pause(0.4) else { return }
        }
    }
}


struct StickerLibraryPage: View {
    let importTargetDate: Date?
    var justAddedStickerID: String? = nil
    /// Date to auto-scroll to in the timeline (e.g. after past-date capture)
    var scrollToDate: Date? = nil
    let onImport: ([UIImage], Date) -> Void
    let onClose: () -> Void
    var onStampConsumed: () -> Void = {}
    var onStickerTap: ((StickerEntry, UIImage) -> Void)? = nil

    @State private var groups: [StickerLibraryDayGroup] = []
    @State private var selectedStickerIDs: Set<String> = []
    @State private var deletingStickerID: String?
    @State private var deleteDragTranslation: CGSize = .zero
    @State private var jigglePhase = false
    @State private var showDeleteConfirm = false
    @State private var pendingDeleteID: String?
    private let deleteCoordinateSpace = "libraryDeleteArea"
    private let calendar = Calendar.current
    private let ink = Color(red: 0.24, green: 0.17, blue: 0.14)
    private let mutedInk = Color(red: 0.54, green: 0.48, blue: 0.44)
    private var isImporting: Bool { importTargetDate != nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PaperTextureBackground()

                ScrollViewReader { scrollProxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            libraryHeader(safeTop: geo.safeAreaInsets.top)

                            if groups.isEmpty {
                                emptyState
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 24)
                                    .padding(.top, 42)
                            } else {
                                StickerLibraryTimelinePaper(
                                    groups: groups,
                                    selectedStickerIDs: selectedStickerIDs,
                                    isSelectable: isImporting,
                                    deletingStickerID: deletingStickerID,
                                    deleteDragTranslation: deleteDragTranslation,
                                    jigglePhase: jigglePhase,
                                    deleteCoordinateSpace: deleteCoordinateSpace,
                                    onSelect: handleCellTap,
                                    onDeleteLongPress: beginDeleteEditing,
                                    onDeleteDragChanged: { point, translation in
                                        deleteDragTranslation = translation
                                    },
                                    onDeleteDragEnded: { point in
                                        deleteDragTranslation = .zero
                                        if let id = deletingStickerID {
                                            confirmDelete(id)
                                        }
                                    },
                                    onDeleteConfirm: { id in
                                        pendingDeleteID = id
                                        showDeleteConfirm = true
                                    }
                                )
                                .padding(.horizontal, 24)
                            }
                        }
                        .padding(.bottom, isImporting ? 118 : 56)
                    }
                    .onAppear {
                        reload()
                        scrollToTargetDate(proxy: scrollProxy)
                    }
                }

                if isImporting, !groups.isEmpty {
                    importBar
                }

                fixedCloseButton(safeTop: geo.safeAreaInsets.top)
                    .zIndex(8)

                // Tap outside sticker to cancel delete mode
                if deletingStickerID != nil, !showDeleteConfirm {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { cancelDeleteEditing() }
                        .allowsHitTesting(false)
                        .zIndex(4)
                }
            }
        }
        .alert("删除贴纸", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let id = pendingDeleteID {
                    confirmDelete(id)
                    pendingDeleteID = nil
                }
            }
            Button("取消", role: .cancel) {
                pendingDeleteID = nil
                cancelDeleteEditing()
            }
        } message: {
            Text("确定要删除这张贴纸吗？删除后无法恢复。")
        }
    }

    private func scrollToTargetDate(proxy: ScrollViewProxy) {
        var anchorID: String?
        if let id = justAddedStickerID,
           let group = groups.first(where: { $0.items.contains(where: { $0.id == id }) }) {
            anchorID = "libgroup-\(group.date.timeIntervalSinceReferenceDate)"
        } else if let targetDate = scrollToDate,
                  let group = groups.first(where: { calendar.isDate($0.date, inSameDayAs: targetDate) }) {
            anchorID = "libgroup-\(group.date.timeIntervalSinceReferenceDate)"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let anchorID {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
            onStampConsumed()
        }
    }

    private func libraryHeader(safeTop: CGFloat) -> some View {
        VStack(spacing: 10) {
            Text("贴纸库")
                .font(DiaryFont.display(size: 32, weight: .black))
                .foregroundStyle(self.ink)
                .frame(maxWidth: .infinity)
                .padding(.top, safeTop + 54)

            Text(headerSubtitle)
                .font(DiaryFont.display(size: 14, weight: .semibold))
                .foregroundStyle(self.mutedInk.opacity(0.72))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 72)
        .padding(.bottom, 28)
    }

    private func fixedCloseButton(safeTop: CGFloat) -> some View {
        VStack {
            HStack {
                closeButton
                Spacer()
            }
            .padding(.leading, 22)
            .padding(.top, safeTop + 18)

            Spacer()
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(self.mutedInk)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.58), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.74), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回")
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color(red: 0.62, green: 0.18, blue: 0.13).opacity(0.16), style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
                    .frame(width: 150, height: 150)

                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(self.mutedInk.opacity(0.45))
            }

            VStack(spacing: 6) {
                Text("还没有贴纸")
                    .font(DiaryFont.display(size: 22, weight: .black))
                    .foregroundStyle(self.ink)

                Text("拍照生成后，会自动出现在这里。")
                    .font(DiaryFont.display(size: 15, weight: .medium))
                    .foregroundStyle(self.mutedInk.opacity(0.66))
            }
        }
    }

    private func dateSection(_ group: StickerLibraryDayGroup) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                Circle()
                    .fill(Color(red: 0.73, green: 0.43, blue: 0.17).opacity(0.72))
                    .frame(width: 9, height: 9)
                Rectangle()
                    .fill(Color(red: 0.58, green: 0.48, blue: 0.40).opacity(0.18))
                    .frame(width: 2)
            }
            .frame(width: 18)
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sectionTitle(for: group.date))
                        .font(DiaryFont.display(size: 24, weight: .black))
                        .foregroundStyle(self.ink)

                    Spacer()

                    Text("\(group.items.count) 张")
                        .font(DiaryFont.display(size: 14, weight: .bold))
                        .foregroundStyle(self.mutedInk.opacity(0.58))
                }

                StickerLibraryPaper(
                    items: group.items,
                    selectedStickerIDs: selectedStickerIDs,
                    isSelectable: isImporting,
                    deletingStickerID: deletingStickerID,
                    deleteDragTranslation: deleteDragTranslation,
                    jigglePhase: jigglePhase,
                    deleteCoordinateSpace: deleteCoordinateSpace,
                    onSelect: toggleSelection,
                    onDeleteLongPress: beginDeleteEditing,
                    onDeleteDragChanged: { point, translation in
                        deleteDragTranslation = translation
                    },
                    onDeleteDragEnded: { point in
                        deleteDragTranslation = .zero
                        if let id = deletingStickerID {
                            confirmDelete(id)
                        }
                    }
                )
            }
        }
    }

    private var importBar: some View {
        VStack {
            Spacer()

            HStack(spacing: 12) {
                Button {
                    selectedStickerIDs.removeAll()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(self.mutedInk)
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.78), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(selectedStickerIDs.isEmpty)
                .opacity(selectedStickerIDs.isEmpty ? 0.45 : 1)

                Button {
                    importSelectedStickers()
                } label: {
                    Label(selectedStickerIDs.isEmpty ? "选择贴纸" : "导入 \(selectedStickerIDs.count) 张", systemImage: "wand.and.stars")
                        .font(DiaryFont.display(size: 17))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color(red: 0.34, green: 0.24, blue: 0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(selectedStickerIDs.isEmpty)
                .opacity(selectedStickerIDs.isEmpty ? 0.55 : 1)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 18)
            .padding(.bottom, 22)
        }
    }

    private var headerSubtitle: String {
        let count = groups.reduce(0) { $0 + $1.items.count }
        if isImporting {
            return selectedStickerIDs.isEmpty ? String(localized: "选择贴纸生成这天的日记") : String(localized: "已选择 \(selectedStickerIDs.count) 张")
        }
        return String(localized: "\(count) 张贴纸 · 按日期归档")
    }

    private func handleCellTap(_ id: String) {
        if isImporting {
            toggleSelection(id)
        } else {
            // Find the item and open preview
            guard let item = groups.flatMap({ $0.items }).first(where: { $0.id == id }) else { return }
            onStickerTap?(item.entry, item.image)
        }
    }

    private func toggleSelection(_ id: String) {
        guard isImporting, deletingStickerID == nil else { return }
        if selectedStickerIDs.contains(id) {
            selectedStickerIDs.remove(id)
        } else {
            selectedStickerIDs.insert(id)
        }
    }

    private func importSelectedStickers() {
        guard let importTargetDate, !selectedStickerIDs.isEmpty else { return }
        let images = groups
            .flatMap(\.items)
            .filter { selectedStickerIDs.contains($0.id) }
            .map(\.image)
        guard !images.isEmpty else { return }
        onImport(images, importTargetDate)
    }

    private func beginDeleteEditing(_ id: String) {
        guard deletingStickerID == nil else {
            cancelDeleteEditing()
            return
        }
        deletingStickerID = id
        pendingDeleteID = id
        jigglePhase = false
        withAnimation(.easeInOut(duration: 0.11).repeatForever(autoreverses: true)) {
            jigglePhase = true
        }
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        showDeleteConfirm = true
    }

    private func confirmDelete(_ id: String) {
        StickerStore.shared.deleteSticker(id: id)
        selectedStickerIDs.remove(id)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            groups = groups.compactMap { group in
                let items = group.items.filter { $0.id != id }
                guard !items.isEmpty else { return nil }
                return StickerLibraryDayGroup(date: group.date, items: items)
            }
        }
        cancelDeleteEditing()
    }

    private func cancelDeleteEditing() {
        withAnimation(.easeOut(duration: 0.18)) {
            deletingStickerID = nil
            jigglePhase = false
        }
    }

    private func reload() {
        let entries = StickerStore.shared.loadEntries()
        let grouped = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.date)
        }

        groups = grouped
            .map { day, _ in
                let items = StickerStore.shared.loadOrderedStickersForDate(day)
                    .map { entry, image in
                        return StickerLibraryItem(entry: entry, image: image)
                    }

                return StickerLibraryDayGroup(date: day, items: items)
            }
            .filter { !$0.items.isEmpty }
            .sorted { $0.date > $1.date }
    }

    private func sectionTitle(for date: Date) -> String {
        if calendar.isDateInToday(date) { return String(localized: "今天") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }

        return AppLocale.string(from: date, chinese: "M月d日 EEEE", template: "MMMdEEEE")
    }
}

struct StickerLibraryDayGroup: Identifiable {
    var id: Date { date }
    let date: Date
    let items: [StickerLibraryItem]
}

struct StickerLibraryItem: Identifiable {
    var id: String { entry.id }
    let entry: StickerEntry
    let image: UIImage
}

struct StickerLibraryTimelinePaper: View {
    let groups: [StickerLibraryDayGroup]
    let selectedStickerIDs: Set<String>
    let isSelectable: Bool
    let deletingStickerID: String?
    let deleteDragTranslation: CGSize
    let jigglePhase: Bool
    let deleteCoordinateSpace: String
    let onSelect: (String) -> Void
    let onDeleteLongPress: (String) -> Void
    let onDeleteDragChanged: (CGPoint, CGSize) -> Void
    let onDeleteDragEnded: (CGPoint) -> Void
    var onDeleteConfirm: ((String) -> Void)? = nil

    private let ink = Color(red: 0.24, green: 0.17, blue: 0.14)
    private let mutedInk = Color(red: 0.54, green: 0.48, blue: 0.44)
    private let calendar = Calendar.current


    private let gridColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { sectionIndex, group in
                groupSection(group: group, isFirst: sectionIndex == 0)
                    .id("libgroup-\(group.date.timeIntervalSinceReferenceDate)")
            }
            Spacer().frame(height: 24)
        }
        .background(
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color(red: 0.99, green: 0.975, blue: 0.93))
                    .overlay(SingleLibraryPaperTexture())
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .stroke(Color(red: 0.46, green: 0.36, blue: 0.28).opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.04), radius: 14, y: 7)

                GeometryReader { geo in
                    Rectangle()
                        .fill(Color(red: 0.58, green: 0.48, blue: 0.40).opacity(0.18))
                        .frame(width: 2, height: max(0, geo.size.height - 80))
                        .offset(x: 26, y: 40)
                }
            }
        )
    }

    @ViewBuilder
    private func groupSection(group: StickerLibraryDayGroup, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Date header with timeline dot
            HStack(spacing: 0) {
                Circle()
                    .fill(Color(red: 0.73, green: 0.43, blue: 0.17).opacity(0.74))
                    .frame(width: 10, height: 10)
                    .frame(width: 22)

                Text(sectionTitle(for: group.date))
                    .font(DiaryFont.display(size: 24, weight: .black))
                    .foregroundStyle(ink)
                    .padding(.leading, 10)

                Spacer()

                Text("\(group.items.count) 张")
                    .font(DiaryFont.display(size: 14, weight: .bold))
                    .foregroundStyle(mutedInk.opacity(0.58))
            }
            .padding(.leading, 16)
            .padding(.trailing, 20)
            .padding(.top, isFirst ? 28 : 26)

            // 2-column sticker grid
            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { itemIndex, item in
                    StickerLibraryCell(
                        item: item,
                        isSelected: selectedStickerIDs.contains(item.id),
                        isSelectable: isSelectable,
                        isDeleting: deletingStickerID == item.id,
                        deleteDragTranslation: deleteDragTranslation,
                        jigglePhase: jigglePhase,
                        deleteCoordinateSpace: deleteCoordinateSpace,
                        onSelect: {
                            onSelect(item.id)
                        },
                        onDeleteLongPress: {
                            onDeleteLongPress(item.id)
                        },
                        onDeleteDragChanged: onDeleteDragChanged,
                        onDeleteDragEnded: onDeleteDragEnded,
                        onDeleteConfirm: onDeleteConfirm.map { callback in
                            { callback(item.id) }
                        }
                    )
                    .frame(height: 142)
                    .zIndex(deletingStickerID == item.id ? 6 : 1)
                }
            }
            .padding(.leading, 48)
            .padding(.trailing, 16)
            .padding(.top, 16)
        }
    }

    private func sectionTitle(for date: Date) -> String {
        if calendar.isDateInToday(date) { return String(localized: "今天") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }

        return AppLocale.string(from: date, chinese: "M月d日 EEEE", template: "MMMdEEEE")
    }
}

struct SingleLibraryPaperTexture: View {
    var body: some View {
        Canvas { context, size in
            for index in 0..<110 {
                let x = CGFloat((index * 47) % 997) / 997 * size.width
                let y = CGFloat((index * 89) % 991) / 991 * size.height
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: 1.3, height: 1.3)),
                    with: .color(Color(red: 0.44, green: 0.35, blue: 0.28).opacity(0.045))
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

struct StickerLibraryPaper: View {
    let items: [StickerLibraryItem]
    let selectedStickerIDs: Set<String>
    let isSelectable: Bool
    let deletingStickerID: String?
    let deleteDragTranslation: CGSize
    let jigglePhase: Bool
    let deleteCoordinateSpace: String
    let onSelect: (String) -> Void
    let onDeleteLongPress: (String) -> Void
    let onDeleteDragChanged: (CGPoint, CGSize) -> Void
    let onDeleteDragEnded: (CGPoint) -> Void
    var onDeleteConfirm: ((String) -> Void)? = nil

    private var paperHeight: CGFloat {
        let rows = max(1, (items.count + 1) / 2)
        return CGFloat(rows) * 190 + 126
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(red: 0.99, green: 0.97, blue: 0.92))
                    .overlay(LibraryPaperPattern())
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color(red: 0.50, green: 0.38, blue: 0.28).opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.035), radius: 12, y: 6)

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    StickerLibraryCell(
                        item: item,
                        isSelected: selectedStickerIDs.contains(item.id),
                        isSelectable: isSelectable,
                        isDeleting: deletingStickerID == item.id,
                        deleteDragTranslation: deleteDragTranslation,
                        jigglePhase: jigglePhase,
                        deleteCoordinateSpace: deleteCoordinateSpace,
                        onSelect: {
                            onSelect(item.id)
                        },
                        onDeleteLongPress: {
                            onDeleteLongPress(item.id)
                        },
                        onDeleteDragChanged: onDeleteDragChanged,
                        onDeleteDragEnded: onDeleteDragEnded,
                        onDeleteConfirm: onDeleteConfirm.map { callback in
                            { callback(item.id) }
                        }
                    )
                    .frame(width: 158, height: 142)
                    .position(stickerPosition(for: index, in: geo.size))
                    .zIndex(deletingStickerID == item.id ? 6 : 1)
                }
            }
        }
        .frame(height: paperHeight)
    }

    private func stickerPosition(for index: Int, in size: CGSize) -> CGPoint {
        let row = index / 2
        let column = index % 2
        let horizontalInset: CGFloat = 20
        let contentWidth = max(220, size.width - horizontalInset * 2)
        let columnWidth = contentWidth / 2
        let x = horizontalInset + columnWidth * (CGFloat(column) + 0.5)
        let y = CGFloat(row) * 190 + 148
        return CGPoint(x: x, y: y)
    }
}

struct LibraryPaperPattern: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 30) {
                ForEach(0..<18, id: \.self) { _ in
                    Rectangle()
                        .fill(Color(red: 0.50, green: 0.42, blue: 0.34).opacity(0.12))
                        .frame(height: 1)
                }
            }
            .padding(.top, 54)
            .padding(.horizontal, 24)

            VStack(spacing: 28) {
                ForEach(0..<12, id: \.self) { _ in
                    Circle()
                        .stroke(Color(red: 0.50, green: 0.42, blue: 0.34).opacity(0.16), lineWidth: 1)
                        .frame(width: 9, height: 9)
                }
            }
            .padding(.leading, 22)
            .padding(.top, 58)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

struct StickerLibraryCell: View {
    let item: StickerLibraryItem
    let isSelected: Bool
    let isSelectable: Bool
    let isDeleting: Bool
    let deleteDragTranslation: CGSize
    let jigglePhase: Bool
    let deleteCoordinateSpace: String
    let onSelect: () -> Void
    let onDeleteLongPress: () -> Void
    let onDeleteDragChanged: (CGPoint, CGSize) -> Void
    let onDeleteDragEnded: (CGPoint) -> Void
    var onDeleteConfirm: (() -> Void)? = nil

    private let ink = Color(red: 0.25, green: 0.18, blue: 0.15)
    private let mutedInk = Color(red: 0.55, green: 0.49, blue: 0.45)

    var body: some View {
        Button(action: {
            guard !isDeleting else { return }
            onSelect()
        }) {
            content
        }
        .buttonStyle(.plain)
        .offset(isDeleting ? deleteDragTranslation : .zero)
        .scaleEffect(isDeleting ? 1.05 : 1)
        .rotationEffect(.degrees(deleteJiggleAngle))
        .contentShape(Rectangle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35, maximumDistance: 10)
                .onEnded { _ in
                    onDeleteLongPress()
                }
        )
        .gesture(isDeleting ? deleteDragGesture : nil)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isDeleting)
    }

    private var content: some View {
        VStack(spacing: 0) {
            ZStack {
                Image(uiImage: item.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageSize.width, height: imageSize.height)
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 5)

                if isSelectable {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(isSelected ? Color(red: 0.34, green: 0.24, blue: 0.18) : mutedInk.opacity(0.36))
                        .background(.white.opacity(isSelected ? 0.82 : 0), in: Circle())
                        .offset(x: 50, y: -52)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 122)
        }
        .padding(6)
        .background(isSelected ? Color.white.opacity(0.70) : Color.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var deleteJiggleAngle: Double {
        guard isDeleting else { return 0 }
        return jigglePhase ? 2.2 : -2.2
    }

    private var imageSize: CGSize {
        CGSize(width: 124, height: 124)
    }

    private var deleteDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(deleteCoordinateSpace))
            .onChanged { value in
                onDeleteDragChanged(value.location, value.translation)
            }
            .onEnded { value in
                onDeleteDragEnded(value.location)
            }
    }

}

final class StickerCameraModel: NSObject, ObservableObject, @unchecked Sendable {
    /// Creating an AVCaptureSession can contact media services and delay the
    /// app's first frame. Keep camera resources lazy because the app opens on
    /// the home screen and doesn't need them until the user starts a capture.
    lazy var session = AVCaptureSession()
    private lazy var output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "DailySticker.Camera.Session")
    private var photoDelegate: PhotoCaptureDelegate?
    private var currentPosition: AVCaptureDevice.Position = .back

    @Published var isReady = false
    @Published private(set) var isUsingFrontCamera = false

    @MainActor
    func configure() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else {
            isReady = false
            isUsingFrontCamera = false
            return
        }

        let position = currentPosition
        let ready = await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: self.configureSession(position: position))
            }
        }
        isReady = ready
        isUsingFrontCamera = ready && position == .front
    }

    func start() {
        sessionQueue.async {
            guard !self.session.inputs.isEmpty, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func switchCamera() {
        currentPosition = currentPosition == .back ? .front : .back
        let position = currentPosition
        sessionQueue.async {
            let ready = self.configureSession(position: position)
            if ready, !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                self.isReady = ready
                self.isUsingFrontCamera = ready && position == .front
            }
        }
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        sessionQueue.async {
            guard !self.session.inputs.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            if let connection = self.output.connection(with: .video),
               connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = self.currentPosition == .front
            }
            let delegate = PhotoCaptureDelegate { [weak self] image in
                DispatchQueue.main.async {
                    completion(image)
                    self?.photoDelegate = nil
                }
            }
            self.photoDelegate = delegate
            self.output.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func configureSession(position: AVCaptureDevice.Position) -> Bool {
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.inputs.forEach { session.removeInput($0) }

        defer {
            session.commitConfiguration()
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return false
        }

        session.addInput(input)
        if session.canAddOutput(output), !session.outputs.contains(output) {
            session.addOutput(output)
        }
        return true
    }
}

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?) -> Void

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(nil)
            return
        }
        completion(image)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let isMirrored: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        updateMirroring(for: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        updateMirroring(for: uiView)
    }

    private func updateMirroring(for view: PreviewView) {
        guard let connection = view.videoPreviewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = isMirrored
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct ViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let length = min(rect.width, rect.height) * 0.14

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))

        return path
    }
}

struct DashedDivider: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let rows = rows(in: width, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(in: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func rows(in maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = current.width == 0 ? size.width : current.width + spacing + size.width

            if nextWidth > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }

            current.items.append(Row.Item(index: index, size: size))
            current.width = current.width == 0 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        struct Item {
            let index: Int
            let size: CGSize
        }
    }
}

enum StickerMaker {
    private static let context = CIContext()

    static func makeSticker(from image: UIImage) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            let normalized = image
                .normalizedForVision()
                .resizedForStickerProcessing(maxDimension: 1400)
            let cutout = try cutOutForeground(from: normalized)
            let cropped = cutout.croppedToVisiblePixels(padding: 30)
            return cropped
                .renderSticker(maxBorderWidth: 13)
                .resizedForStickerProcessing(maxDimension: 720)
        }.value
    }

    private static func cutOutForeground(from image: UIImage) throws -> UIImage {
        guard let cgImage = image.cgImage else {
            throw StickerError.invalidImage
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        try handler.perform([request])

        guard let observation = request.results?.first else {
            throw StickerError.noSubject
        }

        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )
        let inputImage = CIImage(cgImage: cgImage)
        let maskImage = CIImage(cvPixelBuffer: maskBuffer)
        let clearBackground = CIImage(color: .clear).cropped(to: inputImage.extent)

        let filter = CIFilter.blendWithMask()
        filter.inputImage = inputImage
        filter.backgroundImage = clearBackground
        filter.maskImage = maskImage

        guard let output = filter.outputImage,
              let outputCGImage = context.createCGImage(output, from: inputImage.extent) else {
            throw StickerError.renderFailed
        }

        return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: .up)
    }
}

enum StickerError: Error {
    case invalidImage
    case noSubject
    case renderFailed
}

extension UIImage {
    func normalizedForVision() -> UIImage {
        guard imageOrientation != .up else { return self }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func resizedForStickerProcessing(maxDimension: CGFloat) -> UIImage {
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

    func croppedToVisiblePixels(padding: CGFloat) -> UIImage {
        guard let cgImage,
              let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return self
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = max(cgImage.bitsPerPixel / 8, 4)
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let alpha = bytes[offset + bytesPerPixel - 1]
                if alpha > 12 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard minX <= maxX, minY <= maxY else { return self }

        let pixelPadding = Int(padding * scale)
        let cropX = max(minX - pixelPadding, 0)
        let cropY = max(minY - pixelPadding, 0)
        let cropMaxX = min(maxX + pixelPadding, width - 1)
        let cropMaxY = min(maxY + pixelPadding, height - 1)
        let cropRect = CGRect(
            x: cropX,
            y: cropY,
            width: cropMaxX - cropX + 1,
            height: cropMaxY - cropY + 1
        )

        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return self }
        return UIImage(cgImage: croppedCGImage, scale: scale, orientation: .up)
    }

    func renderSticker(maxBorderWidth: CGFloat) -> UIImage {
        let shortestSide = min(size.width, size.height)
        let borderWidth = min(maxBorderWidth, max(12, shortestSide * 0.035))
        let canvasSize = CGSize(
            width: size.width + borderWidth * 2,
            height: size.height + borderWidth * 2
        )
        let origin = CGPoint(x: borderWidth, y: borderWidth)
        let imageRect = CGRect(origin: origin, size: size)
        let whiteSilhouette = withTintColor(.white, renderingMode: .alwaysOriginal)

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))

            context.cgContext.setShadow(
                offset: CGSize(width: 0, height: 6),
                blur: 10,
                color: UIColor.black.withAlphaComponent(0.10).cgColor
            )

            let step = max(2, borderWidth / 7)
            var y = -borderWidth
            while y <= borderWidth {
                var x = -borderWidth
                while x <= borderWidth {
                    if hypot(x, y) <= borderWidth {
                        whiteSilhouette.draw(
                            in: imageRect.offsetBy(dx: x, dy: y),
                            blendMode: .normal,
                            alpha: 1
                        )
                    }
                    x += step
                }
                y += step
            }

            context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            draw(in: imageRect)
        }
    }

    func diaryJPEGDataURL(maxDimension: CGFloat) -> String? {
        let resized = resizedForStickerProcessing(maxDimension: maxDimension)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: resized.size, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: resized.size))
            resized.draw(in: CGRect(origin: .zero, size: resized.size))
        }
        guard let data = image.jpegData(compressionQuality: 0.78) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }
}

// MARK: - Settings Sheet

struct SettingsSheet: View {
    let onClose: () -> Void

    @State private var showContactUs = false
    @State private var showDeveloperNote = false
    @State private var showAbout = false
    @State private var showVersionInfo = false
    @State private var showShareSheet = false
    @State private var showDiaryPrompt = false
    @State private var showSubscription = false
    @State private var showWidgetGuide = false
    @State private var activeSettingsCoachStep: AppCoachStep?
    @State private var coachFrames: [AppCoachTarget: CGRect] = [:]
    @State private var coachGlobalOrigin: CGPoint = .zero
    @AppStorage("hasSeenSettingsPromptCoachV1") private var hasSeenSettingsPromptCoach = false
    @AppStorage(PencilSound.enabledKey) private var pencilSoundEnabled = true
    @AppStorage(AppFeatures.aiDiaryEnabledKey) private var aiDiaryEnabled = true
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let mutedInk = Color(red: 0.56, green: 0.56, blue: 0.58)
    private let cardBg = Color(red: 0.96, green: 0.96, blue: 0.97)
    private let accent = Color(red: 0.95, green: 0.65, blue: 0.12)

    private var proCardSubtitle: String {
        if subscriptionManager.isProUser { return String(localized: "已解锁全部功能") }
        if !AppFeatures.aiDiaryAvailable { return String(localized: "每页无限贴纸、纸张颜色和手写字体") }
        if !AppFeatures.aiDiary {
            return AppFeatures.paperThemesRequirePro ? String(localized: "全部纸张和手写字体") : String(localized: "全部手写字体")
        }
        return AppFeatures.paperThemesRequirePro ? String(localized: "日记无限生成，全部纸张和字体") : String(localized: "日记无限生成，全部手写字体")
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return v
    }

    private var shareItems: [Any] {
        let text = String(localized: "推荐你试试「贴纸日记」，每天拍照收集贴纸，再写成自己的日记。")
        if let url = URL(string: AppStoreLinks.appPage) {
            return [text, url]
        }
        return [text]
    }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    sheetTopInset

                    Image("BrandAppIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                        .padding(.leading, 24)
                        .padding(.top, 8)

                    Text("设置")
                        .font(DiaryFont.display(size: 34, weight: .black, design: .default))
                        .foregroundStyle(ink)
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                    Text("贴纸日记")
                        .font(DiaryFont.display(size: 20, weight: .black, design: .default))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 24)
                        .padding(.top, 2)

                    VStack(spacing: 16) {
                        // Pro subscription card
                        Button {
                            showSubscription = true
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [Color(red: 0.95, green: 0.65, blue: 0.12), Color(red: 0.92, green: 0.50, blue: 0.10)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 42, height: 42)
                                    Image(systemName: subscriptionManager.isProUser ? "crown.fill" : "crown")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.white)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(subscriptionManager.isProUser ? "Pro 会员" : "升级 Pro")
                                            .font(DiaryFont.display(size: 17))
                                            .foregroundStyle(ink)
                                        if !subscriptionManager.isProUser, AppFeatures.aiDiary {
                                            Text("无限生成")
                                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 2)
                                                .background(accent, in: Capsule())
                                        }
                                    }
                                    Text(proCardSubtitle)
                                        .font(DiaryFont.display(size: 13, weight: .medium))
                                        .foregroundStyle(mutedInk)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(mutedInk.opacity(0.5))
                            }
                            .padding(16)
                            .background(cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        settingsCard {
                            VStack(spacing: 0) {
                                settingsRow(icon: "square.and.arrow.up", title: String(localized: "分享给朋友")) {
                                    showShareSheet = true
                                }
                                settingsDivider
                                settingsRow(icon: "bubble.left.and.bubble.right", title: String(localized: "联系我们")) {
                                    showContactUs = true
                                }
                                settingsDivider
                                settingsRow(icon: "pencil.line", title: String(localized: "写个评价")) {
                                    showDeveloperNote = true
                                }
                            }
                        }

                        if AppFeatures.aiDiaryAvailable {
                            VStack(alignment: .leading, spacing: 8) {
                                settingsCard {
                                    VStack(spacing: 0) {
                                        settingsToggleRow(icon: "wand.and.stars", title: String(localized: "AI 帮我写日记"), isOn: $aiDiaryEnabled.animation(.easeInOut(duration: 0.2)))
                                        if aiDiaryEnabled {
                                            settingsDivider
                                            settingsRow(icon: "text.bubble", title: String(localized: "日记风格")) {
                                                finishSettingsPromptCoach()
                                                showDiaryPrompt = true
                                            }
                                            .appCoachAnchor(.settingsDiaryPrompt)
                                        }
                                    }
                                }
                                Text(aiDiaryEnabled ? "AI 会根据当天的照片写一篇日记" : "由你自己动笔写，照片只保存在手机里")
                                    .font(DiaryFont.display(size: 13, weight: .medium))
                                    .foregroundStyle(mutedInk)
                                    .padding(.horizontal, 20)
                            }
                            .onChange(of: aiDiaryEnabled) { _, enabled in
                                // The prompt row the coach points at is gone.
                                if !enabled, activeSettingsCoachStep != nil { finishSettingsPromptCoach() }
                            }
                        }

                        settingsCard {
                            VStack(spacing: 0) {
                                settingsRow(icon: "square.grid.2x2", title: String(localized: "桌面小组件")) {
                                    showWidgetGuide = true
                                }
                                settingsDivider
                                settingsToggleRow(icon: "pencil.and.scribble", title: String(localized: "写字声音"), isOn: $pencilSoundEnabled)
                            }
                        }

                        settingsCard {
                            VStack(spacing: 0) {
                                settingsRow(icon: "info.circle", title: String(localized: "关于贴纸日记")) {
                                    showAbout = true
                                }
                                settingsDivider
                                settingsRow(icon: "doc.text", title: String(localized: "版本信息"), trailing: appVersion) {
                                    showVersionInfo = true
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 26)

                    Text("每天的小确幸，都值得被贴下来。")
                        .font(DiaryFont.display(size: 14, weight: .medium, design: .default))
                        .foregroundStyle(mutedInk.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                        .padding(.bottom, 40)
                }
            }

            if let activeSettingsCoachStep {
                AppCoachOverlay(
                    step: activeSettingsCoachStep,
                    targetFrame: coachFrames[activeSettingsCoachStep.target],
                    globalOrigin: coachGlobalOrigin,
                    onAction: {
                        finishSettingsPromptCoach()
                        showDiaryPrompt = true
                    },
                    onSkip: finishSettingsPromptCoach
                )
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .background(AppCoachOriginReader())
        .onPreferenceChange(AppCoachOriginPreferenceKey.self) { origin in
            coachGlobalOrigin = origin
        }
        .onPreferenceChange(AppCoachFramePreferenceKey.self) { frames in
            coachFrames = frames
        }
        .onAppear {
            scheduleSettingsPromptCoachIfNeeded()
        }
        .sheet(isPresented: $showContactUs) {
            ContactUsPage()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
                .presentationBackground(.white)
        }
        .sheet(isPresented: $showDeveloperNote) {
            DeveloperNoteSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
                .presentationBackground(.white)
        }
        .sheet(isPresented: $showAbout) {
            AboutAppSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
                .presentationBackground(.white)
        }
        .sheet(isPresented: $showVersionInfo) {
            VersionInfoSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
                .presentationBackground(.white)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheetView(items: shareItems)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDiaryPrompt) {
            DiaryPromptSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
                .presentationBackground(.white)
        }
        .sheet(isPresented: $showSubscription) {
            SubscriptionSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
                .presentationBackground(.white)
        }
        .sheet(isPresented: $showWidgetGuide) {
            WidgetGuideSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
                .presentationBackground(.white)
        }
    }

    private func scheduleSettingsPromptCoachIfNeeded() {
        guard AppFeatures.aiDiary, !hasSeenSettingsPromptCoach, activeSettingsCoachStep == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) {
            guard !hasSeenSettingsPromptCoach, activeSettingsCoachStep == nil else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                activeSettingsCoachStep = .settingsDiaryPrompt
            }
        }
    }

    private func finishSettingsPromptCoach() {
        hasSeenSettingsPromptCoach = true
        withAnimation(.easeInOut(duration: 0.18)) {
            activeSettingsCoachStep = nil
        }
    }

    // No close button: these sheets are dismissed by swiping down.
    private var sheetTopInset: some View {
        Color.clear.frame(height: 28)
    }

    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(cardBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.9))
            .frame(height: 1)
            .padding(.leading, 72)
            .padding(.trailing, 20)
    }

    private func settingsRow(icon: String, title: String, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                settingsIcon(icon)
                Text(title)
                    .font(DiaryFont.display(size: 17, weight: .bold, design: .default))
                    .foregroundStyle(ink)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(DiaryFont.display(size: 14, weight: .semibold, design: .default))
                        .foregroundStyle(mutedInk)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(red: 0.78, green: 0.78, blue: 0.80))
            }
            .frame(height: 68)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsToggleRow(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            settingsIcon(icon)
            Toggle(isOn: isOn) {
                Text(title)
                    .font(DiaryFont.display(size: 17, weight: .bold, design: .default))
                    .foregroundStyle(ink)
            }
            .tint(Color(red: 0.48, green: 0.25, blue: 0.17))
        }
        .frame(height: 68)
        .padding(.horizontal, 20)
    }

    private func settingsIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(ink)
            .symbolRenderingMode(.monochrome)
            .frame(width: 38, height: 38)
    }
}

enum AppStoreLinks {
    static let appID = "6775458248"
    static let appPage = "https://apps.apple.com/app/id\(appID)"
    static let writeReview = "\(appPage)?action=write-review"
}

// MARK: - Diary Prompt Sheet

// MARK: - Subscription Sheet

struct SubscriptionSheet: View {
    @ObservedObject private var manager = SubscriptionManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProduct: SubscriptionProduct = .yearly
    @State private var isPurchasing = false

    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let mutedInk = Color(red: 0.56, green: 0.56, blue: 0.58)
    private let accent = Color(red: 0.95, green: 0.65, blue: 0.12)
    private let warmBg = Color(red: 0.98, green: 0.96, blue: 0.93)

    var body: some View {
        ZStack {
            warmBg.ignoresSafeArea()

            // Fits on one screen without scrolling; only falls back to a
            // ScrollView on very short devices. No close button — swipe down.
            ViewThatFits(in: .vertical) {
                sheetContent
                    .frame(maxHeight: .infinity)
                ScrollView(showsIndicators: false) {
                    sheetContent
                }
            }
        }
        .alert("提示", isPresented: $manager.showError) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(manager.errorMessage)
        }
        .task { await manager.loadProducts() }
    }

    @ViewBuilder
    private var sheetContent: some View {
        if manager.isProUser {
            proUserContent
        } else {
            freeUserContent
        }
    }

    // MARK: - Pro User (already subscribed)

    private var proUserContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "crown.fill")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [accent, Color(red: 0.92, green: 0.50, blue: 0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(.top, 48)

            Text("你已经是 Pro 会员")
                .font(DiaryFont.display(size: 26, weight: .black))
                .foregroundStyle(ink)

            VStack(spacing: 12) {
                if AppFeatures.aiDiaryAvailable {
                    proFeatureRow(icon: "infinity", text: String(localized: "无限 AI 日记生成"))
                }
                if AppFeatures.stickersPerPageRequirePro {
                    proFeatureRow(icon: "square.stack.3d.up", text: String(localized: "每页无限贴纸"))
                }
                if AppFeatures.paperThemesRequirePro {
                    proFeatureRow(icon: "paintpalette", text: String(localized: "全部纸张主题"))
                }
                proFeatureRow(icon: "textformat", text: String(localized: "全部手写字体"))
            }
            .padding(.top, 8)

            if manager.ownsLifetime {
                Text("终身会员 · 永久有效")
                    .font(DiaryFont.display(size: 15, weight: .bold))
                    .foregroundStyle(accent)
            }

            Text("感谢你的支持 ☕️")
                .font(DiaryFont.display(size: 15, weight: .medium))
                .foregroundStyle(mutedInk)
                .padding(.top, 16)

            // Buying lifetime doesn't stop an existing plan from renewing.
            if manager.ownsLifetime && manager.hasActiveSubscription {
                Text("你已拥有终身会员，记得取消原来的自动续期订阅，避免重复扣费")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(mutedInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
            }

            if manager.hasActiveSubscription {
                Button {
                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("管理订阅")
                        .font(DiaryFont.display(size: 15, weight: .bold))
                        .foregroundStyle(accent)
                }
                .padding(.top, 8)
            }
        }
        .padding(.bottom, 60)
    }

    private func proFeatureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 28)
            Text(text)
                .font(DiaryFont.display(size: 16, weight: .semibold))
                .foregroundStyle(ink)
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Free User (subscription offer)

    private var billingNote: String {
        guard selectedProduct.isSubscription else { return String(localized: "一次性购买，不会自动续期") }
        if let days = manager.freeTrialDays(for: selectedProduct),
           let product = manager.product(for: selectedProduct) {
            return String(localized: "\(days) 天免费，之后 \(selectedProduct.pricePerPeriod(product.displayPrice))，可随时取消")
        }
        return String(localized: "订阅将自动续期，可随时在系统设置中取消")
    }

    private var premiumPaperCount: Int { DiaryPaperColor.allCases.filter(\.isPremium).count }
    private var premiumFontCount: Int { DiaryHandwriting.available.filter(\.isPremium).count }

    private var freeUserContent: some View {
        VStack(spacing: 0) {
            // Hero
            VStack(spacing: 4) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [accent, Color(red: 0.92, green: 0.50, blue: 0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text("升级 Pro")
                    .font(DiaryFont.display(size: 28, weight: .black))
                    .foregroundStyle(ink)
            }
            .padding(.top, 30)

            Spacer(minLength: 16)

            // Features: what Pro unlocks in this edition, and nothing else.
            // Uses aiDiaryAvailable, not aiDiary: Pro still includes AI for
            // Chinese users who have switched AI writing off.
            VStack(alignment: .leading, spacing: 14) {
                if AppFeatures.aiDiaryAvailable {
                    featureRow(icon: "infinity", title: String(localized: "AI 日记不限次数"), desc: String(localized: "免费版每天 \(DailyQuotaManager.maxFreeGenerations) 次"))
                }
                if AppFeatures.stickersPerPageRequirePro {
                    featureRow(icon: "square.stack.3d.up", title: String(localized: "每页无限贴纸"), desc: String(localized: "免费版每页最多 \(PageStickerLimit.freeLimit) 张"))
                }
                if AppFeatures.paperThemesRequirePro {
                    featureRow(icon: "paintpalette", title: String(localized: "\(premiumPaperCount) 款纸张主题"), desc: String(localized: "牛皮纸、复古、樱粉、天蓝等"))
                }
                featureRow(
                    icon: "textformat",
                    title: String(localized: "\(premiumFontCount) 款手写字体"),
                    desc: AppLocale.isChinese
                        ? String(localized: "小赖、站酷快乐体、马善政楷书等")
                        : "Caveat, Kalam, Indie Flower and more"
                )
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 24)

            Spacer(minLength: 16)

            // Product cards
            VStack(spacing: 10) {
                ForEach(SubscriptionProduct.allCases, id: \.rawValue) { sub in
                    productCard(sub)
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 18)

            // Subscribe button
            Button {
                Task {
                    isPurchasing = true
                    guard let product = manager.product(for: selectedProduct) else {
                        manager.errorMessage = String(localized: "这个订阅商品暂时不可用，请稍后重试。")
                        manager.showError = true
                        isPurchasing = false
                        return
                    }
                    let success = await manager.purchase(product)
                    if success { dismiss() }
                    isPurchasing = false
                }
            } label: {
                Group {
                    if isPurchasing || manager.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else if let days = manager.freeTrialDays(for: selectedProduct) {
                        Text(String(localized: "免费试用 \(days) 天"))
                            .font(DiaryFont.display(size: 18))
                    } else if selectedProduct == .lifetime {
                        Text("立即购买")
                            .font(DiaryFont.display(size: 18))
                    } else {
                        Text("开始订阅")
                            .font(DiaryFont.display(size: 18))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    LinearGradient(
                        colors: [accent, Color(red: 0.92, green: 0.50, blue: 0.10)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .shadow(color: accent.opacity(0.3), radius: 16, y: 8)
            }
            .disabled(isPurchasing || manager.isLoading)
            .padding(.horizontal, 24)

            // One billing line for the selected plan. With a trial, Apple
            // requires the post-trial price right next to the button.
            Text(billingNote)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(mutedInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
                .padding(.top, 10)

            // Restore, redeem & legal on one row
            HStack(spacing: 6) {
                Button("恢复购买") {
                    Task { await manager.restorePurchases() }
                }
                Text(verbatim: "·")
                Button("兑换会员码") {
                    manager.redeemOfferCode()
                }
                Text(verbatim: "·")
                Link("使用条款", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Text(verbatim: "·")
                Link("隐私政策", destination: LegalPage.privacy.url)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(mutedInk.opacity(0.8))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
    }

    private func productCard(_ sub: SubscriptionProduct) -> some View {
        let isSelected = selectedProduct == sub
        let storeProduct = manager.product(for: sub)
        let displayPrice = storeProduct?.displayPrice ?? sub.fallbackDisplayPrice

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                selectedProduct = sub
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(isSelected ? accent : mutedInk.opacity(0.3), lineWidth: isSelected ? 6 : 2)
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .fill(accent)
                            .frame(width: 10, height: 10)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(sub.displayName)
                            .font(DiaryFont.display(size: 17, weight: .bold))
                            .foregroundStyle(ink)
                        if let tag = sub.savingTag(monthly: manager.product(for: .monthly), yearly: manager.product(for: .yearly)) {
                            Text(tag)
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.85), in: Capsule())
                        }
                    }
                    Text(sub.subtitle(for: storeProduct))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(mutedInk)
                    if let days = manager.freeTrialDays(for: sub) {
                        Text(String(localized: "\(days) 天免费试用"))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                    }
                }

                Spacer()

                Text(displayPrice)
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(isSelected ? accent : ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.08) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? accent : mutedInk.opacity(0.15), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func featureRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DiaryFont.display(size: 16, weight: .bold))
                    .foregroundStyle(ink)
                Text(desc)
                    .font(DiaryFont.display(size: 13, weight: .medium))
                    .foregroundStyle(mutedInk)
            }
            Spacer()
        }
    }

}

// MARK: - Shared Prompt Templates

struct DiaryPromptTemplate: Identifiable {
    let id: String
    let emoji: String
    let name: String
    let description: String
    let chinesePrompt: String
    let englishPrompt: String

    /// The system prompt in the language the diary will be written in.
    var prompt: String {
        AppLocale.isChinese ? chinesePrompt : englishPrompt
    }
}

let diaryPromptTemplates: [DiaryPromptTemplate] = [
    DiaryPromptTemplate(
        id: "default",
        emoji: "\u{2615}",
        name: String(localized: "温柔日常"),
        description: String(localized: "平静温暖，像和朋友聊天"),
        chinesePrompt: BailianDiaryGenerator.chineseDefaultSystemPrompt,
        englishPrompt: BailianDiaryGenerator.englishDefaultSystemPrompt
    ),
    DiaryPromptTemplate(
        id: "happy",
        emoji: "\u{2728}",
        name: String(localized: "开心活泼"),
        description: String(localized: "元气满满，充满感叹号"),
        chinesePrompt: "你是一位开朗、活泼、充满元气的中文日记作者。你会根据用户当天拍的照片，识别物品和场景，用欢快明亮的语气写成日记。多用感叹句和俏皮的比喻，让每一天都读起来像值得庆祝的小事件。绝对不要在日记正文中出现「贴纸」这个词。",
        englishPrompt: "You are a cheerful, upbeat diary writer bursting with energy. Based on the photos the user took today, you recognize the objects and scenes and write the diary in a bright, happy voice. Use exclamations and playful comparisons so every day reads like a little event worth celebrating. Never use the word \"sticker\" in the diary text."
    ),
    DiaryPromptTemplate(
        id: "calm",
        emoji: "\u{1F343}",
        name: String(localized: "安静治愈"),
        description: String(localized: "轻柔缓慢，像雨天读书"),
        chinesePrompt: "你是一位安静、细腻、善于感受的中文日记作者。你会根据用户当天拍的照片，识别物品和场景，用舒缓治愈的文字写成日记。语调轻柔，节奏慢一些，关注细微的感官体验——光线、气味、温度、质感。让人读完觉得被轻轻抱了一下。绝对不要在日记正文中出现「贴纸」这个词。",
        englishPrompt: "You are a quiet, gentle diary writer who notices small feelings. Based on the photos the user took today, you recognize the objects and scenes and write the diary in soothing, comforting prose. Keep the tone soft and the pace slow, and linger on small sensory details: light, smell, warmth, texture. It should feel like a gentle hug to read. Never use the word \"sticker\" in the diary text."
    ),
    DiaryPromptTemplate(
        id: "literary",
        emoji: "\u{1F319}",
        name: String(localized: "文艺感伤"),
        description: String(localized: "诗意忧郁，像深夜独白"),
        chinesePrompt: "你是一位文艺、敏感、略带忧伤的中文日记作者。你会根据用户当天拍的照片，识别物品和场景，用诗意的笔触写成日记。可以有淡淡的感伤和怀旧，善用意象和留白，让文字像一首没写完的诗。绝对不要在日记正文中出现「贴纸」这个词。",
        englishPrompt: "You are a sensitive, literary diary writer with a touch of melancholy. Based on the photos the user took today, you recognize the objects and scenes and write the diary with a poetic hand. A little wistfulness and nostalgia is welcome; use imagery and leave things unsaid, so it reads like an unfinished poem. Never use the word \"sticker\" in the diary text."
    ),
    DiaryPromptTemplate(
        id: "humor",
        emoji: "\u{1F643}",
        name: String(localized: "幽默吐槽"),
        description: String(localized: "轻松搞笑，自带段子手属性"),
        chinesePrompt: "你是一位幽默、机智、善于吐槽的中文日记作者。你会根据用户当天拍的照片，识别物品和场景，用轻松诙谐的语气写成日记。适当加入自嘲和生活吐槽，像在跟好朋友发消息一样随意有趣。绝对不要在日记正文中出现「贴纸」这个词。",
        englishPrompt: "You are a witty, funny diary writer with a talent for wry observations. Based on the photos the user took today, you recognize the objects and scenes and write the diary in a light, humorous voice. Add a bit of self-deprecation and everyday grumbling, casual and fun like texting a best friend. Never use the word \"sticker\" in the diary text."
    ),
    DiaryPromptTemplate(
        id: "minimal",
        emoji: "\u{1F4DD}",
        name: String(localized: "简洁记录"),
        description: String(localized: "干净利落，只留关键信息"),
        chinesePrompt: "你是一位简洁、克制的中文日记作者。你会根据用户当天拍的照片，识别物品和场景，用最精炼的文字记录当天发生了什么。不堆砌形容词，不抒情，像备忘录一样干净利落，但仍然有温度。绝对不要在日记正文中出现「贴纸」这个词。",
        englishPrompt: "You are a concise, understated diary writer. Based on the photos the user took today, you recognize the objects and scenes and record what happened in as few words as possible. No piles of adjectives, no gushing: clean and to the point like a memo, but still warm. Never use the word \"sticker\" in the diary text."
    ),
]

func matchingPromptTemplateId() -> String? {
    let current = BailianDiaryGenerator.currentSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return diaryPromptTemplates.first(where: { $0.prompt == current })?.id
}

// MARK: - Quick Prompt Picker (日记页内)

struct QuickPromptPicker: View {
    var onDismiss: (_ didChangePrompt: Bool) -> Void
    @State private var activeId: String? = matchingPromptTemplateId()
    @Environment(\.dismiss) private var dismiss

    private let ink = Color(red: 0.34, green: 0.24, blue: 0.18)
    private let mutedInk = Color(red: 0.56, green: 0.50, blue: 0.46)
    private let accent = Color(red: 0.95, green: 0.65, blue: 0.12)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("日记风格")
                        .font(DiaryFont.display(size: 22, weight: .black))
                        .foregroundStyle(ink)
                    Text("选择后重新生成即可切换")
                        .font(DiaryFont.display(size: 13, weight: .medium))
                        .foregroundStyle(mutedInk)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(mutedInk)
                        .frame(width: 28, height: 28)
                        .background(Color(red: 0.92, green: 0.89, blue: 0.85), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            // Template list
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(diaryPromptTemplates) { template in
                        quickTemplateRow(template)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private func quickTemplateRow(_ template: DiaryPromptTemplate) -> some View {
        let isActive = activeId == template.id
        return Button {
            let wasActive = activeId == template.id
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                activeId = template.id
            }
            BailianDiaryGenerator.currentSystemPrompt = template.prompt
            if !wasActive {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    onDismiss(true)
                }
            }
        } label: {
            HStack(spacing: 14) {
                Text(template.emoji)
                    .font(.system(size: 28))
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .font(DiaryFont.display(size: 16, weight: .bold))
                        .foregroundStyle(isActive ? accent : ink)
                    Text(template.description)
                        .font(DiaryFont.display(size: 13, weight: .medium))
                        .foregroundStyle(isActive ? accent.opacity(0.7) : mutedInk)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(accent)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isActive ? accent.opacity(0.08) : Color(red: 0.96, green: 0.94, blue: 0.91))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isActive ? accent.opacity(0.5) : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

struct DiaryPromptSheet: View {
    @State private var selectedTemplateId: String? = matchingPromptTemplateId()

    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let mutedInk = Color(red: 0.56, green: 0.56, blue: 0.58)
    private let accent = Color(red: 0.95, green: 0.65, blue: 0.12)
    private let cardBg = Color(red: 0.96, green: 0.96, blue: 0.97)

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 28)

                    Text("日记风格")
                        .font(DiaryFont.display(size: 34, weight: .black, design: .default))
                        .foregroundStyle(ink)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                    Text("选一个喜欢的风格，AI 会用它来写日记")
                        .font(DiaryFont.display(size: 15, weight: .medium, design: .default))
                        .foregroundStyle(mutedInk)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)

                    VStack(spacing: 10) {
                        ForEach(diaryPromptTemplates) { template in
                            templateRow(template)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                    Text("切换后对新生成的日记生效，已写好的日记不会改变")
                        .font(DiaryFont.display(size: 13, weight: .medium, design: .default))
                        .foregroundStyle(mutedInk.opacity(0.8))
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 40)
                }
            }
        }
    }

    private func templateRow(_ template: DiaryPromptTemplate) -> some View {
        let isActive = selectedTemplateId == template.id
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                selectedTemplateId = template.id
            }
            BailianDiaryGenerator.currentSystemPrompt = template.prompt
        } label: {
            HStack(spacing: 14) {
                Text(template.emoji)
                    .font(.system(size: 28))
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .font(DiaryFont.display(size: 16, weight: .bold, design: .default))
                        .foregroundStyle(isActive ? accent : ink)
                    Text(template.description)
                        .font(DiaryFont.display(size: 13, weight: .medium, design: .default))
                        .foregroundStyle(isActive ? accent.opacity(0.8) : mutedInk)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(accent)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isActive ? accent.opacity(0.08) : cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isActive ? accent : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Contact Us Page

struct ContactUsPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copiedEmail = false
    @State private var showMailComposer = false
    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let mutedInk = Color(red: 0.56, green: 0.56, blue: 0.58)
    private let cardBg = Color(red: 0.96, green: 0.96, blue: 0.97)
    private let accent = Color(red: 0.95, green: 0.65, blue: 0.12)
    private let email = FeedbackMail.recipient

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    sheetTopInset

                    Image("BrandAppIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                        .padding(.leading, 24)
                        .padding(.top, 8)

                    Text("联系我们")
                        .font(DiaryFont.display(size: 34, weight: .black, design: .default))
                        .foregroundStyle(ink)
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                    Text("贴纸日记")
                        .font(DiaryFont.display(size: 20, weight: .black, design: .default))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 24)
                        .padding(.top, 2)

                    VStack(spacing: 0) {
                        emailRow
                        settingsDivider
                        reviewRow
                        // Xiaohongshu is only meaningful to Chinese-speaking users.
                        if AppLocale.isChinese {
                            settingsDivider
                            xiaohongshuRow
                        }
                    }
                    .background(cardBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 28)

                    Text("有想法、问题或者想分享你的贴纸日记，都可以来找我。")
                        .font(DiaryFont.display(size: 15, weight: .regular, design: .default))
                        .foregroundStyle(mutedInk)
                        .lineSpacing(5)
                        .padding(20)
                        .background(cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    Color.clear.frame(height: 40)
                }
            }
        }
        .sheet(isPresented: $showMailComposer) {
            FeedbackMailComposer()
                .ignoresSafeArea()
        }
    }

    // No close button: these sheets are dismissed by swiping down.
    private var sheetTopInset: some View {
        Color.clear.frame(height: 28)
    }

    /// 优先用系统写信界面；没配置邮件账户时退回 mailto:（可能打开 Gmail 等第三方），都不行就复制地址。
    private func composeFeedback() {
        if MFMailComposeViewController.canSendMail() {
            showMailComposer = true
        } else if let url = FeedbackMail.mailtoURL {
            UIApplication.shared.open(url) { opened in
                if !opened { copyEmail() }
            }
        } else {
            copyEmail()
        }
    }

    private func copyEmail() {
        UIPasteboard.general.string = email
        withAnimation { copiedEmail = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copiedEmail = false }
        }
    }

    private var emailRow: some View {
        HStack(spacing: 14) {
            Button(action: composeFeedback) {
                HStack(spacing: 14) {
                    contactIcon("envelope.fill", color: Color(red: 0.20, green: 0.50, blue: 0.90))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("发邮件反馈")
                            .font(DiaryFont.display(size: 17, weight: .bold, design: .default))
                            .foregroundStyle(ink)
                        Text(email)
                            .font(DiaryFont.display(size: 14, weight: .medium, design: .default))
                            .foregroundStyle(mutedInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: copyEmail) {
                Image(systemName: copiedEmail ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(copiedEmail ? Color.green : mutedInk)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.9), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 72)
        .padding(.horizontal, 20)
    }

    private var reviewRow: some View {
        Button {
            if let url = URL(string: AppStoreLinks.writeReview) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 14) {
                contactIcon("star.fill", color: accent)
                Text("写个评价")
                    .font(DiaryFont.display(size: 17, weight: .bold, design: .default))
                    .foregroundStyle(ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(red: 0.78, green: 0.78, blue: 0.80))
            }
            .frame(height: 72)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var xiaohongshuRow: some View {
        Button {
            if let url = URL(string: "https://www.xiaohongshu.com/user/profile/608e5e7500000000010050c2") {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 14) {
                contactIcon("camera.fill", color: Color(red: 0.92, green: 0.20, blue: 0.30))
                Text("小红书")
                    .font(DiaryFont.display(size: 17, weight: .bold, design: .default))
                    .foregroundStyle(ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(red: 0.78, green: 0.78, blue: 0.80))
            }
            .frame(height: 72)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.9))
            .frame(height: 1)
            .padding(.leading, 72)
            .padding(.trailing, 20)
    }

    private func contactIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(color, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - Developer Note

/// 设置里「写个评价」：先看开发者的一封信，再由用户自己决定去写评价或发邮件。
/// 两个按钮对所有人都一样显示，不按满意度分流（App Store 审核指南 5.6.1）。
struct DeveloperNoteSheet: View {
    @State private var showMailComposer = false
    private let ink = Color(red: 0.24, green: 0.17, blue: 0.13)
    private let mutedInk = Color(red: 0.54, green: 0.48, blue: 0.44)
    private let paper = Color(red: 0.98, green: 0.95, blue: 0.90)
    private let accent = Color(red: 0.95, green: 0.65, blue: 0.12)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // No close button: dismissed by swiping down.
                Color.clear.frame(height: 28)

                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "envelope.open.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(accent)

                    Text("来自开发者的一封信")
                        .font(DiaryFont.display(size: 26, weight: .black, design: .default))
                        .foregroundStyle(ink)

                    Text("你好，我是贴纸日记的开发者。这个 App 是我一个人利用业余时间做的。")
                    Text("如果它让你的日子多了一点点可爱，能不能花 10 秒在 App Store 留一句话？每一条评价我都会认真看，也能帮助更多人发现这个小 App。")
                    Text("谢谢你愿意用贴纸日记记录生活，谢谢你看到这里 ♡")
                        .foregroundStyle(accent)
                        .fontWeight(.semibold)
                }
                .font(DiaryFont.display(size: 16, weight: .regular, design: .default))
                .foregroundStyle(ink)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .background(paper, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Button(action: openWriteReview) {
                    Label("去 App Store 写评价", systemImage: "star.fill")
                        .font(DiaryFont.display(size: 17, weight: .bold, design: .default))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 24)

                VStack(spacing: 6) {
                    Text("有不满意的地方？")
                        .foregroundStyle(mutedInk)
                    Button("直接发邮件给我，我会亲自回复", action: composeFeedback)
                        .fontWeight(.semibold)
                        .foregroundStyle(ink)
                        .underline()
                }
                .font(DiaryFont.display(size: 15, weight: .regular, design: .default))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showMailComposer) {
            FeedbackMailComposer()
                .ignoresSafeArea()
        }
    }

    private func openWriteReview() {
        if let url = URL(string: AppStoreLinks.writeReview) {
            UIApplication.shared.open(url)
        }
    }

    /// 和「联系我们」一致：优先系统写信界面，没有邮件账户时退回 mailto:，再不行就复制地址。
    private func composeFeedback() {
        if MFMailComposeViewController.canSendMail() {
            showMailComposer = true
        } else if let url = FeedbackMail.mailtoURL {
            UIApplication.shared.open(url) { opened in
                if !opened { UIPasteboard.general.string = FeedbackMail.recipient }
            }
        } else {
            UIPasteboard.general.string = FeedbackMail.recipient
        }
    }
}

// MARK: - Feedback Mail

enum FeedbackMail {
    static let recipient = "raowenjieszu@gmail.com"

    static var subject: String {
        String(localized: "贴纸日记反馈") + " v\(appVersion)"
    }

    /// 预留空行给用户写内容，末尾附上排查问题需要的环境信息。
    static var body: String {
        """


        ——
        \(String(localized: "App 版本")): \(appVersion) (\(buildNumber))
        iOS: \(UIDevice.current.systemVersion)
        \(String(localized: "设备")): \(deviceModel)
        """
    }

    static var mailtoURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// 机型标识，如 iPhone17,1。
    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

struct FeedbackMailComposer: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([FeedbackMail.recipient])
        controller.setSubject(FeedbackMail.subject)
        controller.setMessageBody(FeedbackMail.body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            dismiss()
        }
    }
}

// MARK: - About App Sheet

struct AboutAppSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let mutedInk = Color(red: 0.56, green: 0.56, blue: 0.58)
    private let accent = Color(red: 0.95, green: 0.65, blue: 0.12)

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 28)

                    // App icon (left-aligned, like nosh)
                    Image("BrandAppIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 110, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                        .padding(.leading, 24)
                        .padding(.top, 8)

                    // App name
                    Text("贴纸日记：")
                        .font(DiaryFont.display(size: 28, weight: .black, design: .default))
                        .foregroundStyle(ink)
                        .padding(.leading, 24)
                        .padding(.top, 16)

                    // Tagline with colored brackets
                    HStack(spacing: 0) {
                        Text("收集我的「")
                            .font(DiaryFont.display(size: 28, weight: .black, design: .default))
                            .foregroundStyle(ink)
                        Text("贴纸日记")
                            .font(DiaryFont.display(size: 28, weight: .black, design: .default))
                            .foregroundStyle(accent)
                        Text("」")
                            .font(DiaryFont.display(size: 28, weight: .black, design: .default))
                            .foregroundStyle(accent)
                    }
                    .padding(.leading, 24)
                    .padding(.top, 2)

                    // Story card
                    VStack(alignment: .leading, spacing: 14) {
                        Text("📒 把每天的小物件，收进一页日记")
                            .font(DiaryFont.display(size: 17, weight: .bold, design: .default))
                            .foregroundStyle(ink)

                        Text("生活里有很多很轻的小瞬间：一杯饮料、一张票根、一只新买的小物、路边看到的花。它们很容易被拍进相册，也很容易被忘在相册深处。")
                            .font(DiaryFont.display(size: 15, weight: .regular, design: .default))
                            .foregroundStyle(mutedInk)
                            .lineSpacing(5)

                        Text("贴纸日记想做的事情很简单：把这些零散的照片变成贴纸，再把贴纸放回当天的日记里。")
                            .font(DiaryFont.display(size: 15, weight: .regular, design: .default))
                            .foregroundStyle(mutedInk)
                            .lineSpacing(5)

                        Text("拍一张照片，AI 自动识别并抠图，生成一张属于今天的贴纸。等你回头翻看时，看到的不只是图片，而是那一天被留下来的心情。")
                            .font(DiaryFont.display(size: 15, weight: .regular, design: .default))
                            .foregroundStyle(ink)
                            .lineSpacing(5)

                        Text("✨ 每一天，都可以被轻轻贴下来")
                            .font(DiaryFont.display(size: 17, weight: .bold, design: .default))
                            .foregroundStyle(ink)
                            .padding(.top, 4)

                        Text("你可以让贴纸日记帮你生成文字，也可以自己慢慢写。重要的不是记录得多完整，而是那些普通但可爱的东西，终于有了自己的位置。")
                            .font(DiaryFont.display(size: 15, weight: .regular, design: .default))
                            .foregroundStyle(mutedInk)
                            .lineSpacing(5)
                    }
                    .padding(20)
                    .background(Color(red: 0.96, green: 0.96, blue: 0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                    Color.clear.frame(height: 40)
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Version Info Sheet

struct VersionInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let mutedInk = Color(red: 0.56, green: 0.56, blue: 0.58)
    private let cardBg = Color(red: 0.96, green: 0.96, blue: 0.97)

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                Color.clear.frame(height: 28)

                Spacer().frame(height: 12)

                // App icon
                Image("BrandAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)

                Spacer().frame(height: 16)

                // App name + version
                Text("贴纸日记 \(appVersion)")
                    .font(DiaryFont.display(size: 24, weight: .bold, design: .default))
                    .foregroundStyle(ink)

                Spacer().frame(height: 20)

                // Description
                VStack(alignment: .leading, spacing: 12) {
                    Text("贴纸日记用 AI 技术识别并抠出照片里的主体，将它们变成当天的贴纸，再放进你的专属日记里。")
                        .font(DiaryFont.display(size: 15, weight: .regular, design: .default))
                        .foregroundStyle(mutedInk)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)

                    Text("贴纸和日记默认保存在本机；当你使用 AI 生成日记时，当天贴纸会发送到配置的模型服务用于生成内容。")
                        .font(DiaryFont.display(size: 15, weight: .regular, design: .default))
                        .foregroundStyle(mutedInk)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)

                Spacer().frame(height: 28)

                // Links card
                VStack(spacing: 0) {
                    linkRow(title: String(localized: "用户协议")) {
                        openExternalURL(LegalPage.terms.url.absoluteString)
                    }
                    Divider().padding(.leading, 20)
                    linkRow(title: String(localized: "隐私政策")) {
                        openExternalURL(LegalPage.privacy.url.absoluteString)
                    }
                }
                .background(cardBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 24)

                Spacer()

                // Copyright
                Text("Copyright © 贴纸日记. All Rights Reserved.")
                    .font(.system(size: 13))
                    .foregroundStyle(mutedInk.opacity(0.7))
                    .padding(.bottom, 30)
            }
        }
        .presentationDetents([.large])
    }

    private func linkRow(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(DiaryFont.display(size: 17, weight: .regular, design: .default))
                    .foregroundStyle(ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.78, green: 0.78, blue: 0.80))
            }
            .padding(.vertical, 15)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openExternalURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Share Preview

extension UIImage: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

struct SharePreviewOverlay: View {
    let image: UIImage
    let activeCoachStep: AppCoachStep?
    let onCoachCompleteClose: () -> Void
    /// When set, shows a watermark switch; `rerender` redraws the image after it flips.
    var watermarkEnabled: Binding<Bool>? = nil
    var rerender: (() -> UIImage)? = nil
    let onClose: () -> Void
    let onShare: () -> Void

    private let ink = Color(red: 0.22, green: 0.15, blue: 0.12)
    @State private var showCoachGuide = false
    @State private var renderedImage: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            PaperTextureBackground()

            VStack(spacing: 0) {
                HStack {
                    Button(action: closePreview) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(ink)
                            .frame(width: 48, height: 48)
                            .background(.white.opacity(0.70), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("返回"))

                    Spacer()

                    Text("预览")
                        .font(DiaryFont.display(size: 17))
                        .foregroundStyle(ink)

                    Spacer()

                    Button(action: onShare) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Color(red: 0.34, green: 0.24, blue: 0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("分享"))
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)

                if let watermarkEnabled {
                    watermarkToggle(watermarkEnabled)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                }

                ScrollView {
                    VStack(spacing: 16) {
                        Image(uiImage: renderedImage ?? image)
                            .resizable()
                            .scaledToFit()
                            .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 40)
                    }
                }
            }

            if showCoachGuide {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { dismissGuide() }

                // 新手引导的终点：第一篇日记完成，放一轮礼花庆祝。
                if !reduceMotion {
                    CelebrationFireworksOverlay()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                shareCompleteCard
                    .padding(.horizontal, 34)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .onAppear {
            if activeCoachStep == .shareComplete {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    guard activeCoachStep == .shareComplete else { return }
                    presentCoachGuide()
                }
            }
        }
        .onChange(of: activeCoachStep) { _, newValue in
            if newValue == .shareComplete {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    guard activeCoachStep == .shareComplete else { return }
                    presentCoachGuide()
                }
            }
        }
    }

    private func watermarkToggle(_ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { isOn.wrappedValue },
            set: { newValue in
                isOn.wrappedValue = newValue
                UISelectionFeedbackGenerator().selectionChanged()
                if let rerender { renderedImage = rerender() }
            }
        )) {
            HStack(spacing: 10) {
                Image("BrandAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                Text("显示「贴纸日记」水印")
                    .font(DiaryFont.display(size: 15))
                    .foregroundStyle(ink)
            }
        }
        .tint(Color(red: 0.34, green: 0.24, blue: 0.18))
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: 50)
        .background(.white.opacity(0.70), in: Capsule())
    }

    private var shareCompleteCard: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(Color(red: 0.76, green: 0.45, blue: 0.18))
                .padding(.top, 6)

            VStack(spacing: 14) {
                Text(AppCoachStep.shareComplete.title)
                    .font(DiaryFont.display(size: 25, weight: .black, design: .default))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)

                Text(AppCoachStep.shareComplete.message)
                    .font(DiaryFont.display(size: 17, weight: .semibold, design: .default))
                    .foregroundStyle(Color(red: 0.48, green: 0.40, blue: 0.34))
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: dismissGuide) {
                Text(AppCoachStep.shareComplete.buttonTitle)
                    .font(DiaryFont.display(size: 18, design: .default))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(red: 0.25, green: 0.15, blue: 0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.horizontal, 30)
        .padding(.top, 40)
        .padding(.bottom, 30)
        .frame(maxWidth: 360)
        .background(Color(red: 0.99, green: 0.97, blue: 0.93), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 24, y: 14)
        .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .onTapGesture {}
    }

    private func presentCoachGuide() {
        guard !showCoachGuide else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            showCoachGuide = true
        }
    }

    private func closePreview() {
        onClose()
        if activeCoachStep == .shareComplete {
            onCoachCompleteClose()
        }
    }

    private func dismissGuide() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showCoachGuide = false
        }
        if activeCoachStep == .shareComplete {
            onCoachCompleteClose()
        }
    }
}

// MARK: - Celebration Fireworks

private struct CelebrationFireworkSpark {
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var color: Color
    var life: CGFloat = 1
    var size: CGFloat
}

/// 一次性礼花：几簇依次炸开后自然下落淡出，不拦截点击。
struct CelebrationFireworksOverlay: View {
    @State private var sparks: [CelebrationFireworkSpark] = []

    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private static let palette = [
        Color(red: 0.98, green: 0.68, blue: 0.20),
        Color(red: 0.95, green: 0.34, blue: 0.28),
        Color(red: 0.42, green: 0.62, blue: 0.96),
        Color(red: 0.52, green: 0.78, blue: 0.48),
        Color(red: 0.96, green: 0.78, blue: 0.34)
    ]

    var body: some View {
        GeometryReader { geo in
            Canvas { context, _ in
                for spark in sparks where spark.life > 0 {
                    let rect = CGRect(
                        x: spark.x - spark.size / 2,
                        y: spark.y - spark.size / 2,
                        width: spark.size,
                        height: spark.size
                    )
                    context.fill(
                        Path(ellipseIn: rect.insetBy(dx: -spark.size * 0.75, dy: -spark.size * 0.75)),
                        with: .color(spark.color.opacity(Double(spark.life) * 0.22))
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(spark.color.opacity(Double(spark.life)))
                    )
                }
            }
            .onAppear { scheduleBursts(in: geo.size) }
            .onReceive(timer) { _ in update() }
        }
    }

    private func scheduleBursts(in size: CGSize) {
        let points = [
            CGPoint(x: size.width * 0.50, y: size.height * 0.20),
            CGPoint(x: size.width * 0.22, y: size.height * 0.28),
            CGPoint(x: size.width * 0.78, y: size.height * 0.24),
            CGPoint(x: size.width * 0.30, y: size.height * 0.72),
            CGPoint(x: size.width * 0.72, y: size.height * 0.70),
            CGPoint(x: size.width * 0.52, y: size.height * 0.14)
        ]
        for (index, point) in points.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.24) {
                burst(at: point)
            }
        }
    }

    private func burst(at center: CGPoint) {
        let count = Int.random(in: 46...70)
        for index in 0..<count {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let speed = CGFloat.random(in: 1.6...5.6)
            sparks.append(CelebrationFireworkSpark(
                x: center.x,
                y: center.y,
                vx: cos(angle) * speed,
                vy: sin(angle) * speed,
                color: Self.palette[index % Self.palette.count],
                size: CGFloat.random(in: 2.2...5.4)
            ))
        }
    }

    private func update() {
        guard !sparks.isEmpty else { return }
        for index in sparks.indices {
            sparks[index].x += sparks[index].vx
            sparks[index].y += sparks[index].vy
            sparks[index].vy += 0.035
            sparks[index].vx *= 0.988
            sparks[index].vy *= 0.988
            sparks[index].life -= 0.010
        }
        sparks.removeAll { $0.life <= 0 }
    }
}

// MARK: - Share Sheet

struct ShareSheetView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack { DailyStickerView() }
}
