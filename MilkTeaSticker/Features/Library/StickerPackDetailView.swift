import SwiftUI

struct StickerPackDetailView: View {
    let packID: UUID
    let library: StickerLibrary

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

    var body: some View {
        Group {
            if let pack = library.packs.first(where: { $0.id == packID }) {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)
                        ],
                        spacing: 12
                    ) {
                        ForEach(pack.stickers) { sticker in
                            StickerLibraryCell(
                                sticker: sticker,
                                imageURL: library.imageURL(for: sticker),
                                onFavorite: {
                                    library.toggleFavorite(packID: packID, stickerID: sticker.id)
                                }
                            )
                        }
                    }
                    .padding(20)
                }
                .navigationTitle(pack.name)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("删除整包", systemImage: "trash", role: .destructive) {
                                showDeleteConfirmation = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            } else {
                ContentUnavailableView("贴纸包不存在", systemImage: "questionmark.folder")
            }
        }
        .background(AppTheme.background)
        .confirmationDialog(
            "确定删除这套贴纸吗？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除整包", role: .destructive) {
                library.deletePack(id: packID)
                dismiss()
            }
        } message: {
            Text("删除后，系统贴纸入口中的对应图片也会消失。")
        }
    }
}

private struct StickerLibraryCell: View {
    let sticker: ReactionSticker
    let imageURL: URL?
    let onFavorite: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                StickerArtworkView(imageURL: imageURL)
                    .aspectRatio(1, contentMode: .fit)
                Button(action: onFavorite) {
                    Image(systemName: sticker.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(sticker.isFavorite ? .pink : .secondary)
                        .padding(9)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(8)
                .accessibilityLabel(sticker.isFavorite ? "取消收藏" : "收藏")
            }
            HStack {
                Text(sticker.caption)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let imageURL {
                    ShareLink(item: imageURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享\(sticker.caption)贴纸")
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 22))
    }
}
