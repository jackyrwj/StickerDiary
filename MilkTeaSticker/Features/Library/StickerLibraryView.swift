import SwiftUI

struct StickerLibraryView: View {
    let library: StickerLibrary

    var body: some View {
        NavigationStack {
            Group {
                if library.packs.isEmpty {
                    emptyState
                } else {
                    packList
                }
            }
            .background(AppTheme.background)
            .navigationTitle("我的贴纸")
            .navigationDestination(for: UUID.self) { packID in
                StickerPackDetailView(packID: packID, library: library)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有贴纸", systemImage: "face.smiling.inverse")
        } description: {
            Text("先到“制作”选择照片，几分钟后就能拥有第一套常用表情。")
        }
    }

    private var packList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                systemTip
                ForEach(library.packs) { pack in
                    NavigationLink(value: pack.id) {
                        StickerPackCard(pack: pack, library: library)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    private var systemTip: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("保存后可在系统贴纸入口使用")
                    .font(.headline)
                Text("打开表情键盘里的贴纸入口，就能在支持的聊天场景中找到“贴贴”。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct StickerPackCard: View {
    let pack: StickerPack
    let library: StickerLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(pack.name)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Text("\(pack.stickers.count) 张 · \(pack.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                ForEach(pack.stickers.prefix(4)) { sticker in
                    StickerArtworkView(imageURL: library.imageURL(for: sticker), cornerRadius: 14)
                        .aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .padding(16)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pack.name)，共 \(pack.stickers.count) 张贴纸")
    }
}

#Preview("空贴纸库") {
    StickerLibraryView(library: .preview)
}
