import SwiftUI

struct GenerationView: View {
    let library: StickerLibrary
    let onSaved: () -> Void
    @State private var model: GenerationViewModel

    init(
        request: GenerationRequest,
        library: StickerLibrary,
        onSaved: @escaping () -> Void
    ) {
        self.library = library
        self.onSaved = onSaved
        _model = State(initialValue: GenerationViewModel(request: request))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .preparing:
                GenerationProgressView(progress: 0, title: "正在理解你的照片", detail: "建立统一的角色形象…")
            case .generating(let completed, let total, let current):
                GenerationProgressView(
                    progress: Double(completed) / Double(total),
                    title: "正在制作 \(current.caption)",
                    detail: current.direction
                )
            case .reviewing:
                reviewContent
            case .failed(let message):
                ContentUnavailableView {
                    Label("生成没有完成", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                } description: {
                    Text(message)
                } actions: {
                    Button("重新生成") {
                        Task { await model.retry() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .background(AppTheme.background)
        .navigationTitle("生成贴纸")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.phase != .reviewing)
        .task {
            await model.start()
        }
        .sheet(item: $model.selectedDraft) { draft in
            EditStickerSheet(draft: draft) { caption in
                model.updateCaption(for: draft.id, caption: caption)
            } onDelete: {
                model.deleteDraft(id: draft.id)
            }
        }
        .alert("无法保存", isPresented: Binding(
            get: { model.saveErrorMessage != nil },
            set: { if !$0 { model.saveErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(model.saveErrorMessage ?? "请稍后再试。")
        }
    }

    private var reviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("这一包先这样")
                            .font(.system(.title, design: .rounded, weight: .bold))
                        Text("点开任意贴纸可修改文字或删除。真实 AI 接入后还可以单张重做。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    PrototypeBadge()
                }

                TextField("贴纸包名称", text: $model.packName)
                    .font(.headline)
                    .padding(14)
                    .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16))

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    ForEach(model.drafts) { draft in
                        Button {
                            model.selectedDraft = draft
                        } label: {
                            VStack(spacing: 8) {
                                StickerArtworkView(imageURL: draft.temporaryImageURL)
                                    .aspectRatio(1, contentMode: .fit)
                                Text(draft.caption)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .padding(8)
                            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 22))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(draft.caption)贴纸，点按编辑")
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 76)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                do {
                    try model.save(to: library)
                    onSaved()
                } catch {}
            } label: {
                Label(
                    model.isSaving ? "正在保存" : "保存到我的贴纸库",
                    systemImage: "square.and.arrow.down.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.drafts.isEmpty || model.isSaving)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }
}

private struct GenerationProgressView: View {
    let progress: Double
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle()
                    .fill(AppTheme.accent.opacity(0.10))
                    .frame(width: 168, height: 168)
                Image(systemName: "face.smiling.inverse")
                    .font(.system(size: 70))
                    .foregroundStyle(AppTheme.accent)
                    .symbolEffect(.pulse, options: .repeating)
            }
            VStack(spacing: 9) {
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 260)
            Text("离开此页面会取消本次生成")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct EditStickerSheet: View {
    let draft: StickerDraft
    let onSave: (String) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var caption: String

    init(
        draft: StickerDraft,
        onSave: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.draft = draft
        self.onSave = onSave
        self.onDelete = onDelete
        _caption = State(initialValue: draft.caption)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    StickerArtworkView(imageURL: draft.temporaryImageURL, cornerRadius: 30)
                        .aspectRatio(1, contentMode: .fit)
                        .listRowBackground(Color.clear)
                }
                Section {
                    TextField("输入常用语", text: $caption)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("贴纸文字")
                } footer: {
                    Text("文字由手机本地渲染，因此中文不会被 AI 写错。")
                }
                Section {
                    Button("删除这张贴纸", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle(draft.reaction.caption)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(caption)
                        dismiss()
                    }
                    .disabled(caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
