import AVFoundation
import CoreImage
import Network
import CoreImage.CIFilterBuiltins
import PhotosUI
import StoreKit
import SwiftUI
import UIKit
import Vision

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct DiaryScrollOffsetObserver: UIViewRepresentable {
    var onOffsetChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.attach(from: view)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onOffsetChange = onOffsetChange
        DispatchQueue.main.async {
            context.coordinator.attach(from: view)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOffsetChange: onOffsetChange)
    }

    final class Coordinator: NSObject {
        var onOffsetChange: (CGFloat) -> Void
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        init(onOffsetChange: @escaping (CGFloat) -> Void) {
            self.onOffsetChange = onOffsetChange
        }

        func attach(from view: UIView) {
            guard let scrollView = view.enclosingScrollView else { return }
            guard self.scrollView !== scrollView else {
                report(scrollView)
                return
            }

            self.scrollView = scrollView
            observation = scrollView.observe(\.contentOffset, options: [.new, .initial]) { [weak self, weak scrollView] _, _ in
                guard let scrollView else { return }
                self?.report(scrollView)
            }
            report(scrollView)
        }

        private func report(_ scrollView: UIScrollView) {
            let distanceFromTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            DispatchQueue.main.async { [weak self] in
                self?.onOffsetChange(distanceFromTop)
            }
        }
    }
}

private extension UIView {
    var enclosingScrollView: UIScrollView? {
        var view = superview
        while let current = view {
            if let scrollView = current as? UIScrollView {
                return scrollView
            }
            view = current.superview
        }
        return nil
    }
}

struct DailyStickerView: View {
    var onReplayOnboarding: () -> Void = {}

    @StateObject private var camera = StickerCameraModel()
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
    @State private var calendarRefreshRevision = 0
    @State private var cameraActivationToken = UUID()
    @State private var showCameraPermissionAlert = false
    @State private var showPhotoPermissionAlert = false
    @State private var activeAppCoachStep: AppCoachStep?
    @State private var isCoachWaitingForStickerCapture = false
    @State private var isCoachWaitingForDiaryAnimation = false
    @State private var shouldShowDiaryShareCoachAfterAchievement = false
    @AppStorage("hasSeenMainFlowCoachV1") private var hasSeenMainFlowCoach = false

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
                    recentStickers: StickerStore.shared.loadRecentStickers(count: 6),
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
                    onCoachSkip: finishMainFlowCoach,
                    onReplayOnboarding: restartMainFlowCoach,
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
                    onCaptureForDate: openCameraForDiaryDate,
                    onImportForDate: openStickerLibraryForDiaryDate,
                    onDateEntries: { date in
                        diaryEntriesForDate(date)
                    },
                    onRegenerate: regenerateDiaryForDate,
                    onClearDiary: clearDiaryForDate,
                    activeCoachStep: activeAppCoachStep,
                    onCoachAction: handleCoachAction,
                    onCoachSkip: finishMainFlowCoach,
                    onDiaryGenerationAnimationComplete: handleDiaryGenerationAnimationComplete
                ) {
                    showDiary = false
                    if diaryReturnToCalendar {
                        diaryReturnToCalendar = false
                        showCalendar = true
                    } else {
                        showHome = true
                    }
                    if pendingReviewAfterDiary {
                        pendingReviewAfterDiary = false
                        UserDefaults.standard.set(true, forKey: "hasRequestedReviewAfterDiary")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            if let scene = UIApplication.shared.connectedScenes
                                .compactMap({ $0 as? UIWindowScene }).first {
                                SKStoreReviewController.requestReview(in: scene)
                            }
                        }
                    }
                }
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
                }
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
                .zIndex(60)
            }
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.86), value: stickerImage != nil)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: isProcessing || isBatchLoading)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: showHome)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: unlockedAchievement?.id)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            startMainFlowCoachIfNeeded()
            let records = await Task.detached(priority: .utility) {
                SampleContentSeeder.seedIfNeeded()
                return DiaryRecordStore.shared.loadCalendarRecords()
            }.value
            calendarRecords = records
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

    private func finishMainFlowCoach() {
        hasSeenMainFlowCoach = true
        isCoachWaitingForStickerCapture = false
        isCoachWaitingForDiaryAnimation = false
        shouldShowDiaryShareCoachAfterAchievement = false
        withAnimation(.easeInOut(duration: 0.2)) {
            activeAppCoachStep = nil
        }
    }

    private func handleCoachAction(_ step: AppCoachStep) {
        switch step {
        case .homeAddSticker:
            openCameraForDateFromHome(homeSelectedDate)
        case .homeWriteDiary:
            openDiaryForDate(homeSelectedDate)
        case .diaryGenerate:
            regenerateDiaryForDate(diarySelectedDate)
        case .diaryShare:
            hasSeenMainFlowCoach = true
            withAnimation(.easeInOut(duration: 0.18)) {
                activeAppCoachStep = .shareComplete
            }
        case .shareComplete:
            finishMainFlowCoach()
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

    private func presentPendingAchievementAfterDiaryAnimation() -> Bool {
        guard let unlock = pendingAchievementUnlock,
              let unlockDate = pendingAchievementUnlockDate else { return false }
        guard showDiary else { return false }
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
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))

                    Text(isBatchLoading ? "把照片放进日记盒里" : "AI 正在把照片变成一枚小贴纸")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
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
                        errorMessage = "当前设备无法拍照，请尝试从相册选择图片。"
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
            .photosPicker(isPresented: $showPhotosPicker, selection: $selectedItems, maxSelectionCount: 20, matching: .images)
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
                errorMessage = "无法读取这些图片。"
                return
            }

            sourceImage = firstImage
            if failedCount > 0 {
                errorMessage = "有 \(failedCount) 张图片读取失败，其余图片会继续处理。"
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

    private func processNextQueuedImage() {
        guard !isProcessing,
              stickerImage == nil else { return }

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
                    errorMessage = "有 1 张图片读取失败，其余图片会继续处理。"
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
                errorMessage = "无法读取这张图片。"
                return
            }
            let processingImage = image.resizedForStickerProcessing(maxDimension: 1200)
            sourceImage = processingImage
            process(processingImage)
        } catch {
            errorMessage = "读取图片失败：\(error.localizedDescription)"
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
                    stickerRecognition = StickerRecognitionResult.dailyStickerMock
                    showRecognitionReview = true
                    isProcessing = false
                    isCameraMode = false
                    stopCameraSession()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "抠图失败：请换一张主体更清晰、背景更简单的照片。"
                    isProcessing = false
                    if shouldContinueQueue {
                        processNextQueuedImage()
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
        let orderedStickers = StickerStore.shared.loadOrderedStickersForDate(date)
        let previewStickers = orderedStickers.prefix(1).map { Optional($0.image) }
        let stickerCount = orderedStickers.count

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

    private func openCameraFromHome() {
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
        }
    }

    private func openCameraForDiaryDate(_ date: Date) {
        requestCameraAccess {
            openCameraForDiaryDateAfterPermission(date)
        }
    }

    private func openCameraForDiaryDateAfterPermission(_ date: Date) {
        clearStickerPreview()
        returnToDiaryAfterCapture = true
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
        diarySelectedDate = date
        activeBagDate = date
        diaryEntries = []
        diaryGenerationError = nil
        showStickerLibrary = false
        stickerLibraryTargetDate = nil
        showDiary = true
        let sources = images.enumerated().map { index, image in
            DiaryStickerSource(title: "贴纸 \(index + 1)", subtitle: "从贴纸库导入", image: image)
        }
        generateDiary(for: date, sources: sources, force: true)
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

    private func regenerateDiaryForDate(_ date: Date) {
        let storedSources = diaryStickerSourcesForDate(date)
        let sources: [DiaryStickerSource]
        if !storedSources.isEmpty {
            sources = storedSources
        } else {
            sources = diaryEntries.compactMap { entry in
                guard let image = entry.sticker else { return nil }
                return DiaryStickerSource(title: entry.title, subtitle: "当前日记贴纸", image: image)
            }
        }
        generateDiary(for: date, sources: sources, force: true)
    }

    private func diaryStickerSourcesForDate(_ date: Date) -> [DiaryStickerSource] {
        StickerStore.shared.loadOrderedStickersForDate(date)
            .map {
                DiaryStickerSource(title: $0.entry.title, subtitle: $0.entry.subtitle, image: $0.image)
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
        guard !sources.isEmpty else {
            isGeneratingDiary = false
            diaryGenerationError = "没有可用于生成的贴纸"
            return
        }
        guard force || !hasSavedDiaryRecord(for: date) else { return }
        if activeAppCoachStep == .diaryGenerate {
            isCoachWaitingForDiaryAnimation = true
            withAnimation(.easeInOut(duration: 0.18)) {
                activeAppCoachStep = nil
            }
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
                    diaryEntries = makeDiaryEntries(from: generated, sources: sources)
                    diaryGeneratedTitle = nil
                    saveDiaryEntriesRecord(for: date, entries: diaryEntries, title: nil)
                    checkAndPresentAchievement(date: date, representativeSticker: sources.first?.image)
                    ensureCoachFirstDiaryAchievementIfNeeded(date: date, representativeSticker: sources.first?.image)
                    isGeneratingDiary = false
                    diaryGenerationError = nil
                    diaryGenerationRevision += 1
                    // Request App Store review once, after 3rd diary generation
                    if !UserDefaults.standard.bool(forKey: "hasRequestedReviewAfterDiary") {
                        let count = UserDefaults.standard.integer(forKey: "diaryGenerationCount") + 1
                        UserDefaults.standard.set(count, forKey: "diaryGenerationCount")
                        if count >= 3 {
                            pendingReviewAfterDiary = true
                        }
                    }
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
            return "这次没写好，再试一次"
        case BailianDiaryError.emptyContent:
            return "这次没有写出来，再试一次"
        case BailianDiaryError.requestTimeout:
            return "生成等太久了，请重试"
        case BailianDiaryError.invalidImage:
            return "有张贴纸没处理好，换一张试试"
        case BailianDiaryError.missingAPIKey:
            return "还没有配置 AI 写作"
        default:
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    return "生成等太久了，请重试"
                case .notConnectedToInternet:
                    return "请允许网络访问后重试"
                case .networkConnectionLost:
                    return "网络不太稳定，请重试"
                default:
                    break
                }
            }
            return "生成遇到点小问题，再试一次"
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
        sourceImage = nil
        pendingBatchImages = []
        pendingBatchPhotoItems = []
        isCameraMode = false
        showDiary = false
        showCalendar = false
        showStickerLibrary = false
        stickerLibraryTargetDate = nil
        returnToDiaryAfterCapture = false
        stopCameraSession()

        if shouldReturnToDiary {
            openDiaryForDate(targetDate)
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

    private func saveDiaryRecord(for date: Date, from entries: [EditableDiaryEntry], title: String?) {
        let images: [UIImage?] = entries.map(\.sticker)
        let stickerSlots = entries.map { $0.sticker != nil }
        let hadStickerSlots = entries.map { $0.hadStickerSlot || $0.sticker != nil }
        let text = entries.map(\.text).joined(separator: "\n\n")
        let diaryTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = images.contains(where: { $0 != nil }) || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent else { return }

        let record = StickerCalendarRecord(
            date: date,
            stickers: images,
            diaryText: text,
            diaryTitle: diaryTitle?.isEmpty == false ? diaryTitle : nil,
            stickerSlots: stickerSlots,
            hadStickerSlots: hadStickerSlots
        )
        if let index = calendarRecords.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: record.date) }) {
            calendarRecords[index] = record
        } else {
            calendarRecords.append(record)
        }
        DiaryRecordStore.shared.saveDiaryText(
            text,
            for: date,
            title: diaryTitle,
            stickerSlots: stickerSlots,
            hadStickerSlots: hadStickerSlots
        )
    }

    private func saveDiaryEntriesRecord(for date: Date, entries: [DiaryEntry], title: String?) {
        let images: [UIImage?] = entries.map(\.sticker)
        let stickerSlots = entries.map { $0.sticker != nil }
        let hadStickerSlots = entries.map { $0.hadStickerSlot || $0.sticker != nil }
        let diaryTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = entries.map { entry in
            [entry.title, entry.text]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
        let hasContent = images.contains(where: { $0 != nil }) || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent else { return }

        let record = StickerCalendarRecord(
            date: date,
            stickers: images,
            diaryText: text,
            diaryTitle: diaryTitle?.isEmpty == false ? diaryTitle : nil,
            stickerSlots: stickerSlots,
            hadStickerSlots: hadStickerSlots
        )
        if let index = calendarRecords.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) {
            calendarRecords[index] = record
        } else {
            calendarRecords.append(record)
        }
        DiaryRecordStore.shared.saveDiaryText(
            text,
            for: date,
            title: diaryTitle,
            stickerSlots: stickerSlots,
            hadStickerSlots: hadStickerSlots
        )
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
            "把今天的一瞬间贴在这里，像给普通日子留下一个小小坐标。",
            "这张贴纸最像今天的心情，值得被认真收进日记里。",
            "后来又遇到一个新的片段，刚好适合写进今天的尾巴。",
            "这一页留给所有被看见、被保存、被记住的小事。"
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
                sticker: stickers.indices.contains(index) ? stickers[index] : nil,
                stickerSide: index % 2 == 0 ? .right : .left,
                hadStickerSlot: record.hadStickerSlots.indices.contains(index)
                    ? record.hadStickerSlots[index]
                    : stickers.indices.contains(index) && stickers[index] != nil
            )
        }
    }

    private func diaryStickers(for record: StickerCalendarRecord, entryCount: Int) -> [UIImage?] {
        let availableStickers = diaryStickerSourcesForDate(record.date).map(\.image)
        guard !record.stickerSlots.isEmpty else {
            if !record.stickers.isEmpty {
                return record.stickers
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
            let body = raw.hasPrefix("\u{3000}\u{3000}") ? raw : "\u{3000}\u{3000}" + raw

            result.append(DiaryEntry(
                title: "",
                text: body,
                sticker: sources[offset].image,
                stickerSide: result.count % 2 == 0 ? .right : .left,
                hadStickerSlot: true,
                inlineAnchor: inlineAnchor?.isEmpty == false ? inlineAnchor : nil
            ))
        }

        // Safety net: if the model returned fewer paragraphs than stickers,
        // append the leftover stickers so none of them get dropped.
        if result.count < sources.count {
            let leftoverFallbacks = [
                "\u{3000}\u{3000}这张贴纸也想被记住，就一起收进今天的日记里。",
                "\u{3000}\u{3000}还有这一张，留作今天的另一个小注脚。",
                "\u{3000}\u{3000}顺手把它也贴上来，让今天更完整一点。"
            ]
            for index in result.count..<sources.count {
                let fallback = leftoverFallbacks[(index - 1) % leftoverFallbacks.count]
                result.append(DiaryEntry(
                    title: "",
                    text: fallback,
                    sticker: sources[index].image,
                    stickerSide: result.count % 2 == 0 ? .right : .left,
                    hadStickerSlot: true
                ))
            }
        }

        if result.isEmpty, let firstSource = sources.first {
            let fallbackRaw = generated.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackText = fallbackRaw.isEmpty ? "\u{3000}\u{3000}今天收下了一张新的贴纸，先把这个小片段安静地放进日记里。" : (fallbackRaw.hasPrefix("\u{3000}\u{3000}") ? fallbackRaw : "\u{3000}\u{3000}" + fallbackRaw)
            result.append(DiaryEntry(
                title: "",
                text: fallbackText,
                sticker: firstSource.image,
                stickerSide: .right,
                hadStickerSlot: true
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

private struct HeaderIconButton: View {
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

private struct RecentStickerPreview: Identifiable {
    var id: String { entry.id }
    let entry: StickerEntry
    let image: UIImage
}

private struct StickerPagerPreview: View {
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
                        .font(.system(size: 15, weight: .bold, design: .rounded))
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return "收集于 \(formatter.string(from: entry.date))"
    }
}

private struct AchievementTier: Identifiable {
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

private struct AchievementStatus {
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

private struct AchievementUnlock: Identifiable, Equatable {
    let tier: AchievementTier
    let representativeSticker: UIImage?

    var id: Int { tier.threshold }

    static func == (lhs: AchievementUnlock, rhs: AchievementUnlock) -> Bool {
        lhs.id == rhs.id
    }
}

private enum AchievementSystem {
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
        title: "等待第一篇日记",
        condition: "本月生成第一篇日记。"
    )

    static let tiers: [AchievementTier] = [
        AchievementTier(threshold: 1, title: "第一篇日记", condition: "本月生成 1 篇日记。", imageName: "AchieveTier1"),
        AchievementTier(threshold: 3, title: "记录起步", condition: "本月生成 3 篇日记。", imageName: "AchieveTier2"),
        AchievementTier(threshold: 7, title: "一周记录者", condition: "本月生成 7 篇日记。", imageName: "AchieveTier3"),
        AchievementTier(threshold: 14, title: "半月采集家", condition: "本月生成 14 篇日记。", imageName: "AchieveTier4"),
        AchievementTier(threshold: 25, title: "生活记录家", condition: "本月生成 25 篇日记。", imageName: "AchieveTier5"),
        AchievementTier(threshold: 30, title: "满月收藏馆", condition: "本月生成 30 篇日记。", imageName: "AchieveTier6")
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

private struct AchievementMonthArchive: Identifiable {
    var id: Date { month }
    let month: Date
    let count: Int
}

private enum AppCoachTarget: Hashable {
    case homeAddSticker
    case homeWriteDiary
    case diaryGenerate
    case diaryShare
    case shareComplete
}

private enum AppCoachStep: String, Equatable {
    case homeAddSticker
    case homeWriteDiary
    case diaryGenerate
    case diaryShare
    case shareComplete

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
        }
    }

    var title: String {
        switch self {
        case .homeAddSticker:
            return "先添加一张贴纸"
        case .homeWriteDiary:
            return "用贴纸写日记"
        case .diaryGenerate:
            return "一键生成日记"
        case .diaryShare:
            return "分享这篇日记"
        case .shareComplete:
            return "第一篇日记完成啦"
        }
    }

    var message: String {
        switch self {
        case .homeAddSticker:
            return "点击这里拍照或选图，确认一张贴纸后回到首页。"
        case .homeWriteDiary:
            return "贴纸准备好了，接下来把它写进今天。"
        case .diaryGenerate:
            return "让 AI 根据今天的贴纸写一小段日记。"
        case .diaryShare:
            return "生成完成啦，可以先看看分享预览。"
        case .shareComplete:
            return "开始尽情探索贴纸日记吧。"
        }
    }

    var buttonTitle: String {
        switch self {
        case .homeAddSticker:
            return "添加贴纸"
        case .homeWriteDiary:
            return "写日记"
        case .diaryGenerate:
            return "生成日记"
        case .diaryShare:
            return "去分享"
        case .shareComplete:
            return "知道了"
        }
    }
}

private struct AppCoachFramePreferenceKey: PreferenceKey {
    static var defaultValue: [AppCoachTarget: CGRect] = [:]

    static func reduce(value: inout [AppCoachTarget: CGRect], nextValue: () -> [AppCoachTarget: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct AppCoachOriginPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero

    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

private struct AppCoachOriginReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: AppCoachOriginPreferenceKey.self,
                value: proxy.frame(in: .global).origin
            )
        }
    }
}

private extension View {
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

private struct AppCoachOverlay: View {
    let step: AppCoachStep
    let targetFrame: CGRect?
    let globalOrigin: CGPoint
    let onAction: () -> Void
    let onSkip: () -> Void

    private let ink = Color(red: 0.24, green: 0.17, blue: 0.13)

    var body: some View {
        GeometryReader { geo in
            let fallbackFrame = CGRect(
                x: geo.size.width * 0.16,
                y: geo.size.height * 0.28,
                width: geo.size.width * 0.68,
                height: 112
            )
            let frame = targetFrame.map(normalizedFrame) ?? fallbackFrame
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
            .ignoresSafeArea()
        }
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
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(ink)

            Text(step.message)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.50, green: 0.43, blue: 0.38))
                .lineSpacing(4)

            HStack {
                Button("跳过", action: onSkip)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.56, green: 0.50, blue: 0.46))

                Spacer()

                Button(action: onAction) {
                    Text(step.buttonTitle)
                        .font(.system(size: 15, weight: .black, design: .rounded))
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
        CGRect(
            x: frame.minX - globalOrigin.x,
            y: frame.minY - globalOrigin.y,
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
        }
    }
}

private struct AppCoachCutoutShape: Shape {
    let spotlight: CGRect
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(in: spotlight, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        return path
    }
}

private struct StickerHomeView: View {
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
    let onReplayOnboarding: () -> Void
    let onStickerPreview: ([(entry: StickerEntry, image: UIImage)], String) -> Void

    private let paper = Color(red: 0.97, green: 0.95, blue: 0.92)
    private let ink = Color(red: 0.22, green: 0.15, blue: 0.12)
    private let mutedInk = Color(red: 0.52, green: 0.46, blue: 0.42)
    private let cardBg = Color.white

    @State private var appeared = false
    @State private var selectedDateStickers: [(entry: StickerEntry, image: UIImage)] = []
    @State private var selectedDateCount: Int = 0
    @State private var showSettings = false
    @State private var showAchievements = false
    @State private var isReorderingHeroStickers = false
    @State private var draggingHeroStickerID: String?
    @State private var draggedHeroStickerOffset: CGSize = .zero
    @State private var heroReorderOriginalIndex: Int?
    @State private var heroReorderTargetIndex: Int?
    @State private var coachFrames: [AppCoachTarget: CGRect] = [:]
    @State private var coachGlobalOrigin: CGPoint = .zero

    private func refreshSelectedDate(for date: Date? = nil) {
        let target = date ?? selectedDate
        let stickers = StickerStore.shared.loadOrderedStickersForDate(target)
        selectedDateStickers = stickers
        selectedDateCount = stickers.count
    }

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
            let topPadding = max(geo.safeAreaInsets.top + (compact ? 8 : 12), compact ? 20 : 28)
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
            refreshSelectedDate()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82).delay(0.1)) {
                appeared = true
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(
                onReplayOnboarding: {
                    showSettings = false
                    onReplayOnboarding()
                }
            ) {
                showSettings = false
            }
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
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(self.mutedInk)

                Text(todayDateString)
                    .font(.system(size: 34, weight: .black, design: .rounded))
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
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date.now)
        let weekDates = homeWeekDates(centeredOn: selectedDate)
        let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

        return HStack(spacing: 6) {
            ForEach(weekDates, id: \.self) { date in
                let isToday = calendar.isDateInToday(date)
                let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
                let isFuture = calendar.startOfDay(for: date) > calendar.startOfDay(for: today)
                let hasRecord = records.contains(where: { record in
                    guard calendar.isDate(record.date, inSameDayAs: date) else { return false }
                    let text = record.diaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !text.isEmpty && text != "每日贴纸" && text != "今日日记"
                })
                let dayNum = calendar.component(.day, from: date)
                let weekdayIndex = calendar.component(.weekday, from: date) - 1

                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        selectedDate = date
                    }
                    refreshSelectedDate(for: date)
                } label: {
                    VStack(spacing: 4) {
                        Text(weekdaySymbols[weekdayIndex])
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(isFuture ? mutedInk.opacity(0.28) : (isSelected ? ink : mutedInk.opacity(0.6)))

                        Text("\(dayNum)")
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundStyle(isFuture ? mutedInk.opacity(0.28) : (isSelected ? ink : mutedInk.opacity(0.7)))

                        Circle()
                            .fill(hasRecord ? Color(red: 0.73, green: 0.43, blue: 0.17) : Color.clear)
                            .frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isSelected ? Color.white : Color.clear)
                            .shadow(color: isSelected ? .black.opacity(0.06) : .clear, radius: 6, y: 3)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isToday && !isSelected ? Color(red: 0.73, green: 0.43, blue: 0.17).opacity(0.4) : .clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isFuture)
                .accessibilityLabel(isToday ? "今天" : "\(dayNum)日")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(Color(red: 0.90, green: 0.87, blue: 0.83).opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 18)
    }

    private func homeWeekDates(centeredOn date: Date) -> [Date] {
        let calendar = Calendar.current
        return (-3...3).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: date)
        }
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

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(heroDateDisplay(date: selectedDate))
                            .font(.system(size: subtitleSize - 1, weight: .semibold, design: .rounded))
                            .foregroundStyle(self.mutedInk.opacity(0.7))
                            .lineLimit(1)

                        Text(hasStickers ? heroTitle(count: count) : heroEmptyTitle)
                            .font(.system(size: titleSize, weight: .bold, design: .rounded))
                            .foregroundStyle(self.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)

                        Text(heroSubtitle(hasStickers: hasStickers, count: count))
                            .font(.system(size: subtitleSize, weight: .semibold, design: .rounded))
                            .foregroundStyle(self.mutedInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)
                    }

                    Spacer(minLength: 8)

                    Button {
                        onCapture(selectedDate)
                    } label: {
                        Label(heroActionTitle(hasStickers: hasStickers), systemImage: heroActionIcon(hasStickers: hasStickers))
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .background(ink, in: Capsule())
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(heroActionTitle(hasStickers: hasStickers))
                    .appCoachAnchor(.homeAddSticker)
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

    private func heroActionTitle(hasStickers: Bool) -> String {
        return "添加贴纸"
    }

    private func heroActionIcon(hasStickers: Bool) -> String {
        return "plus"
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
        return "收集了 \(count) 张贴纸"
    }

    private var heroEmptyTitle: String {
        isSelectedToday ? "今天还没有贴纸" : "这天还没有贴纸"
    }

    private func heroSubtitle(hasStickers: Bool, count: Int) -> String {
        if hasStickers {
            if hasDiaryForSelectedDate {
                return "日记已写好 \u{2714}"
            }
            if count >= 2 {
                return isSelectedToday ? "拍得够多了，可以写日记啦" : "贴纸够多了，可以写日记啦"
            }
            return isSelectedToday ? "再拍几张就能写日记了" : "可以继续补充贴纸"
        }
        return isSelectedToday ? "记录一个小瞬间吧" : "可以为这天补充贴纸"
    }

    private func heroDateDisplay(date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "今天  M月d日 EEEE"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "昨天  M月d日 EEEE"
        } else {
            formatter.dateFormat = "M月d日 EEEE"
        }
        return formatter.string(from: date)
    }

    private func heroDateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return "昨天" }
        let day = calendar.component(.day, from: date)
        return "\(day)日"
    }

    // MARK: - Action Cards

    private func actionCardsRow(compact: Bool) -> some View {
        let status = achievementStatus

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            HomeActionCard(
                title: "写日记",
                subtitle: isSelectedToday ? "今天的日记" : "\(heroDateLabel(selectedDate))的日记",
                stickerImage: "StickerDiary",
                compact: compact,
                action: { onDiary(selectedDate) }
            )
            .appCoachAnchor(.homeWriteDiary)
            HomeActionCard(
                title: "日历",
                subtitle: monthString,
                stickerImage: "StickerCalendar",
                compact: compact,
                action: onCalendar
            )
            HomeActionCard(
                title: "成就",
                subtitle: status.diaryCount == 0 ? "待解锁" : status.currentTier.title,
                stickerImage: "StickerAchievement",
                compact: compact,
                action: {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        showAchievements = true
                    }
                }
            )
            HomeActionCard(
                title: "贴纸库",
                subtitle: "查看全部",
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
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundStyle(self.ink)

                        Text("\(status.diaryCount)/\(status.nextThreshold)")
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(Color(red: 0.73, green: 0.43, blue: 0.17))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Color.white.opacity(0.68), in: Capsule())
                    }

                    Text(status.diaryCount == 0 ? "写一篇日记，开启成就之旅" : status.currentTier.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
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
                    .font(.system(size: 20, weight: .bold, design: .rounded))
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
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(self.ink)
                        .lineLimit(1)

                    Text(diaryPreviewExcerpt(from: record.diaryText))
                        .font(.system(size: 13.5, weight: .medium, design: .rounded))
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
        case 0..<6: return "夜深了 🌙"
        case 6..<12: return "早上好 ☀️"
        case 12..<14: return "中午好 🌤"
        case 14..<18: return "下午好 🧋"
        default: return "晚上好 🌙"
        }
    }

    private var todayDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: .now)
    }

    private var monthString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月"
        return formatter.string(from: .now)
    }

    private func recentDateString(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private func diaryPreviewStickers(for date: Date) -> [UIImage] {
        StickerStore.shared.loadOrderedStickersForDate(date).prefix(5).map(\.image)
    }

    private func diaryPreviewTitle(for record: StickerCalendarRecord) -> String {
        let customTitle = record.diaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }
        return "\(recentDateString(record.date))的日记"
    }

    private func diaryPreviewExcerpt(from text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return "这一天还没有写下内容。" }

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

private struct HomeActionCard: View {
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
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(self.ink)

                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
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

private struct AchievementListPage: View {
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
                .font(.system(size: 32, weight: .black, design: .rounded))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .padding(.top, safeTop + 54)

            Text(status.diaryCount == 0 ? "写下第一篇日记，盖下第一枚成就章" : "本月已完成 \(status.diaryCount)/\(AchievementSystem.monthlyCap) 篇日记")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(mutedInk.opacity(0.72))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
    }

    private func closeButton(safeTop: CGFloat) -> some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(mutedInk)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.58), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.74), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭日记成就")

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
                        .font(.system(size: 16, weight: .black, design: .rounded))
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
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
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
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(ink)

                    Text("从第一次生成日记的月份开始")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
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
                    .font(.system(size: 15, weight: .black, design: .rounded))
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: date)
    }
}

private struct HomeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

private enum RecognitionKind {
    case dailySticker
    case movieTicket
}

private struct RecognitionMetric: Identifiable {
    let id = UUID()
    var label: String
    var value: String
}

private struct StickerRecognitionResult {
    let kind: RecognitionKind
    var title: String
    var subtitle: String
    var metrics: [RecognitionMetric]
    var noteTitle: String
    var noteBody: String

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

private struct StickerRecognitionReview: View {
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

private struct StickerDeleteTarget: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "trash.fill" : "trash")
                .font(.system(size: 22, weight: .bold))

            Text(isActive ? "松手删除" : "拖到这里删除")
                .font(.system(size: 16, weight: .bold, design: .rounded))
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

private struct CircularTrashDeleteTarget: View {
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

private struct StickerCloseButton: View {
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

private struct StickerPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let closeSystemImage: String
    let onClose: () -> Void
    @ViewBuilder var actions: () -> Actions

    private let ink = Color(red: 0.24, green: 0.17, blue: 0.14)
    private let mutedInk = Color(red: 0.54, green: 0.48, blue: 0.44)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text(title)
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(self.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 10)

                actions()

                Button(action: onClose) {
                    Image(systemName: closeSystemImage)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(self.mutedInk)
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.52), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(self.mutedInk.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
    }
}

private struct HeaderPillButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.white.opacity(0.74), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct DiaryEntry: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let sticker: UIImage?
    let stickerSide: StickerSide
    var hadStickerSlot: Bool = false
    var inlineAnchor: String? = nil

    enum StickerSide {
        case left
        case right
    }
}

private func joinedDiaryText(title: String, text: String) -> String {
    [title, text]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

private func normalizedDiaryTitleAndText(title: String, text: String) -> (title: String, text: String) {
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

private extension Array where Element == String {
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

private struct DiaryStickerSource {
    let title: String
    let subtitle: String
    let image: UIImage
}

private struct GeneratedDiary: Decodable {
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

private enum BailianDiaryError: LocalizedError {
    case missingAPIKey
    case invalidImage
    case invalidResponse
    case emptyContent
    case requestTimeout

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "还没有配置 API Key，请到设置里填写"
        case .invalidImage:
            return "图片处理失败，请重试"
        case .invalidResponse:
            return "AI 返回内容异常，请重试"
        case .emptyContent:
            return "AI 暂时没有灵感，请重试"
        case .requestTimeout:
            return "生成超时，请重试"
        }
    }
}

/// 用 NWPathMonitor 等待网络变为可用。首次请求触发系统授权弹窗后，
/// 用户点「允许」会让网络变为可用，从而可以立即自动重试。
private enum NetworkReachability {
    /// 等待网络可用，最多 timeout 秒。返回 true 表示已可用，false 表示超时。
    static func waitUntilAvailable(timeout: TimeInterval) async -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.stickerdiary.reachability")

        if monitor.currentPath.status == .satisfied {
            monitor.cancel()
            return true
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var finished = false
            func finish(_ value: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                monitor.cancel()
                continuation.resume(returning: value)
            }

            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied { finish(true) }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

private struct BailianDiaryGenerator {
    private let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
    private let model = "qwen-vl-plus"

    static let defaultSystemPrompt = "你是一位温柔、具体、有生活观察力的中文日记作者。你会根据用户当天拍的照片，识别物品和场景，并写成自然、不夸张、可直接放进日记本的文字。绝对不要在日记正文中出现「贴纸」这个词。"

    private static let customPromptKey = "custom_diary_system_prompt"

    static var currentSystemPrompt: String {
        get {
            UserDefaults.standard.string(forKey: customPromptKey) ?? defaultSystemPrompt
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == defaultSystemPrompt {
                UserDefaults.standard.removeObject(forKey: customPromptKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: customPromptKey)
            }
        }
    }

    static var isUsingCustomPrompt: Bool {
        UserDefaults.standard.string(forKey: customPromptKey) != nil
    }

    private var apiKey: String {
        let p1 = "sk-19"
        let p2 = "c9a42f"
        let p3 = "80bd46"
        let p4 = "27a10d"
        let p5 = "73dc48"
        let p6 = "a2b561"
        return p1 + p2 + p3 + p4 + p5 + p6
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

    private func performRequest(body: Data, retries: Int) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

    private func prompt(for date: Date, sources: [DiaryStickerSource]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy\u{5E74}M\u{6708}d\u{65E5} EEEE"
        let dateText = formatter.string(from: date)
        let visibleSources = Array(sources.prefix(8))
        let stickerCount = visibleSources.count
        let stickerList = visibleSources.enumerated().map { index, source in
            "\(index). \(source.title) / \(source.subtitle)"
        }.joined(separator: "\n")
        let q = "\u{22}"
        let jsonExample = "{\n  \(q)title\(q): \(q)\(q),\n  \(q)summary\(q): \(q)\u{4E00}\u{53E5}\u{8BDD}\u{603B}\u{7ED3}\(q),\n  \(q)entries\(q): [\n    { \(q)title\(q): \(q)\(q), \(q)text\(q): \(q)\u{65E5}\u{8BB0}\u{81EA}\u{7136}\u{6BB5}\u{FF0C}80\u{5230}160\u{4E2A}\u{4E2D}\u{6587}\u{5B57}\(q), \(q)stickerIndex\(q): 0, \(q)inlineAnchor\(q): \(q)\u{7269}\u{54C1}\u{77ED}\u{8BCD}\(q) }\n  ]\n}"
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
        lines.append("14. 只输出 JSON，不要 Markdown，不要解释。")
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

private struct BailianChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}

private struct StickerCalendarRecord: Identifiable {
    let id = UUID()
    var date: Date
    var stickers: [UIImage?]
    var diaryText: String
    var diaryTitle: String? = nil
    var stickerCountOverride: Int?
    var stickerSlots: [Bool] = []
    var hadStickerSlots: [Bool] = []

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
        copy.stickers = StickerStore.shared.loadOrderedStickersForDate(date).prefix(1).map { Optional($0.image) }
        return copy
    }
}

private func isRealDiaryText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed != "每日贴纸" && trimmed != "今日日记"
}

private struct DiaryStickerPilePreview: View {
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

private final class DiaryRecordStore {
    static let shared = DiaryRecordStore()

    private let userDefaultsKey = "dailyDiaryRecords"
    private let calendar = Calendar.current

    private init() {}

    func loadCalendarRecords() -> [StickerCalendarRecord] {
        loadEntries().map { entry in
            let date = Date(timeIntervalSince1970: entry.dayTimestamp)
            let stickers = StickerStore.shared.loadOrderedStickersForDate(date)
            return StickerCalendarRecord(
                date: date,
                stickers: stickers.prefix(1).map { Optional($0.image) },
                diaryText: entry.diaryText,
                diaryTitle: entry.diaryTitle,
                stickerCountOverride: stickers.count,
                stickerSlots: entry.stickerSlots ?? [],
                hadStickerSlots: entry.hadStickerSlots ?? []
            )
        }
    }

    func saveDiaryText(
        _ text: String,
        for date: Date,
        title: String? = nil,
        stickerSlots: [Bool] = [],
        hadStickerSlots: [Bool] = []
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
            hadStickerSlots: hadStickerSlots
        ))
        entries.sort { $0.dayTimestamp > $1.dayTimestamp }
        saveEntries(entries)
    }

    func deleteDiary(for date: Date) {
        let dayTimestamp = calendar.startOfDay(for: date).timeIntervalSince1970
        let entries = loadEntries().filter { $0.dayTimestamp != dayTimestamp }
        saveEntries(entries)
    }

    private func loadEntries() -> [PersistedDiaryRecord] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let entries = try? JSONDecoder().decode([PersistedDiaryRecord].self, from: data) else {
            return []
        }
        return entries
    }

    private func saveEntries(_ entries: [PersistedDiaryRecord]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}

private struct PersistedDiaryRecord: Codable {
    let dayTimestamp: TimeInterval
    let diaryText: String
    var diaryTitle: String?
    var stickerSlots: [Bool]?
    var hadStickerSlots: [Bool]?
}

private enum SampleContentSeeder {
    private static let seededKey = "stickerDiarySampleContentSeeded.v2"
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

    static func seedIfNeeded() {
        let defaults = UserDefaults.standard
        removeLegacySampleDiaryIfNeeded()
        removeLegacySampleStickersIfNeeded()
        guard !defaults.bool(forKey: seededKey) else { return }

        defaults.set(true, forKey: seededKey)
        defaults.removeObject(forKey: sampleDateKey)
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

private struct StickerCalendarPage: View {
    let records: [StickerCalendarRecord]
    let currentStickers: [UIImage]
    let refreshToken: Int
    let onClose: () -> Void
    var onOpenDiary: ((Date) -> Void)?
    @State private var selectedDate: Date?
    @State private var cachedDisplayRecords: [StickerCalendarRecord] = []
    @State private var cachedDisplayStickers: [UIImage] = []
    @State private var cachedRecordsByDay: [Date: StickerCalendarRecord] = [:]
    @State private var cachedStickerCount = 0
    @State private var displayedMonth: Date = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 7)
    private let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

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
        .onChange(of: refreshToken) { _, _ in
            rebuildCalendarCache()
        }
        .gesture(monthSwipeGesture)
    }

    private var compactHeader: some View {
        StickerPageHeader(
            title: "日历",
            subtitle: monthTitle,
            closeSystemImage: "xmark",
            onClose: onClose
        ) {
            HStack(spacing: 8) {
                HeaderIconButton(systemImage: "chevron.left", accessibilityLabel: "上个月") {
                    shiftDisplayedMonth(by: -1)
                }
                HeaderIconButton(systemImage: "chevron.right", accessibilityLabel: "下个月") {
                    shiftDisplayedMonth(by: 1)
                }
                if !isDisplayedMonthCurrent {
                    HeaderIconButton(systemImage: "calendar", accessibilityLabel: "回到本月") {
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
                ForEach(weekdaySymbols, id: \.self) { weekday in
                    Text(weekday)
                        .font(.system(size: 15, weight: .black, design: .monospaced))
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
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.38, blue: 0.35))

                Spacer()

                Text("\(cachedDisplayRecords.count) 天")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.54, green: 0.48, blue: 0.44))
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(stickerCount)")
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .foregroundStyle(Color(red: 0.19, green: 0.13, blue: 0.11))
                Text("张贴纸")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.38, blue: 0.35))

                Spacer()
            }

            if !cachedDisplayStickers.isEmpty {
                CalendarStickerScatter(images: cachedDisplayStickers)
                    .frame(height: 88)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: displayedMonth)
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

private struct CalendarStickerScatter: View {
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

private struct CalendarDayCell: View {
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


private struct AchievementUnlockOverlay: View {
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

private struct AchievementPopup: View {
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
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .foregroundStyle(Color(red: 0.70, green: 0.42, blue: 0.18))

                    Text(title)
                        .font(.system(size: 27, weight: .black, design: .rounded))
                        .foregroundStyle(Color(red: 0.20, green: 0.13, blue: 0.11))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Text(subtitle)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.49, green: 0.44, blue: 0.40))
                        .lineLimit(2)
                }
            }

            Button(action: onDone) {
                Text("知道了")
                    .font(.system(size: 18, weight: .black, design: .rounded))
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

private struct PaperTextureBackground: View {
    var body: some View {
        AchievementPaperBackground()
    }
}

private struct AchievementPaperBackground: View {
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
private enum PaperTextureCache {
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

private struct PaperTextureCanvas: View {
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

private enum StickerOnboardingPage: Int, CaseIterable, Identifiable {
    case collect
    case write

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .collect: return "拍一张"
        case .write: return "贴进日记"
        }
    }

    var subtitle: String {
        switch self {
        case .collect:
            return "拍下今天的小物件，自动变成一张贴纸。"
        case .write:
            return "用贴纸和文字，收藏难忘的瞬间。"
        }
    }
}

private struct StickerOnboardingPageView: View {
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
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)

                Text(page.subtitle)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
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

private struct CollectStickerOnboardingArt: View {
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

private struct OnboardingCutoutTransition: View {
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

private struct OnboardingCutoutStickerWindow: View {
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

private struct OnboardingStickerWindow: View {
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

private struct OnboardingFloatingSticker: View {
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

private struct WriteDiaryOnboardingArt: View {
    let animate: Bool

    private struct Paragraph {
        let text: String
        let stickerName: String?
        let stickerOnRight: Bool
    }

    private static let paragraphs: [Paragraph] = [
        Paragraph(text: "下午在回家的路上，看到一只橘色的小奶猫。它趴在路边，眼睛睁得大大的，好奇地看着来往的行人。", stickerName: "SampleCat", stickerOnRight: true),
        Paragraph(text: "到家后小狗已经在门口等了好久，一看到我就摇着尾巴扑过来，毛茸茸的脑袋蹭个不停。", stickerName: "SampleDog", stickerOnRight: false),
    ]

    private static let fullLength: Int = paragraphs.map(\.text.count).reduce(0, +)

    @State private var visibleChars = 0
    @State private var typingTimer: Timer?

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
                    .font(.system(size: 18, weight: .black, design: .rounded))
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
        .onAppear { startTyping() }
        .onDisappear { typingTimer?.invalidate() }
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
        let showSticker = charsForThis > 6

        return HStack(alignment: .top, spacing: 8) {
            if para.stickerOnRight {
                textView(visibleText)
                if showSticker, let name = para.stickerName {
                    stickerImage(name, wiggleOffset: index)
                }
            } else {
                if showSticker, let name = para.stickerName {
                    stickerImage(name, wiggleOffset: index)
                }
                textView(visibleText)
            }
        }
    }

    private func textView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
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
}


private struct StickerLibraryPage: View {
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
                .font(.system(size: 32, weight: .black, design: .rounded))
                .foregroundStyle(self.ink)
                .frame(maxWidth: .infinity)
                .padding(.top, safeTop + 54)

            Text(headerSubtitle)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
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
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(self.mutedInk)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.58), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.74), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭贴纸库")
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
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(self.ink)

                Text("拍照生成后，会自动出现在这里。")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
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
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(self.ink)

                    Spacer()

                    Text("\(group.items.count) 张")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
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
                        .font(.system(size: 17, weight: .black, design: .rounded))
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
            return selectedStickerIDs.isEmpty ? "选择贴纸生成这天的日记" : "已选择 \(selectedStickerIDs.count) 张"
        }
        return "\(count) 张贴纸 · 按日期归档"
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
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }
}

private struct StickerLibraryDayGroup: Identifiable {
    var id: Date { date }
    let date: Date
    let items: [StickerLibraryItem]
}

private struct StickerLibraryItem: Identifiable {
    var id: String { entry.id }
    let entry: StickerEntry
    let image: UIImage
}

private struct StickerLibraryTimelinePaper: View {
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
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(ink)
                    .padding(.leading, 10)

                Spacer()

                Text("\(group.items.count) 张")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
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
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }
}

private struct SingleLibraryPaperTexture: View {
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

private struct StickerLibraryPaper: View {
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

private struct LibraryPaperPattern: View {
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

private struct StickerLibraryCell: View {
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

private struct DiaryBookView: View {
    @Environment(\.scenePhase) private var scenePhase

    let entries: [DiaryEntry]
    let records: [StickerCalendarRecord]
    @Binding var selectedDate: Date
    let isGenerating: Bool
    let generationError: String?
    let generationRevision: Int
    var generatedTitle: String? = nil
    let onArchive: (Date, [EditableDiaryEntry], String?) -> Void
    let onCaptureForDate: (Date) -> Void
    let onImportForDate: (Date) -> Void
    let onDateEntries: (Date) -> [DiaryEntry]
    let onRegenerate: (Date) -> Void
    let onClearDiary: (Date) -> Void
    let activeCoachStep: AppCoachStep?
    let onCoachAction: (AppCoachStep) -> Void
    let onCoachSkip: () -> Void
    let onDiaryGenerationAnimationComplete: () -> Void
    let onClose: () -> Void
    @State private var visibleCharacters = 0
    @State private var visibleStickerCount = 0
    @State private var paperStyle: DiaryPaperStyle = .lined
    @State private var layoutStyle: DiaryLayoutStyle = .classic
    @State private var editableEntries: [EditableDiaryEntry] = []
    @State private var isWriting = false
    @State private var isStickerLayoutMode = false
    @State private var isArchivingPage = false
    @State private var isPageArchived = false
    @State private var currentWritingIndex = 0
    @State private var isDiaryDeleteTargetVisible = false
    @State private var isDiaryDeleteTargetActive = false
    @State private var richCombinedText: String = ""
    @State private var richInlineInsertions: [InlineStickerInsertion] = []
    @State private var richCursorPosition: Int = 0
    @State private var richFloatingStickers: [FloatingSticker] = [] // kept for rich layout reset
    @State private var richContentInitialized = false
    @State private var richContentRevision = 0
    @State private var isEditorFocused = false
    @State private var diaryScrollDistanceFromTop: CGFloat = 10_000
    @State private var lastEditorModeSwitchAt = Date.distantPast
    @State private var didSwitchEditorModeDuringDrag = false
    @State private var didStartDiaryDrag = false
    @State private var canExitFullscreenFromTop = false
    @State private var pendingFullscreenTopExitUnlock = false
    @State private var dragStartedWithFullscreenExitArmed = false
    @State private var diaryCustomTitle: String = ""
    @State private var originalHadSticker: Set<Int> = []
    @State private var dateStickerImages: [UIImage] = []
    @State private var activeGenerationStickerIndex: Int?
    @State private var generationAnimationStopToken = 0
    @State private var lastAnimatedGenerationRevision = 0
    @State private var saveState: DiarySaveState = .idle
    @State private var autosaveTask: Task<Void, Never>?
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
    @State private var diaryScrollResetToken = 0
    @State private var coachFrames: [AppCoachTarget: CGRect] = [:]
    @State private var coachGlobalOrigin: CGPoint = .zero

    private let calendar = Calendar.current

    private var currentEntries: [DiaryEntry] {
        entries
    }

    private var allAvailableStickers: [UIImage] {
        let entryStickers = editableEntries.compactMap(\.sticker)
        return entryStickers.isEmpty ? dateStickerImages : entryStickers
    }

    private var fullText: String {
        currentEntries.map { diaryBlockText(for: $0) }.joined(separator: "\n\n")
    }

    private var hasEditableDiaryContent: Bool {
        editableEntries.contains { entry in
            !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entry.sticker != nil
        }
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
                accessibilityLabel: "分享日记"
            ) {
                performDiaryShareAction()
            }
            .disabled(!hasEditableDiaryContent || isWriting || isGenerating)
            .opacity(hasEditableDiaryContent && !isWriting && !isGenerating ? 1 : 0.4)
            .appCoachAnchor(.diaryShare)

            HeaderIconButton(
                systemImage: "wand.and.stars",
                accessibilityLabel: "AI 重写日记"
            ) {
                dismissKeyboard()
                requestRegeneration()
            }
            .disabled(!canUseToolbarMagicWand)
            .opacity(canUseToolbarMagicWand ? 1 : 0.4)

            HeaderIconButton(
                systemImage: "trash",
                accessibilityLabel: "删除日记"
            ) {
                dismissKeyboard()
                showClearDiaryConfirm = true
            }
            .disabled(!hasDiaryToClear || isWriting || isGenerating)
            .opacity(hasDiaryToClear && !isWriting && !isGenerating ? 1 : 0.4)
        }
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
                    ZStack(alignment: .top) {
                        // Full header – always in view tree, hidden when editing
                        VStack(spacing: 0) {
                            StickerPageHeader(
                                title: diaryHeaderTitle,
                                subtitle: diaryHeaderSubtitle,
                                closeSystemImage: "xmark",
                                onClose: closeDiaryPage
                            ) {
                                diaryHeaderActions
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 54)
                            .padding(.bottom, 14)

                            diaryWeekStrip
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)

                            diaryStyleControls
                                .padding(.horizontal, 20)
                                .padding(.bottom, 8)

                            if isRichLayoutMode, !isWriting, !isArchivingPage {
                                richStickerToolbar(mode: .inline)
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 8)
                            }

                        }
                        .opacity(isEditorFocused ? 0 : 1)
                        .frame(height: isEditorFocused ? 0 : nil)
                        .clipped()
                        .allowsHitTesting(!isEditorFocused)

                        VStack(spacing: 8) {
                            diaryStyleControls
                                .padding(.horizontal, 20)

                            if isRichLayoutMode, !isWriting, !isArchivingPage {
                                richStickerToolbar(mode: .inline)
                                    .padding(.horizontal, 20)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                        .opacity(isEditorFocused ? 1 : 0)
                        .frame(height: isEditorFocused ? nil : 0)
                        .clipped()
                        .allowsHitTesting(isEditorFocused)
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            DiaryScrollOffsetObserver(onOffsetChange: handleDiaryScrollOffsetChange)
                            .frame(width: 1, height: 1)
                            .opacity(0)
                            .allowsHitTesting(false)
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
                                                    isEditable: !isWriting && !isArchivingPage,
                                                    isStickerEditable: isStickerLayoutMode && !isWriting && !isArchivingPage,
                                                    availableStickers: allAvailableStickers,
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
                                                        }
                                                        if !focused {
                                                            saveImmediately()
                                                        }
                                                    },
                                                    onTextChange: {
                                                        scheduleAutosave()
                                                    },
                                                    hadSticker: originalHadSticker.contains(index),
                                                    autoFocus: index == 0 && autoFocusBlankEntry,
                                                    dateStickerImages: dateStickerImages,
                                                    onAddSticker: {
                                                        onCaptureForDate(selectedDate)
                                                    },
                                                    onStickerTap: {
                                                        previewDiarySticker(at: index)
                                                    },
                                                    onDeleteEntry: {
                                                        deleteDiaryEntry(at: index)
                                                    },
                                                    canDeleteEntry: editableEntries.count > 1
                                                )
                                                .id(diaryRowID(for: index))
                                            }

                                            // Add new paragraph button
                                            if !editableEntries.isEmpty && !isWriting && !isArchivingPage {
                                                HStack(spacing: 8) {
                                                    Image(systemName: "plus")
                                                        .font(.system(size: 14, weight: .bold))
                                                    Text("添加段落")
                                                        .font(.system(size: 14, weight: .bold, design: .rounded))
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
                                .background(alignment: .top) {
                                    DiaryPaper(style: paperStyle)
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
                        .coordinateSpace(name: "diaryScroll")
                        .id(diaryScrollViewID)
                        .scrollDisabled(isEmptyDiaryState)
                        .simultaneousGesture(diaryScrollDragGesture)
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
                            .font(.title3.weight(.bold))
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
        .sheet(isPresented: $showDiaryShareSheet) {
            ShareSheetView(items: diaryShareItems)
        }
        .onDisappear {
            autosaveTask?.cancel()
            saveStateResetTask?.cancel()
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
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.52, green: 0.46, blue: 0.40))

            VStack(spacing: 12) {
                emptyDiaryStartButton

                Button {
                    onCaptureForDate(selectedDate)
                } label: {
                    Label("添加贴纸", systemImage: "plus")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))
                        .padding(.horizontal, 20)
                        .frame(height: 42)
                        .background(.white.opacity(0.72), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color(red: 0.34, green: 0.24, blue: 0.18).opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isArchivingPage || isPageArchived)
            }
        }
    }

    private var emptyDiaryStartButton: some View {
        Button {
            if dateStickerImages.isEmpty {
                startBlankPage()
            } else {
                attemptRegeneration(confirmIfNeeded: false)
            }
        } label: {
            Label(dateStickerImages.isEmpty ? "开始写日记" : "AI写日记", systemImage: dateStickerImages.isEmpty ? "pencil.line" : "wand.and.stars")
                .font(.system(size: 17, weight: .black, design: .rounded))
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

    private var diaryStyleControls: some View {
        let inactive = Color(red: 0.62, green: 0.58, blue: 0.54)
        let pillBg = Color(red: 0.34, green: 0.24, blue: 0.18)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
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
                            .frame(width: 32, height: 28)
                            .background(selected ? pillBg : Color.clear, in: Capsule())
                    }
                }

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 3)

                ForEach(DiaryLayoutStyle.allCases) { style in
                    let selected = layoutStyle == style
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            if style == .inlineSticker {
                                syncRichContentFromEditableEntries(resetInsertions: true)
                            }
                            layoutStyle = style
                        }
                    } label: {
                        Image(systemName: style.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? .white : inactive)
                            .frame(width: 32, height: 28)
                            .background(selected ? pillBg : Color.clear, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(red: 0.92, green: 0.89, blue: 0.85), in: Capsule())
        .disabled(isArchivingPage || isPageArchived)
    }

    private var diaryGenerationStatus: some View {
        Group {
            if isGenerating {
                diaryGenerationWaitingView
            } else {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.34, green: 0.24, blue: 0.18).opacity(0.10))
                            .frame(width: 38, height: 38)

                        Image(systemName: needsNetworkPermissionRecovery ? "wifi.exclamationmark" : "arrow.clockwise")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(needsNetworkPermissionRecovery ? "需要网络权限" : "生成没有完成")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .foregroundStyle(Color(red: 0.30, green: 0.22, blue: 0.17))

                        Text(needsNetworkPermissionRecovery ? "允许无线数据后，再让 AI 继续写日记" : (generationError ?? "生成遇到问题，请重试"))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.58, green: 0.50, blue: 0.44))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    Button {
                        attemptRegeneration(confirmIfNeeded: false)
                    } label: {
                        Text(needsNetworkPermissionRecovery ? "去设置" : "重试")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(Color(red: 0.34, green: 0.24, blue: 0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
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
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.18))

                Text("AI 正在根据你的贴纸生成今天的日记")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
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
        HStack(spacing: 6) {
            ForEach(weekDates(centeredOn: selectedDate), id: \.self) { date in
                let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
                let isToday = calendar.isDateInToday(date)
                let isFuture = calendar.startOfDay(for: date) > calendar.startOfDay(for: Date.now)
                let hasStickers = records.contains(where: { record in
                    guard calendar.isDate(record.date, inSameDayAs: date) else { return false }
                    let text = record.diaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !text.isEmpty && text != "每日贴纸" && text != "今日日记"
                })

                Button {
                    switchToDate(date)
                } label: {
                    VStack(spacing: 4) {
                        Text(chineseWeekday(for: date))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(isFuture ? Color(red: 0.60, green: 0.56, blue: 0.52).opacity(0.35) : (isSelected ? Color(red: 0.34, green: 0.24, blue: 0.18) : Color(red: 0.60, green: 0.56, blue: 0.52)))

                        Text("\(calendar.component(.day, from: date))")
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundStyle(isFuture ? Color(red: 0.50, green: 0.46, blue: 0.42).opacity(0.35) : (isSelected ? Color(red: 0.34, green: 0.24, blue: 0.18) : Color(red: 0.50, green: 0.46, blue: 0.42)))

                        // Dot indicator for dates with stickers
                        Circle()
                            .fill(hasStickers ? Color(red: 0.73, green: 0.43, blue: 0.17) : Color.clear)
                            .frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isSelected ? Color.white : Color.clear)
                            .shadow(color: isSelected ? .black.opacity(0.06) : .clear, radius: 6, y: 3)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isToday && !isSelected ? Color(red: 0.73, green: 0.43, blue: 0.17).opacity(0.4) : .clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isFuture)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(Color(red: 0.90, green: 0.87, blue: 0.83).opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var diaryHeaderTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: selectedDate)
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
        switch saveState {
        case .saving:
            return "保存中"
        case .saved:
            return "已保存"
        case .idle:
            return hasEditableDiaryContent ? "已保存" : "未保存"
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
                    title: "日记贴纸",
                    subtitle: "当前日记使用中",
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

    private var diaryShareItems: [Any] {
        [diaryShareImage()]
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

    private func diaryShareImage() -> UIImage {
        let paperWidth: CGFloat = 820
        let minPaperHeight: CGFloat = 1296
        let contentInset: CGFloat = 76
        let contentX = contentInset
        let contentWidth = paperWidth - contentInset * 2
        let headerTop: CGFloat = 84
        let footerHeight: CGFloat = 54
        let contentBottomPadding: CGFloat = 50

        let titleAttributes = shareTitleAttributes
        let titleHeight = shareTextHeight(displayedDiaryTitle, width: contentWidth, attributes: titleAttributes)
        let headerHeight = titleHeight + 54

        let contentHeight: CGFloat
        switch layoutStyle {
        case .classic:
            contentHeight = shareClassicContentHeight(width: contentWidth)
        case .timeline:
            contentHeight = shareTimelineContentHeight(width: contentWidth)
        case .inlineSticker:
            contentHeight = shareInlineContentHeight(width: contentWidth)
        }

        let paperHeight = max(
            minPaperHeight,
            headerTop + headerHeight + contentHeight + footerHeight + contentBottomPadding
        )
        let size = CGSize(width: paperWidth, height: paperHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size)
            sharePaperBackgroundColor.setFill()
            context.fill(rect)

            let cardRect = rect
            let cardPath = UIBezierPath(rect: cardRect)
            sharePaperBackgroundColor.setFill()
            cardPath.fill()
            context.cgContext.saveGState()
            cardPath.addClip()
            drawSharePaperPattern(in: cardRect, context: context.cgContext)
            context.cgContext.restoreGState()

            sharePaperStrokeColor.setStroke()
            cardPath.lineWidth = 3
            cardPath.stroke()

            var y: CGFloat = headerTop
            let title = NSAttributedString(string: displayedDiaryTitle, attributes: titleAttributes)
            title.draw(in: CGRect(x: contentX, y: y, width: contentWidth, height: ceil(titleHeight)))
            y += ceil(titleHeight) + 54

            switch layoutStyle {
            case .classic:
                drawShareClassicContent(at: CGPoint(x: contentX, y: y), width: contentWidth)
            case .timeline:
                drawShareTimelineContent(at: CGPoint(x: contentX, y: y), width: contentWidth)
            case .inlineSticker:
                drawShareInlineContent(at: CGPoint(x: contentX, y: y), width: contentWidth)
            }

            let footer = NSAttributedString(string: "贴纸日记", attributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor(red: 0.72, green: 0.55, blue: 0.38, alpha: 0.52)
            ])
            footer.draw(in: CGRect(x: contentX, y: cardRect.maxY - 64, width: contentWidth, height: 30))
        }
    }

    private var shareTitleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: 54, weight: .black),
            .foregroundColor: UIColor(red: 0.22, green: 0.15, blue: 0.12, alpha: 1)
        ]
    }

    private var shareSubtitleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: 25, weight: .semibold),
            .foregroundColor: UIColor(red: 0.54, green: 0.48, blue: 0.42, alpha: 1)
        ]
    }

    private var shareBodyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 14
        paragraph.paragraphSpacing = 18
        return [
            .font: UIFont.systemFont(ofSize: 32, weight: .regular),
            .foregroundColor: UIColor(red: 0.28, green: 0.21, blue: 0.17, alpha: 1),
            .paragraphStyle: paragraph
        ]
    }

    private var sharePaperBackgroundColor: UIColor {
        switch paperStyle {
        case .lined:
            UIColor(red: 1.0, green: 0.97, blue: 0.90, alpha: 1)
        case .grid:
            UIColor(red: 0.98, green: 0.96, blue: 0.91, alpha: 1)
        case .dotted:
            UIColor(red: 0.96, green: 0.98, blue: 0.95, alpha: 1)
        }
    }

    private var sharePaperAccentColor: UIColor {
        switch paperStyle {
        case .lined:
            UIColor(red: 0.80, green: 0.35, blue: 0.24, alpha: 1)
        case .grid:
            UIColor(red: 0.45, green: 0.58, blue: 0.66, alpha: 1)
        case .dotted:
            UIColor(red: 0.42, green: 0.54, blue: 0.40, alpha: 1)
        }
    }

    private var sharePaperStrokeColor: UIColor {
        UIColor(red: 0.72, green: 0.55, blue: 0.38, alpha: 0.18)
    }

    private func shareTextHeight(_ text: String, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes)
        return ceil(attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
    }

    private func drawSharePaperPattern(in rect: CGRect, context: CGContext) {
        let accent = sharePaperAccentColor
        switch paperStyle {
        case .lined:
            context.setStrokeColor(UIColor(red: 0.66, green: 0.50, blue: 0.36, alpha: 0.16).cgColor)
            context.setLineWidth(1)
            var y = rect.minY + 46
            while y < rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y.rounded() + 0.5))
                context.addLine(to: CGPoint(x: rect.maxX, y: y.rounded() + 0.5))
                y += 28
            }
            context.strokePath()
            context.setFillColor(sharePaperAccentColor.withAlphaComponent(0.18).cgColor)
            context.fill(CGRect(x: rect.minX + 48, y: rect.minY, width: 2, height: rect.height))
        case .grid:
            context.setLineWidth(1)
            context.setStrokeColor(accent.withAlphaComponent(0.12).cgColor)
            var y = rect.minY + 23
            while y < rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y.rounded() + 0.5))
                context.addLine(to: CGPoint(x: rect.maxX, y: y.rounded() + 0.5))
                y += 23
            }
            context.strokePath()
            context.setStrokeColor(accent.withAlphaComponent(0.10).cgColor)
            var x = rect.minX + 23
            while x < rect.maxX {
                context.move(to: CGPoint(x: x.rounded() + 0.5, y: rect.minY))
                context.addLine(to: CGPoint(x: x.rounded() + 0.5, y: rect.maxY))
                x += 23
            }
            context.strokePath()
        case .dotted:
            context.setFillColor(accent.withAlphaComponent(0.16).cgColor)
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
    }

    private func shareClassicContentHeight(width: CGFloat) -> CGFloat {
        editableEntries.reduce(CGFloat.zero) { total, entry in
            let textWidth = entry.sticker == nil ? width : width - 206
            let textHeight = shareTextHeight(shareShareableText(for: entry), width: textWidth, attributes: shareBodyAttributes)
            return total + max(176, textHeight) + 48
        }
    }

    private func drawShareClassicContent(at origin: CGPoint, width: CGFloat) {
        var y = origin.y
        for (index, entry) in editableEntries.enumerated() {
            let text = shareShareableText(for: entry)
            let hasSticker = entry.sticker != nil
            let stickerSize: CGFloat = 170
            let gap: CGFloat = 36
            let textWidth = hasSticker ? width - stickerSize - gap : width
            let textHeight = shareTextHeight(text, width: textWidth, attributes: shareBodyAttributes)
            let rowHeight = max(176, textHeight)
            let stickerOnLeft = entry.stickerSide == .left
            let textX = origin.x + (hasSticker && stickerOnLeft ? stickerSize + gap : 0)

            if let sticker = entry.sticker {
                let stickerX = origin.x + (stickerOnLeft ? 0 : width - stickerSize)
                drawStickerAspectFit(
                    sticker,
                    in: CGRect(x: stickerX, y: y + max(0, (rowHeight - stickerSize) / 2), width: stickerSize, height: stickerSize)
                )
            }

            NSAttributedString(string: text, attributes: shareBodyAttributes).draw(
                with: CGRect(x: textX, y: y, width: textWidth, height: textHeight + 8),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            y += rowHeight + (index == editableEntries.indices.last ? 0 : 48)
        }
    }

    private func shareTimelineContentHeight(width: CGFloat) -> CGFloat {
        let textWidth = width - 46
        return editableEntries.reduce(CGFloat.zero) { total, entry in
            let textHeight = shareTextHeight(shareShareableText(for: entry), width: textWidth, attributes: shareBodyAttributes)
            let stickerHeight: CGFloat = entry.sticker == nil ? 0 : 166
            return total + textHeight + stickerHeight + 58
        }
    }

    private func drawShareTimelineContent(at origin: CGPoint, width: CGFloat) {
        var y = origin.y
        let lineX = origin.x + 10
        let textX = origin.x + 46
        let textWidth = width - 46
        let accent = UIColor(red: 0.74, green: 0.38, blue: 0.25, alpha: 1)

        for entry in editableEntries {
            let text = shareShareableText(for: entry)
            let textHeight = shareTextHeight(text, width: textWidth, attributes: shareBodyAttributes)
            accent.withAlphaComponent(0.55).setFill()
            UIBezierPath(ovalIn: CGRect(x: lineX - 5.5, y: y + 10, width: 11, height: 11)).fill()
            accent.withAlphaComponent(0.18).setFill()
            UIBezierPath(rect: CGRect(x: lineX - 1, y: y + 30, width: 2, height: max(88, textHeight + (entry.sticker == nil ? 10 : 134)))).fill()

            NSAttributedString(string: text, attributes: shareBodyAttributes).draw(
                with: CGRect(x: textX, y: y, width: textWidth, height: textHeight + 8),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            y += textHeight + 20

            if let sticker = entry.sticker {
                let stickerSize: CGFloat = 162
                drawStickerAspectFit(sticker, in: CGRect(x: origin.x + width - stickerSize, y: y, width: stickerSize, height: stickerSize))
                y += stickerSize + 38
            } else {
                y += 32
            }
        }
    }

    private func shareInlineContentHeight(width: CGFloat) -> CGFloat {
        let attributed = shareInlineAttributedText()
        return ceil(attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height) + 18
    }

    private func drawShareInlineContent(at origin: CGPoint, width: CGFloat) {
        let attributed = shareInlineAttributedText()
        let height = shareInlineContentHeight(width: width)
        attributed.draw(
            with: CGRect(x: origin.x, y: origin.y, width: width, height: height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
    }

    private func shareInlineAttributedText() -> NSAttributedString {
        let text = (richCombinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? editableEntries.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            : richCombinedText)
        let result = NSMutableAttributedString(string: text.isEmpty ? "今天还没有写下文字。" : text, attributes: shareBodyAttributes)
        let font = UIFont.systemFont(ofSize: 32, weight: .regular)
        let stickerSize = font.lineHeight * 2.05
        let insertions = richInlineInsertions.isEmpty ? defaultInlineStickerInsertions() : richInlineInsertions

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
        return text.isEmpty ? "今天还没有写下文字。" : text
    }

    private func drawStickerAspectFit(_ image: UIImage, in rect: CGRect) {
        image.draw(in: aspectFitRect(for: image, in: rect))
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

    private func closeWithoutSavingPartialGeneration() {
        autosaveTask?.cancel()
        isWriting = false
        activeGenerationStickerIndex = nil
        generationAnimationStopToken += 1
        dismissKeyboard()
        onClose()
    }

    private func shareDiary() {
        dismissKeyboard()
        saveImmediately()
        diarySharePreviewImage = diaryShareImage()
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
            if dateStickerImages.isEmpty {
                startBlankPage()
            } else {
                attemptRegeneration(confirmIfNeeded: false)
            }
        case .diaryShare:
            performDiaryShareAction()
        default:
            onCoachAction(step)
        }
    }

    private func isDiaryCoachStep(_ step: AppCoachStep) -> Bool {
        step == .diaryGenerate || step == .diaryShare
    }

    // MARK: - Rich Layout (inline / wrap) combined content

    private func initializeRichContent() {
        guard !richContentInitialized else { return }
        syncRichContentFromEditableEntries(resetInsertions: true)
    }

    private func rebuildRichContentIfNeeded() {
        richContentInitialized = false
        richCombinedText = ""
        richInlineInsertions = []
        richFloatingStickers = []
        richCursorPosition = 0
        richContentRevision += 1

        if isRichLayoutMode {
            initializeRichContent()
        }
    }

    private func combinedEditableDiaryText() -> String {
        editableEntries
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func syncRichContentFromEditableEntries(resetInsertions: Bool = false) {
        let nextText = combinedEditableDiaryText()
        let previousText = richCombinedText
        let previousInsertions = richInlineInsertions

        richCombinedText = nextText
        richContentInitialized = true
        if resetInsertions || richInlineInsertions.isEmpty {
            richInlineInsertions = defaultInlineStickerInsertions()
        }

        if previousText != richCombinedText || previousInsertions != richInlineInsertions {
            richContentRevision += 1
        }
    }

    private func defaultInlineStickerInsertions() -> [InlineStickerInsertion] {
        var insertions: [InlineStickerInsertion] = []
        var cursor = 0

        for entry in editableEntries {
            let block = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !block.isEmpty else { continue }

            if let sticker = entry.sticker {
                let insertionIndex = inlineStickerInsertionIndex(for: entry, in: block, blockStart: cursor)
                insertions.append(InlineStickerInsertion(image: sticker, characterIndex: insertionIndex))
            }

            cursor += block.count + 2
        }

        return Array(insertions.prefix(8))
    }

    private func inlineStickerInsertionIndex(for entry: EditableDiaryEntry, in block: String, blockStart: Int) -> Int {
        if let anchor = entry.inlineAnchor?.trimmingCharacters(in: .whitespacesAndNewlines),
           !anchor.isEmpty,
           let range = block.range(of: anchor) {
            let offset = block.distance(from: block.startIndex, to: range.upperBound)
            return min(blockStart + offset, blockStart + block.count)
        }

        let titleLength = block.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first?.count ?? 0
        return min(blockStart + titleLength + 1, blockStart + block.count)
    }

    @ViewBuilder
    private var richLayoutContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            InlineStickerTextView(
                text: $richCombinedText,
                insertions: $richInlineInsertions,
                cursorPosition: $richCursorPosition,
                revision: richContentRevision,
                isEditable: !isWriting && !isArchivingPage,
                fontSize: 17,
                lineSpacing: 8,
                onFocusChange: { focused in
                    if focused {
                        enterEditorFullscreen()
                    }
                    if !focused {
                        saveImmediately()
                    }
                },
                onTextChange: {
                    if editableEntries.isEmpty {
                        editableEntries = [EditableDiaryEntry.blank()]
                    }
                    editableEntries[0].text = richCombinedText
                    scheduleAutosave()
                }
            )
            .id(richTextViewIdentity)
            .frame(minHeight: 400, maxHeight: .infinity, alignment: .top)

        }
        .onAppear {
            if isWriting {
                syncRichContentFromEditableEntries(resetInsertions: true)
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
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(mutedInk)
                .padding(.leading, 4)

                ForEach(Array(stickers.prefix(8).enumerated()), id: \.offset) { _, image in
                    Button {
                        richInlineInsertions.append(
                            InlineStickerInsertion(image: image, characterIndex: richCursorPosition)
                        )
                    } label: {
                        Image(uiImage: image)
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

    private func weekDates(centeredOn date: Date) -> [Date] {
        (-3...3).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: date)
        }
    }

    private func chineseWeekday(for date: Date) -> String {
        let symbols = ["日", "一", "二", "三", "四", "五", "六"]
        return symbols[calendar.component(.weekday, from: date) - 1]
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

        dateStickerImages = StickerStore.shared.loadOrderedStickersForDate(selectedDate).map(\.image)
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
        if confirmIfNeeded, shouldConfirmRegeneration {
            showRegenerateConfirm = true
        } else {
            beginRegeneration()
        }
    }

    private var needsNetworkPermissionRecovery: Bool {
        generationError == "请允许网络访问后重试"
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

    private func enterEditorFullscreen() {
        guard !isEditorFocused else { return }
        lastEditorModeSwitchAt = Date()
        canExitFullscreenFromTop = false
        pendingFullscreenTopExitUnlock = false
        dragStartedWithFullscreenExitArmed = false
        withAnimation(.easeOut(duration: 0.12)) {
            isEditorFocused = true
        }
    }

    private func exitEditorFullscreen() {
        guard isEditorFocused else { return }
        lastEditorModeSwitchAt = Date()
        canExitFullscreenFromTop = false
        pendingFullscreenTopExitUnlock = false
        dragStartedWithFullscreenExitArmed = false
        withAnimation(.easeInOut(duration: 0.18)) {
            isEditorFocused = false
        }
    }

    private var canRespondToScrollModeChange: Bool {
        Date().timeIntervalSince(lastEditorModeSwitchAt) > 0.32
    }

    private var diaryScrollDragGesture: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .local)
            .onChanged { value in
                handleDiaryScrollDragChanged(value.translation)
            }
            .onEnded { value in
                handleDiaryScrollDragEnded(value.translation)
            }
    }

    private func handleDiaryScrollDragChanged(_ translation: CGSize) {
        if !didStartDiaryDrag {
            didStartDiaryDrag = true
            dragStartedWithFullscreenExitArmed = isEditorFocused
                && canExitFullscreenFromTop
                && isDiaryScrollAtTop(diaryScrollDistanceFromTop)
        }
        handleDiaryScrollDrag(translation)
    }

    private func handleDiaryScrollOffsetChange(_ distanceFromTop: CGFloat) {
        diaryScrollDistanceFromTop = distanceFromTop
        updateFullscreenTopExitGate(with: distanceFromTop)
    }

    private func handleDiaryScrollDragEnded(_ translation: CGSize) {
        didSwitchEditorModeDuringDrag = false
        didStartDiaryDrag = false
        dragStartedWithFullscreenExitArmed = false
        updateFullscreenTopExitGate(with: diaryScrollDistanceFromTop, endedTranslation: translation)
    }

    private func scrollDuringWritingIfNeeded(_ visibleCount: Int, proxy: ScrollViewProxy) {
        guard isWriting, visibleCount % 8 == 0 || visibleCount == fullText.count else { return }
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

    private func handleDiaryScrollDrag(_ translation: CGSize) {
        guard !isGenerating, !isWriting, !isArchivingPage else { return }
        guard !isEmptyDiaryState else { return }
        guard !didSwitchEditorModeDuringDrag else { return }
        guard canRespondToScrollModeChange else { return }
        guard abs(translation.height) > abs(translation.width) else { return }

        if isEditorFocused, translation.height < -12 {
            canExitFullscreenFromTop = false
            pendingFullscreenTopExitUnlock = false
            dragStartedWithFullscreenExitArmed = false
        }

        if translation.height > 42, isEditorFocused, dragStartedWithFullscreenExitArmed {
            didSwitchEditorModeDuringDrag = true
            exitEditorFullscreen()
        } else if translation.height < -42, !isEditorFocused {
            didSwitchEditorModeDuringDrag = true
            enterEditorFullscreen()
        }
    }

    private func updateFullscreenTopExitGate(with offset: CGFloat) {
        guard isEditorFocused else {
            canExitFullscreenFromTop = false
            pendingFullscreenTopExitUnlock = false
            dragStartedWithFullscreenExitArmed = false
            return
        }

        if !isDiaryScrollAtTop(offset) {
            canExitFullscreenFromTop = false
        } else if pendingFullscreenTopExitUnlock, !didStartDiaryDrag {
            canExitFullscreenFromTop = true
            pendingFullscreenTopExitUnlock = false
        }
    }

    private func updateFullscreenTopExitGate(with offset: CGFloat, endedTranslation: CGSize) {
        guard isEditorFocused else {
            canExitFullscreenFromTop = false
            pendingFullscreenTopExitUnlock = false
            dragStartedWithFullscreenExitArmed = false
            return
        }

        let endedAtTop = isDiaryScrollAtTop(offset)
        let pulledDown = endedTranslation.height > 18 && abs(endedTranslation.height) > abs(endedTranslation.width)

        if pulledDown, endedAtTop {
            canExitFullscreenFromTop = true
            pendingFullscreenTopExitUnlock = false
        } else {
            canExitFullscreenFromTop = false
            pendingFullscreenTopExitUnlock = pulledDown
        }
    }

    private func isDiaryScrollAtTop(_ offset: CGFloat) -> Bool {
        offset <= 8
    }

    private func beginRegeneration() {
        autosaveTask?.cancel()
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
        saveStateResetTask?.cancel()
        onClearDiary(selectedDate)
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
        richFloatingStickers = []
        richContentInitialized = false
        dateStickerImages = StickerStore.shared.loadOrderedStickersForDate(selectedDate).map(\.image)
        diaryScrollDistanceFromTop = 0
        diaryScrollResetToken += 1
    }

    private func scheduleAutosave() {
        guard !isWriting, !isGenerating, hasEditableDiaryContent else { return }
        autosaveTask?.cancel()
        saveStateResetTask?.cancel()
        saveState = .saving

        let date = selectedDate
        let snapshot = editableEntries
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                guard calendar.isDate(date, inSameDayAs: selectedDate), hasEditableDiaryContent else { return }
                onArchive(date, snapshot, displayedDiaryTitle)
                markSaved()
            }
        }
    }

    private func saveImmediately() {
        autosaveTask?.cancel()
        guard hasEditableDiaryContent else { return }
        onArchive(selectedDate, editableEntries, displayedDiaryTitle)
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
            syncRichContentFromEditableEntries(resetInsertions: true)
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
            editableEntries[index].sticker = nil
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
        visibleCharacters = 0
        visibleStickerCount = 0
        currentWritingIndex = 0
        activeGenerationStickerIndex = nil
        generationAnimationStopToken += 1
        editableEntries = []
        originalHadSticker = Set(source.indices.filter { source[$0].hadStickerSlot || source[$0].sticker != nil })
        if isRichLayoutMode {
            richCombinedText = ""
            richInlineInsertions = []
            richContentInitialized = true
        }

        dateStickerImages = StickerStore.shared.loadOrderedStickersForDate(selectedDate).map(\.image)

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
                        syncRichContentFromEditableEntries(resetInsertions: true)
                    }
                }

                for characterCount in 0...blockText.count {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await MainActor.run {
                        guard isWriting, editableEntries.indices.contains(entryIndex) else { return }
                        editableEntries[entryIndex].text = String(blockText.prefix(characterCount))
                        visibleCharacters = writtenCharacters + characterCount
                        if isRichLayoutMode {
                            syncRichContentFromEditableEntries(resetInsertions: false)
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
                        syncRichContentFromEditableEntries(resetInsertions: true)
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
                    syncRichContentFromEditableEntries(resetInsertions: true)
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
        dateStickerImages = StickerStore.shared.loadOrderedStickersForDate(selectedDate).map(\.image)
        if isRichLayoutMode {
            syncRichContentFromEditableEntries(resetInsertions: true)
        } else {
            richContentInitialized = false
        }
    }

    private func updateEditableText(to visibleCount: Int) {
        let source = currentEntries
        var activeIndex = 0
        for index in source.indices {
            let previous = source.prefix(index).map { diaryBlockText(for: $0) }.joined(separator: "\n\n")
            let consumed = previous.isEmpty ? 0 : previous.count + 2
            let available = max(0, visibleCount - consumed)
            let block = diaryBlockText(for: source[index])
            if editableEntries.indices.contains(index) {
                editableEntries[index].text = String(block.prefix(available))
            }
            if available > 0 {
                activeIndex = index
            }
        }
        currentWritingIndex = min(activeIndex, max(source.count - 1, 0))
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

private enum DiarySaveState {
    case idle
    case saving
    case saved
}

private struct EditableDiaryEntry: Identifiable {
    let id: UUID
    var text: String
    var sticker: UIImage?
    let stickerSide: DiaryEntry.StickerSide
    var hadStickerSlot: Bool = false
    var inlineAnchor: String?
    var stickerOffset: CGSize = .zero
    var stickerScale: CGFloat = 1

    init(
        id: UUID,
        text: String,
        sticker: UIImage?,
        stickerSide: DiaryEntry.StickerSide,
        hadStickerSlot: Bool = false,
        inlineAnchor: String? = nil
    ) {
        self.id = id
        self.text = text
        self.sticker = sticker
        self.stickerSide = stickerSide
        self.hadStickerSlot = hadStickerSlot
        self.inlineAnchor = inlineAnchor
    }

    init(_ entry: DiaryEntry) {
        id = entry.id
        text = joinedDiaryText(title: entry.title, text: entry.text)
        sticker = entry.sticker
        stickerSide = entry.stickerSide
        hadStickerSlot = entry.hadStickerSlot || entry.sticker != nil
        inlineAnchor = entry.inlineAnchor
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

private struct DiaryPaper: View {
    let style: DiaryPaperStyle

    var body: some View {
        let paperShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        paperShape
            .fill(style.background)
            .overlay {
                style.pattern
                    .clipShape(paperShape)
            }
            .overlay(alignment: .leading) {
                if style.showsMarginLine {
                    Rectangle()
                        .fill(style.accent.opacity(0.18))
                        .frame(width: 2)
                        .padding(.leading, 48)
                }
            }
            .clipShape(paperShape)
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}

private struct DiaryEntryRow: View {
    @Binding var entry: EditableDiaryEntry
    let showSticker: Bool
    let layoutStyle: DiaryLayoutStyle
    let index: Int
    let isGenerating: Bool
    let animationStopToken: Int
    let isEditable: Bool
    let isStickerEditable: Bool
    let availableStickers: [UIImage]
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
    var dateStickerImages: [UIImage] = []
    var onAddSticker: (() -> Void)? = nil
    var onStickerTap: (() -> Void)? = nil
    var onDeleteEntry: (() -> Void)? = nil
    var canDeleteEntry: Bool = false
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
            case .timeline:
                timelineLayout
            case .inlineSticker:
                inlineStickerLayout
            }
        }
        .alert("删除贴纸", isPresented: $showStickerDeleteConfirm) {
            Button("删除", role: .destructive) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    entry.hadStickerSlot = true
                    entry.sticker = nil
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

    private var inlineStickerLayout: some View {
        // TODO: InlineStickerEntryView was removed; restore or replace
        EmptyView()
            .frame(minHeight: 200)
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
            autoFocus: autoFocus,
            onFocusChange: onFocusChange,
            onTextChange: onTextChange
        )
            .frame(minHeight: autoFocus ? max(layoutStyle.editorMinHeight, 320) : layoutStyle.editorMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                if isEditable && entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("写下这一刻的感受…")
                        .font(.system(size: layoutStyle.textSize, weight: .semibold, design: .serif))
                        .foregroundStyle(Color(red: 0.31, green: 0.24, blue: 0.20).opacity(0.28))
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
        } else if entry.sticker == nil && (hadSticker || entry.hadStickerSlot) {
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
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(ink)
                .padding(.top, 20)

            if dateStickerImages.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(mutedInk.opacity(0.5))
                    Text("暂无可用贴纸")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(mutedInk)
                    Text("拍照生成贴纸后，就可以添加到日记中")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
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
                                .font(.system(size: 15, weight: .black, design: .rounded))
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
                        ForEach(Array(dateStickerImages.enumerated()), id: \.offset) { _, image in
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    entry.sticker = image
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

private struct DiaryTextView: UIViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    var autoFocus: Bool = false
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
        context.coordinator.applyStyle(to: textView, fontSize: fontSize, lineSpacing: lineSpacing)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyStyle(to: textView, fontSize: fontSize, lineSpacing: lineSpacing)

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

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: DiaryTextView
        var isUserEditing = false
        private var styleKey: String?

        init(parent: DiaryTextView) {
            self.parent = parent
        }

        func applyStyle(to textView: UITextView, fontSize: CGFloat, lineSpacing: CGFloat) {
            let nextKey = "\(fontSize)-\(lineSpacing)"
            guard styleKey != nextKey else { return }
            styleKey = nextKey

            let baseDescriptor = UIFont.systemFont(ofSize: fontSize, weight: .semibold).fontDescriptor
            let descriptor = baseDescriptor.withDesign(.serif) ?? baseDescriptor
            let font = UIFont(descriptor: descriptor, size: fontSize)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = lineSpacing
            let textColor = UIColor(red: 0.31, green: 0.24, blue: 0.20, alpha: 1)

            textView.font = font
            textView.textColor = textColor
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
        }

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            guard parent.isEditable else { return false }
            parent.onFocusChange?(true)
            return true
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isUserEditing = true
            parent.onFocusChange?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isUserEditing = false
            parent.onFocusChange?(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.onTextChange?()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView,
                  parent.isEditable, !textView.isFirstResponder else { return }
            textView.becomeFirstResponder()
        }
    }
}

// MARK: - Shared Rich Diary Helpers

private let richDiaryDemoText = """
今天路过那家常去的奶茶店，阳光刚好洒在门口的玻璃窗上，暖暖的光线把整条街都染成了蜂蜜色。\
点了一杯桂花乌龙，等待的时候翻了翻手机相册，发现上个月拍的那张晚霞照片特别好看，\
橘红色渐变到淡紫色，像一幅水彩画。

店里放着轻柔的爵士乐，隔壁桌的小朋友正在认真画画，\
蜡笔在纸上沙沙作响。我突然觉得这样平凡的午后特别珍贵，\
值得被认真记录下来。每一个看似普通的瞬间，其实都在编织着我们独一无二的生活纹理。

走出店门的时候看到路边开了一丛野花，\
淡黄色的小花瓣在微风中轻轻摇摆，像是在跟路过的人打招呼。\
摘了一小朵夹在日记本里，作为今天这一页的小书签。\
希望翻开这页的时候，还能闻到午后阳光的味道。
"""

private struct InlineStickerInsertion: Identifiable, Equatable {
    let id: UUID
    let image: UIImage
    let characterIndex: Int

    init(image: UIImage, characterIndex: Int, id: UUID = UUID()) {
        self.id = id
        self.image = image
        self.characterIndex = characterIndex
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.characterIndex == rhs.characterIndex
    }
}

// MARK: - Mode 2: Simple Wrap Sticker Overlay (legacy, kept for reference)

private struct SimpleWrapStickerOverlay: View {
    @Binding var text: String
    @Binding var floatingStickers: [FloatingSticker]
    let isEditable: Bool
    let fontSize: CGFloat
    let lineSpacing: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                .font(.system(size: fontSize, weight: .semibold, design: .serif))
                .foregroundStyle(Color(red: 0.31, green: 0.24, blue: 0.20))
                .lineSpacing(lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

            ForEach(floatingStickers) { sticker in
                Image(uiImage: sticker.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: sticker.size.width, height: sticker.size.height)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
                    .position(x: sticker.relativePosition.x * 300, y: sticker.relativePosition.y * 400)
            }
        }
    }
}

private struct FloatingSticker: Identifiable {
    let id = UUID()
    let image: UIImage
    var relativePosition: CGPoint
    var size: CGSize = CGSize(width: 110, height: 110)
}

private func richDiaryFont(size: CGFloat) -> UIFont {
    let baseDescriptor = UIFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor
    let descriptor = baseDescriptor.withDesign(.serif) ?? baseDescriptor
    return UIFont(descriptor: descriptor, size: size)
}

private func richDiaryBaseAttrs(fontSize: CGFloat, lineSpacing: CGFloat) -> [NSAttributedString.Key: Any] {
    let font = richDiaryFont(size: fontSize)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = lineSpacing
    return [
        .font: font,
        .foregroundColor: UIColor(red: 0.31, green: 0.24, blue: 0.20, alpha: 1),
        .paragraphStyle: paragraphStyle
    ]
}

private func resizeStickerImage(_ image: UIImage, to size: CGSize) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { _ in
        image.draw(in: aspectFitRect(for: image, in: CGRect(origin: .zero, size: size)))
    }
}

private func aspectFitRect(for image: UIImage, in rect: CGRect) -> CGRect {
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

private struct InlineStickerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var insertions: [InlineStickerInsertion]
    @Binding var cursorPosition: Int
    let revision: Int
    let isEditable: Bool
    let fontSize: CGFloat
    let lineSpacing: CGFloat
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
        context.coordinator.applyContent(to: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyContent(to: textView)
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
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
        /// Prevents programmatic selectedRange changes from overwriting the cursor binding.
        private var isProgrammaticChange = false
        private var appliedText = ""
        private var appliedCount = -1
        private var appliedRevision = -1

        init(parent: InlineStickerTextView) { self.parent = parent }

        func applyContent(to textView: UITextView) {
            // Allow rebuild when insertions changed (toolbar adds sticker while
            // the text view may already have resigned first responder).
            if isUserEditing && parent.text == appliedText && parent.insertions.count == appliedCount && parent.revision == appliedRevision { return }
            let needsRebuild = parent.text != appliedText || parent.insertions.count != appliedCount || parent.revision != appliedRevision
            guard needsRebuild, textView.markedTextRange == nil else { return }
            appliedText = parent.text
            appliedCount = parent.insertions.count
            appliedRevision = parent.revision

            let font = richDiaryFont(size: parent.fontSize)
            let baseAttrs = richDiaryBaseAttrs(fontSize: parent.fontSize, lineSpacing: parent.lineSpacing)
            let result = NSMutableAttributedString(string: parent.text, attributes: baseAttrs)

            // Count how many stickers sit at or before the plain-text cursor
            // so we can offset the attributed-string cursor properly.
            let cursorPos = parent.cursorPosition
            var stickersBefore = 0

            let sorted = parent.insertions.sorted { $0.characterIndex > $1.characterIndex }
            for insertion in sorted {
                let attachment = NSTextAttachment()
                let stickerSize = font.lineHeight * 1.6
                attachment.image = resizeStickerImage(insertion.image, to: CGSize(width: stickerSize, height: stickerSize))
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
            guard parent.isEditable else { return false }
            parent.onFocusChange?(true)
            return true
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isUserEditing = true
            parent.onFocusChange?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            // Capture cursor position one last time before marking editing done
            syncCursorPosition(from: textView)
            isUserEditing = false
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
            let attributed = textView.attributedText ?? NSAttributedString()
            var plain = ""
            var ins: [InlineStickerInsertion] = []
            var idx = 0
            var stickerOrdinal = 0

            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
                if let att = attrs[.attachment] as? NSTextAttachment, let img = att.image {
                    // Preserve existing ID if possible, to avoid unnecessary SwiftUI re-renders
                    let existingID = stickerOrdinal < parent.insertions.count ? parent.insertions[stickerOrdinal].id : UUID()
                    ins.append(InlineStickerInsertion(image: img, characterIndex: idx, id: existingID))
                    stickerOrdinal += 1
                } else {
                    let sub = (attributed.string as NSString).substring(with: range)
                    plain += sub
                    idx += sub.count
                }
            }
            appliedText = plain
            appliedCount = ins.count
            appliedRevision = parent.revision
            parent.text = plain
            parent.insertions = ins
            parent.onTextChange?()

            // Update cursor position after text change
            syncCursorPosition(from: textView)
        }
    }
}

// MARK: - Mode 1: Inline Sticker Entry View

private struct InlineStickerEntryView: View {
    @Binding var entry: EditableDiaryEntry
    let isEditable: Bool
    let availableStickers: [UIImage]
    @State private var insertions: [InlineStickerInsertion] = []
    @State private var hasAutoInserted = false
    @State private var cursorPosition: Int = 0

    private let mutedInk = Color(red: 0.52, green: 0.46, blue: 0.42)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InlineStickerTextView(
                text: $entry.text,
                insertions: $insertions,
                cursorPosition: $cursorPosition,
                revision: 0,
                isEditable: isEditable,
                fontSize: 17,
                lineSpacing: 8
            )
            .frame(minHeight: 200)

            if isEditable {
                inlineToolbar
                    .padding(.top, 10)
            }
        }
        .onAppear {
            ensureDemoContent()
        }
    }

    private func ensureDemoContent() {
        if entry.text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
            entry.text = richDiaryDemoText
        }
        if !hasAutoInserted, let sticker = entry.sticker {
            hasAutoInserted = true
            let len = entry.text.count
            insertions = [
                InlineStickerInsertion(image: sticker, characterIndex: len / 3),
                InlineStickerInsertion(image: sticker, characterIndex: len * 2 / 3)
            ]
        }
    }

    private var inlineToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Label("点击插入文中", systemImage: "text.insert")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(mutedInk)
                    .padding(.leading, 4)

                ForEach(Array(availableStickers.prefix(8).enumerated()), id: \.offset) { _, image in
                    Button {
                        insertInline(image)
                    } label: {
                        Image(uiImage: image)
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

    private func insertInline(_ image: UIImage) {
        insertions.append(InlineStickerInsertion(image: image, characterIndex: cursorPosition))
    }
}

// MARK: - Mode 2: Integrated Wrap Sticker Content View
// Stickers are UIImageView subviews of the UITextView itself,
// so exclusion paths and sticker positions share the same coordinate system.

private struct WrapStickerContentView: UIViewRepresentable {
    @Binding var text: String
    @Binding var floatingStickers: [FloatingSticker]
    let isEditable: Bool
    let fontSize: CGFloat
    let lineSpacing: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textView.tintColor = UIColor(red: 0.48, green: 0.25, blue: 0.17, alpha: 1)
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        context.coordinator.textView = textView
        context.coordinator.applyText()
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.textView = textView
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        context.coordinator.applyText()
        // Only update sticker layout when not actively editing to avoid cursor jitter
        if !context.coordinator.isUserEditing {
            DispatchQueue.main.async {
                context.coordinator.updateStickerViews()
                context.coordinator.updateExclusionPaths()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        context.coordinator.updateStickerPositionsForWidth(width)
        context.coordinator.updateExclusionPaths()
        let measured = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(ceil(measured.height), 300))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: WrapStickerContentView
        weak var textView: UITextView?
        var isUserEditing = false
        private var appliedText = ""
        private var stickerImageViews: [UUID: UIImageView] = [:]
        private var lastWidth: CGFloat = 0

        init(parent: WrapStickerContentView) { self.parent = parent }

        func applyText() {
            guard let textView = textView else { return }
            guard !isUserEditing else { return }
            guard parent.text != appliedText, textView.markedTextRange == nil else { return }
            appliedText = parent.text
            let baseAttrs = richDiaryBaseAttrs(fontSize: parent.fontSize, lineSpacing: parent.lineSpacing)
            UIView.performWithoutAnimation {
                let sel = textView.selectedRange
                textView.attributedText = NSAttributedString(string: parent.text, attributes: baseAttrs)
                textView.selectedRange = NSRange(location: min(sel.location, parent.text.count), length: 0)
            }
            textView.typingAttributes = baseAttrs
        }

        /// Convert relative position to absolute frame in textView coordinates
        private func stickerFrame(for sticker: FloatingSticker, in width: CGFloat) -> CGRect {
            let insets = textView?.textContainerInset ?? UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
            let contentWidth = width - insets.left - insets.right
            let x: CGFloat
            if sticker.relativePosition.x > 0.5 {
                // Right-aligned: sticker near right margin
                x = insets.left + contentWidth - sticker.size.width - 4
            } else {
                // Left-aligned: sticker near left margin
                x = insets.left + 4
            }
            // y is proportional to content height, using a generous range
            let y = insets.top + sticker.relativePosition.y * 400
            return CGRect(x: x, y: y, width: sticker.size.width, height: sticker.size.height)
        }

        func updateStickerPositionsForWidth(_ width: CGFloat) {
            lastWidth = width
        }

        func updateStickerViews() {
            guard let textView = textView else { return }
            let tvWidth = textView.bounds.width
            guard tvWidth > 0 else { return }
            lastWidth = tvWidth

            let currentIDs = Set(parent.floatingStickers.map(\.id))

            // Remove stale views
            for (id, view) in stickerImageViews where !currentIDs.contains(id) {
                view.removeFromSuperview()
                stickerImageViews.removeValue(forKey: id)
            }

            // Add or update sticker views
            for sticker in parent.floatingStickers {
                let frame = stickerFrame(for: sticker, in: tvWidth)
                if let existing = stickerImageViews[sticker.id] {
                    UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
                        existing.frame = frame
                    }
                } else {
                    let imgView = UIImageView(image: sticker.image)
                    imgView.contentMode = .scaleAspectFit
                    imgView.frame = frame
                    imgView.layer.shadowColor = UIColor.black.cgColor
                    imgView.layer.shadowOpacity = 0.18
                    imgView.layer.shadowRadius = 8
                    imgView.layer.shadowOffset = CGSize(width: 0, height: 5)
                    imgView.transform = CGAffineTransform(rotationAngle: -0.08)
                    imgView.isUserInteractionEnabled = parent.isEditable
                    imgView.accessibilityIdentifier = sticker.id.uuidString

                    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
                    imgView.addGestureRecognizer(pan)

                    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
                    imgView.addGestureRecognizer(longPress)

                    textView.addSubview(imgView)
                    stickerImageViews[sticker.id] = imgView
                }
            }
        }

        func updateExclusionPaths() {
            guard let textView = textView else { return }
            let tvWidth = textView.bounds.width > 0 ? textView.bounds.width : lastWidth
            guard tvWidth > 0 else { return }
            let insets = textView.textContainerInset

            let paths = parent.floatingStickers.map { sticker -> UIBezierPath in
                let frame = stickerFrame(for: sticker, in: tvWidth)
                // Exclusion paths are in text container coordinate system
                let exclusionRect = CGRect(
                    x: frame.origin.x - insets.left,
                    y: frame.origin.y - insets.top,
                    width: frame.width,
                    height: frame.height
                ).insetBy(dx: -8, dy: -6)
                return UIBezierPath(roundedRect: exclusionRect, cornerRadius: 8)
            }
            textView.textContainer.exclusionPaths = paths
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let imgView = gesture.view as? UIImageView,
                  let textView = textView,
                  let idString = imgView.accessibilityIdentifier,
                  let stickerID = UUID(uuidString: idString),
                  let idx = parent.floatingStickers.firstIndex(where: { $0.id == stickerID }) else { return }

            let translation = gesture.translation(in: textView)

            switch gesture.state {
            case .changed:
                imgView.center = CGPoint(
                    x: imgView.center.x + translation.x,
                    y: imgView.center.y + translation.y
                )
                gesture.setTranslation(.zero, in: textView)
                imgView.transform = CGAffineTransform(rotationAngle: -0.08).scaledBy(x: 1.08, y: 1.08)
                imgView.layer.shadowRadius = 14
                imgView.layer.shadowOpacity = 0.28
                // Live-update exclusion paths during drag
                updateExclusionPathsFromCurrentFrames()

            case .ended, .cancelled:
                imgView.transform = CGAffineTransform(rotationAngle: -0.08)
                imgView.layer.shadowRadius = 8
                imgView.layer.shadowOpacity = 0.18
                // Compute new relative position from final frame
                let tvWidth = textView.bounds.width
                let insets = textView.textContainerInset
                let contentWidth = tvWidth - insets.left - insets.right
                let frame = imgView.frame
                let relX: CGFloat = (frame.midX - insets.left) / contentWidth
                let relY: CGFloat = (frame.origin.y - insets.top) / 400.0
                var stickers = parent.floatingStickers
                stickers[idx].relativePosition = CGPoint(
                    x: min(max(relX, 0.1), 0.9),
                    y: min(max(relY, 0.02), 2.0)
                )
                parent.floatingStickers = stickers

            default:
                break
            }
        }

        /// Update exclusion paths from current UIImageView frames (during drag)
        private func updateExclusionPathsFromCurrentFrames() {
            guard let textView = textView else { return }
            let insets = textView.textContainerInset
            var paths: [UIBezierPath] = []
            for sticker in parent.floatingStickers {
                if let imgView = stickerImageViews[sticker.id] {
                    let frame = imgView.frame
                    let exclusionRect = CGRect(
                        x: frame.origin.x - insets.left,
                        y: frame.origin.y - insets.top,
                        width: frame.width,
                        height: frame.height
                    ).insetBy(dx: -8, dy: -6)
                    paths.append(UIBezierPath(roundedRect: exclusionRect, cornerRadius: 8))
                }
            }
            textView.textContainer.exclusionPaths = paths
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let imgView = gesture.view as? UIImageView,
                  let idString = imgView.accessibilityIdentifier,
                  let stickerID = UUID(uuidString: idString) else { return }

            let alert = UIAlertController(title: nil, message: "移除这张贴纸？", preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "移除", style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                imgView.removeFromSuperview()
                self.stickerImageViews.removeValue(forKey: stickerID)
                self.parent.floatingStickers.removeAll { $0.id == stickerID }
                self.updateExclusionPaths()
            })
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            if let vc = textView?.window?.rootViewController {
                var top = vc
                while let p = top.presentedViewController { top = p }
                top.present(alert, animated: true)
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isUserEditing = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isUserEditing = false
            // Refresh sticker layout now that editing is done
            updateStickerViews()
            updateExclusionPaths()
        }

        func textViewDidChange(_ textView: UITextView) {
            appliedText = textView.text
            parent.text = textView.text
        }
    }
}

private struct DiaryNotebookArchiveView: View {
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

private enum DiaryPaperStyle: String, CaseIterable, Identifiable {
    case lined
    case grid
    case dotted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lined: "横线"
        case .grid: "方格"
        case .dotted: "点阵"
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
    var pattern: some View {
        GeometryReader { geo in
            switch self {
            case .lined:
                let lineSpacing: CGFloat = 28
                let count = max(1, Int((geo.size.height - 46) / lineSpacing))
                VStack(spacing: lineSpacing - 1) {
                    ForEach(0..<count, id: \.self) { _ in
                        Rectangle()
                            .fill(Color(red: 0.66, green: 0.50, blue: 0.36).opacity(0.16))
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
                    context.stroke(horizontal, with: .color(accent.opacity(0.12)), lineWidth: 1)

                    var vertical = Path()
                    var x: CGFloat = spacing
                    while x < size.width {
                        vertical.move(to: CGPoint(x: x.rounded(.toNearestOrAwayFromZero) + 0.5, y: 0))
                        vertical.addLine(to: CGPoint(x: x.rounded(.toNearestOrAwayFromZero) + 0.5, y: size.height))
                        x += spacing
                    }
                    context.stroke(vertical, with: .color(accent.opacity(0.10)), lineWidth: 1)
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
                            context.fill(Path(ellipseIn: rect), with: .color(accent.opacity(0.16)))
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

private enum DiaryLayoutStyle: String, CaseIterable, Identifiable {
    case classic
    case timeline
    case inlineSticker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "经典"
        case .timeline: "时间线"
        case .inlineSticker: "内联"
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

private final class StickerCameraModel: NSObject, ObservableObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
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

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
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

private struct CameraPreview: UIViewRepresentable {
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

private final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

private struct ViewfinderCorners: Shape {
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

private struct DashedDivider: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct FlowLayout: Layout {
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

private enum StickerMaker {
    private static let context = CIContext()

    static func makeSticker(from image: UIImage) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            let normalized = image
                .normalizedForVision()
                .resizedForStickerProcessing(maxDimension: 1400)
            let cutout = try cutOutForeground(from: normalized)
            let cropped = cutout.croppedToVisiblePixels(padding: 30)
            return cropped
                .renderSticker(maxBorderWidth: 22)
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

private enum StickerError: Error {
    case invalidImage
    case noSubject
    case renderFailed
}

private extension UIImage {
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
                color: UIColor.black.withAlphaComponent(0.14).cgColor
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

private struct SettingsSheet: View {
    var onReplayOnboarding: () -> Void = {}
    let onClose: () -> Void

    @State private var showContactUs = false
    @State private var showAbout = false
    @State private var showVersionInfo = false
    @State private var showShareSheet = false
    @State private var showDiaryPrompt = false

    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let mutedInk = Color(red: 0.56, green: 0.56, blue: 0.58)
    private let cardBg = Color(red: 0.96, green: 0.96, blue: 0.97)
    private let accent = Color(red: 0.95, green: 0.65, blue: 0.12)

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return v
    }

    private var shareItems: [Any] {
        let text = "推荐你试试「贴纸日记」，每天拍照收集贴纸，再写成自己的日记。"
        if let url = URL(string: "https://apps.apple.com/app/id0000000000") {
            return [text, url]
        }
        return [text]
    }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    closeButton

                    Image("BrandAppIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                        .padding(.leading, 24)
                        .padding(.top, 8)

                    Text("设置")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(ink)
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                    Text("贴纸日记")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 24)
                        .padding(.top, 2)

                    VStack(spacing: 16) {
                        settingsCard {
                            VStack(spacing: 0) {
                                settingsRow(icon: "square.and.arrow.up", title: "分享给朋友") {
                                    showShareSheet = true
                                }
                                settingsDivider
                                settingsRow(icon: "bubble.left.and.bubble.right", title: "联系我们") {
                                    showContactUs = true
                                }
                                settingsDivider
                                settingsRow(icon: "pencil.line", title: "写个评价") {
                                    requestAppReview()
                                }
                            }
                        }

                        settingsCard {
                            VStack(spacing: 0) {
                                settingsRow(icon: "text.bubble", title: "日记提示语") {
                                    showDiaryPrompt = true
                                }
                            }
                        }

                        settingsCard {
                            VStack(spacing: 0) {
                                settingsRow(icon: "info.circle", title: "关于贴纸日记") {
                                    showAbout = true
                                }
                                settingsDivider
                                settingsRow(icon: "sparkles", title: "重新查看引导") {
                                    onClose()
                                    onReplayOnboarding()
                                }
                                settingsDivider
                                settingsRow(icon: "doc.text", title: "版本信息", trailing: appVersion) {
                                    showVersionInfo = true
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 26)

                    Text("每天的小确幸，都值得被贴下来。")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(mutedInk.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                        .padding(.bottom, 40)
                }
            }
        }
        .sheet(isPresented: $showContactUs) {
            ContactUsPage()
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
    }

    private var closeButton: some View {
        HStack {
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.50, green: 0.50, blue: 0.52))
                    .frame(width: 32, height: 32)
                    .background(Color(red: 0.92, green: 0.92, blue: 0.93), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 20)
        .padding(.trailing, 20)
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
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(ink)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 14, weight: .semibold))
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

    private func settingsIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(ink)
            .symbolRenderingMode(.monochrome)
            .frame(width: 38, height: 38)
    }

    private func requestAppReview() {
        // Try the modern API first; fall back to App Store URL
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            SKStoreReviewController.requestReview(in: scene)
        }
    }
}

// MARK: - Diary Prompt Sheet

private struct DiaryPromptSheet: View {
    @State private var promptText: String = BailianDiaryGenerator.currentSystemPrompt
    @State private var isEditing = false
    @State private var selectedTemplateId: String? = nil
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let mutedInk = Color(red: 0.56, green: 0.56, blue: 0.58)
    private let accent = Color(red: 0.95, green: 0.65, blue: 0.12)
    private let cardBg = Color(red: 0.96, green: 0.96, blue: 0.97)

    private struct PromptTemplate: Identifiable {
        let id: String
        let emoji: String
        let name: String
        let description: String
        let prompt: String
    }

    private let templates: [PromptTemplate] = [
        PromptTemplate(
            id: "default",
            emoji: "\u{2615}",
            name: "温柔日常",
            description: "平静温暖，像和朋友聊天",
            prompt: BailianDiaryGenerator.defaultSystemPrompt
        ),
        PromptTemplate(
            id: "happy",
            emoji: "\u{2728}",
            name: "开心活泼",
            description: "元气满满，充满感叹号",
            prompt: "你是一位开朗、活泼、充满元气的中文日记作者。你会根据用户当天拍的照片，识别物品和场景，用欢快明亮的语气写成日记。多用感叹句和俏皮的比喻，让每一天都读起来像值得庆祝的小事件。绝对不要在日记正文中出现「贴纸」这个词。"
        ),
        PromptTemplate(
            id: "calm",
            emoji: "\u{1F343}",
            name: "安静治愈",
            description: "轻柔缓慢，像雨天读书",
            prompt: "你是一位安静、细腻、善于感受的中文日记作者。你会根据用户当天拍的照片，识别物品和场景，用舒缓治愈的文字写成日记。语调轻柔，节奏慢一些，关注细微的感官体验——光线、气味、温度、质感。让人读完觉得被轻轻抱了一下。绝对不要在日记正文中出现「贴纸」这个词。"
        ),
        PromptTemplate(
            id: "literary",
            emoji: "\u{1F319}",
            name: "文艺感伤",
            description: "诗意忧郁，像深夜独白",
            prompt: "你是一位文艺、敏感、略带忧伤的中文日记作者。你会根据用户当天拍的照片，识别物品和场景，用诗意的笔触写成日记。可以有淡淡的感伤和怀旧，善用意象和留白，让文字像一首没写完的诗。绝对不要在日记正文中出现「贴纸」这个词。"
        ),
        PromptTemplate(
            id: "humor",
            emoji: "\u{1F643}",
            name: "幽默吐槽",
            description: "轻松搞笑，自带段子手属性",
            prompt: "你是一位幽默、机智、善于吐槽的中文日记作者。你会根据用户当天拍的照片，识别物品和场景，用轻松诙谐的语气写成日记。适当加入自嘲和生活吐槽，像在跟好朋友发消息一样随意有趣。绝对不要在日记正文中出现「贴纸」这个词。"
        ),
        PromptTemplate(
            id: "minimal",
            emoji: "\u{1F4DD}",
            name: "简洁记录",
            description: "干净利落，只留关键信息",
            prompt: "你是一位简洁、克制的中文日记作者。你会根据用户当天拍的照片，识别物品和场景，用最精炼的文字记录当天发生了什么。不堆砌形容词，不抒情，像备忘录一样干净利落，但仍然有温度。绝对不要在日记正文中出现「贴纸」这个词。"
        ),
    ]

    private var hasChanges: Bool {
        promptText.trimmingCharacters(in: .whitespacesAndNewlines) != BailianDiaryGenerator.currentSystemPrompt
    }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(red: 0.50, green: 0.50, blue: 0.52))
                                .frame(width: 32, height: 32)
                                .background(Color(red: 0.92, green: 0.92, blue: 0.93), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 20)
                    .padding(.trailing, 20)

                    Text("日记提示语")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(ink)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                    Text("选一个风格模板，或者自由编辑")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(mutedInk)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)

                    // Template grid
                    templateGrid
                        .padding(.top, 20)

                    // Current prompt card
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("当前提示语")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(mutedInk)
                            Spacer()
                            if selectedTemplateId == nil && BailianDiaryGenerator.isUsingCustomPrompt {
                                Text("已自定义")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(accent.opacity(0.12), in: Capsule())
                            }
                        }

                        if isEditing {
                            TextEditor(text: $promptText)
                                .font(.system(size: 15))
                                .foregroundStyle(ink)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 160)
                                .focused($isFocused)
                        } else {
                            Text(promptText)
                                .font(.system(size: 15))
                                .foregroundStyle(ink)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(18)
                    .background(cardBg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(isEditing ? accent.opacity(0.6) : .clear, lineWidth: 2)
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    // Action buttons
                    actionButtons
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    // Tips
                    VStack(alignment: .leading, spacing: 8) {
                        Text("小提示")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(mutedInk)
                        Text("• 选择模板后可以继续编辑微调\n• 修改后对新生成的日记生效\n• 已生成的日记不会改变")
                            .font(.system(size: 14))
                            .foregroundStyle(mutedInk.opacity(0.8))
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            selectedTemplateId = matchingTemplateId()
        }
    }

    // MARK: Template Grid

    private var templateGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(templates) { template in
                templateCard(template)
            }
        }
        .padding(.horizontal, 20)
    }

    private func templateCard(_ template: PromptTemplate) -> some View {
        let isActive = selectedTemplateId == template.id
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTemplateId = template.id
                promptText = template.prompt
                isEditing = false
                isFocused = false
            }
            // Auto-save when selecting a template
            BailianDiaryGenerator.currentSystemPrompt = template.prompt
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(template.emoji)
                    .font(.system(size: 24))
                HStack(spacing: 0) {
                    Text(template.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isActive ? accent : ink)
                    Spacer()
                }
                Text(template.description)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? accent.opacity(0.8) : mutedInk)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isActive ? accent.opacity(0.08) : cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isActive ? accent : .clear, lineWidth: 2)
            )
            .opacity(selectedTemplateId == nil || isActive ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }

    // MARK: Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        if isEditing {
            Button {
                let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                BailianDiaryGenerator.currentSystemPrompt = trimmed
                promptText = BailianDiaryGenerator.currentSystemPrompt
                selectedTemplateId = matchingTemplateId()
                isEditing = false
                isFocused = false
            } label: {
                Text("保存")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(hasChanges ? 1 : 0.5)
            .disabled(!hasChanges)

            Button {
                promptText = BailianDiaryGenerator.currentSystemPrompt
                isEditing = false
                isFocused = false
            } label: {
                Text("取消")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            Button {
                isEditing = true
                selectedTemplateId = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isFocused = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 16, weight: .bold))
                    Text("自由编辑")
                        .font(.system(size: 17, weight: .bold))
                }
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Helpers

    private func matchingTemplateId() -> String? {
        let current = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        return templates.first(where: { $0.prompt == current })?.id
    }
}


// MARK: - Contact Us Page

private struct ContactUsPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copiedEmail = false
    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let mutedInk = Color(red: 0.56, green: 0.56, blue: 0.58)
    private let cardBg = Color(red: 0.96, green: 0.96, blue: 0.97)
    private let accent = Color(red: 0.95, green: 0.65, blue: 0.12)
    private let email = "raowenjieszu@gmail.com"

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    closeButton

                    Image("BrandAppIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                        .padding(.leading, 24)
                        .padding(.top, 8)

                    Text("联系我们")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(ink)
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                    Text("贴纸日记")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 24)
                        .padding(.top, 2)

                    VStack(spacing: 0) {
                        emailRow
                        settingsDivider
                        xiaohongshuRow
                    }
                    .background(cardBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 28)

                    Text("有想法、问题或者想分享你的贴纸日记，都可以来找我。")
                        .font(.system(size: 15))
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
    }

    private var closeButton: some View {
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.50, green: 0.50, blue: 0.52))
                    .frame(width: 32, height: 32)
                    .background(Color(red: 0.92, green: 0.92, blue: 0.93), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 20)
        .padding(.trailing, 20)
    }

    private var emailRow: some View {
        HStack(spacing: 14) {
            contactIcon("envelope.fill", color: Color(red: 0.20, green: 0.50, blue: 0.90))
            VStack(alignment: .leading, spacing: 4) {
                Text("邮箱")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(ink)
                Text(email)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(mutedInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer(minLength: 12)
            Button {
                UIPasteboard.general.string = email
                withAnimation { copiedEmail = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { copiedEmail = false }
                }
            } label: {
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

    private var xiaohongshuRow: some View {
        Button {
            if let url = URL(string: "https://www.xiaohongshu.com/user/profile/608e5e7500000000010050c2") {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 14) {
                contactIcon("camera.fill", color: Color(red: 0.92, green: 0.20, blue: 0.30))
                Text("小红书")
                    .font(.system(size: 17, weight: .bold))
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

// MARK: - About App Sheet

private struct AboutAppSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let mutedInk = Color(red: 0.56, green: 0.56, blue: 0.58)
    private let accent = Color(red: 0.95, green: 0.65, blue: 0.12)

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Close button
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(red: 0.50, green: 0.50, blue: 0.52))
                                .frame(width: 32, height: 32)
                                .background(Color(red: 0.92, green: 0.92, blue: 0.93), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 20)
                    .padding(.trailing, 20)

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
                        .font(.system(size: 28, weight: .black))
                        .foregroundStyle(ink)
                        .padding(.leading, 24)
                        .padding(.top, 16)

                    // Tagline with colored brackets
                    HStack(spacing: 0) {
                        Text("收集我的「")
                            .font(.system(size: 28, weight: .black))
                            .foregroundStyle(ink)
                        Text("贴纸日记")
                            .font(.system(size: 28, weight: .black))
                            .foregroundStyle(accent)
                        Text("」")
                            .font(.system(size: 28, weight: .black))
                            .foregroundStyle(accent)
                    }
                    .padding(.leading, 24)
                    .padding(.top, 2)

                    // Story card
                    VStack(alignment: .leading, spacing: 14) {
                        Text("📒 把每天的小物件，收进一页日记")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(ink)

                        Text("生活里有很多很轻的小瞬间：一杯饮料、一张票根、一只新买的小物、路边看到的花。它们很容易被拍进相册，也很容易被忘在相册深处。")
                            .font(.system(size: 15))
                            .foregroundStyle(mutedInk)
                            .lineSpacing(5)

                        Text("贴纸日记想做的事情很简单：把这些零散的照片变成贴纸，再把贴纸放回当天的日记里。")
                            .font(.system(size: 15))
                            .foregroundStyle(mutedInk)
                            .lineSpacing(5)

                        Text("拍一张照片，AI 自动识别并抠图，生成一张属于今天的贴纸。等你回头翻看时，看到的不只是图片，而是那一天被留下来的心情。")
                            .font(.system(size: 15))
                            .foregroundStyle(ink)
                            .lineSpacing(5)

                        Text("✨ 每一天，都可以被轻轻贴下来")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(ink)
                            .padding(.top, 4)

                        Text("你可以让贴纸日记帮你生成文字，也可以自己慢慢写。重要的不是记录得多完整，而是那些普通但可爱的东西，终于有了自己的位置。")
                            .font(.system(size: 15))
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

private struct VersionInfoSheet: View {
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
                // Close button
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(red: 0.50, green: 0.50, blue: 0.52))
                            .frame(width: 32, height: 32)
                            .background(Color(red: 0.92, green: 0.92, blue: 0.93), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 20)
                .padding(.trailing, 20)

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
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(ink)

                Spacer().frame(height: 20)

                // Description
                VStack(alignment: .leading, spacing: 12) {
                    Text("贴纸日记用 AI 技术识别并抠出照片里的主体，将它们变成当天的贴纸，再放进你的专属日记里。")
                        .font(.system(size: 15))
                        .foregroundStyle(mutedInk)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)

                    Text("贴纸和日记默认保存在本机；当你使用 AI 生成日记时，当天贴纸会发送到配置的模型服务用于生成内容。")
                        .font(.system(size: 15))
                        .foregroundStyle(mutedInk)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)

                Spacer().frame(height: 28)

                // Links card
                VStack(spacing: 0) {
                    linkRow(title: "用户协议") {
                        openExternalURL("https://jackyrwj.github.io/StickerDiary/user-agreement.html")
                    }
                    Divider().padding(.leading, 20)
                    linkRow(title: "隐私政策") {
                        openExternalURL("https://jackyrwj.github.io/StickerDiary/privacy-policy.html")
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
                    .font(.system(size: 17))
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

private struct SharePreviewOverlay: View {
    let image: UIImage
    let activeCoachStep: AppCoachStep?
    let onCoachCompleteClose: () -> Void
    let onClose: () -> Void
    let onShare: () -> Void

    private let ink = Color(red: 0.22, green: 0.15, blue: 0.12)
    @State private var showCoachGuide = false

    var body: some View {
        ZStack {
            PaperTextureBackground()

            VStack(spacing: 0) {
                HStack {
                    Button(action: onShare) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Color(red: 0.34, green: 0.24, blue: 0.18), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("预览")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(ink)

                    Spacer()

                    Button(action: closePreview) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(ink)
                            .frame(width: 48, height: 48)
                            .background(.white.opacity(0.70), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)

                ScrollView {
                    VStack(spacing: 16) {
                        Image(uiImage: image)
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

                shareCompleteCard
                    .padding(.horizontal, 34)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .onAppear {
            if activeCoachStep == .shareComplete {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    guard activeCoachStep == .shareComplete else { return }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        showCoachGuide = true
                    }
                }
            }
        }
        .onChange(of: activeCoachStep) { _, newValue in
            if newValue == .shareComplete {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    guard activeCoachStep == .shareComplete else { return }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        showCoachGuide = true
                    }
                }
            }
        }
    }

    private var shareCompleteCard: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(Color(red: 0.76, green: 0.45, blue: 0.18))
                .padding(.top, 6)

            VStack(spacing: 14) {
                Text(AppCoachStep.shareComplete.title)
                    .font(.system(size: 25, weight: .black))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)

                Text(AppCoachStep.shareComplete.message)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.48, green: 0.40, blue: 0.34))
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: dismissGuide) {
                Text(AppCoachStep.shareComplete.buttonTitle)
                    .font(.system(size: 18, weight: .black))
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

// MARK: - Share Sheet

private struct ShareSheetView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack { DailyStickerView() }
}
