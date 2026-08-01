import PhotosUI
import SwiftUI

struct CreateStickerView: View {
    let onContinue: (GenerationRequest) -> Void

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var photoData: [Data] = []
    @State private var isLoadingPhotos = false
    @State private var photoError: String?

    private let photoColumns = [
        GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                photoPickerCard
                reactionPreview
                privacyNote
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(AppTheme.background)
        .navigationTitle("制作我的贴纸")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            continueButton
        }
        .task(id: selectedItems) {
            await loadSelectedPhotos()
        }
        .alert("照片读取失败", isPresented: Binding(
            get: { photoError != nil },
            set: { if !$0 { photoError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(photoError ?? "请换一张照片再试。")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrototypeBadge()
            Text("一组照片，变成聊天里\n真正用得上的表情")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.8)
            Text("选择 1–4 张清晰正脸照。我们会固定生成 12 个高频反应，不需要你写提示词。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    private var photoPickerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("参考照片", systemImage: "person.crop.square")
                    .font(.headline)
                Spacer()
                Text("\(photoData.count)/4")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if photoData.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 42))
                        .foregroundStyle(AppTheme.accent)
                    Text("正脸清晰、光线自然，生成会更像你")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                LazyVGrid(columns: photoColumns, spacing: 12) {
                    ForEach(Array(photoData.enumerated()), id: \.offset) { index, data in
                        ReferencePhotoThumbnail(data: data, index: index)
                    }
                }
            }

            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: 4,
                matching: .images
            ) {
                Label(
                    photoData.isEmpty ? "选择照片" : "重新选择",
                    systemImage: "photo.on.rectangle.angled"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoadingPhotos)
        }
        .padding(18)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var reactionPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("首包包含")
                .font(.headline)
            FlowLayout(spacing: 8) {
                ForEach(ReactionIntent.allCases) { reaction in
                    Text("\(reaction.emoji) \(reaction.caption)")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(.background, in: Capsule())
                }
            }
        }
        .padding(18)
        .background(AppTheme.warm.opacity(0.16), in: RoundedRectangle(cornerRadius: 26))
    }

    private var privacyNote: some View {
        Label(
            "当前原型只在本机处理所选照片，不会上传。接入真实 AI 前会再次明确告知你。",
            systemImage: "lock.shield.fill"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var continueButton: some View {
        Button {
            onContinue(GenerationRequest(photoData: photoData))
        } label: {
            HStack {
                if isLoadingPhotos {
                    ProgressView().tint(.white)
                }
                Text(isLoadingPhotos ? "正在读取照片" : "生成 12 张常用贴纸")
                    .font(.headline)
                Image(systemName: "arrow.right")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .buttonStyle(.borderedProminent)
        .disabled(photoData.isEmpty || isLoadingPhotos)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func loadSelectedPhotos() async {
        guard !selectedItems.isEmpty else {
            photoData = []
            return
        }
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }

        var loaded: [Data] = []
        for item in selectedItems.prefix(4) {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    loaded.append(data)
                }
            } catch is CancellationError {
                return
            } catch {
                photoError = "有一张照片无法读取，请重新选择。"
                return
            }
        }
        photoData = loaded
    }
}

private struct ReferencePhotoThumbnail: View {
    let data: Data
    let index: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 112)
                    .clipped()
            }
            Text("\(index + 1)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(7)
                .background(.black.opacity(0.55), in: Circle())
                .padding(7)
        }
        .frame(height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("第 \(index + 1) 张参考照片")
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let result = arrangement(width: proposal.width ?? 0, subviews: subviews)
        return result.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}

#Preview {
    NavigationStack {
        CreateStickerView { _ in }
    }
}
