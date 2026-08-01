import SwiftUI

struct StickerArtworkView: View {
    let imageURL: URL?
    var cornerRadius: CGFloat = 24

    var body: some View {
        Group {
            if let imageURL,
               let image = UIImage(contentsOfFile: imageURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.black.opacity(0.05), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

struct PrototypeBadge: View {
    var body: some View {
        Label("原型模式 · 暂用模拟图", systemImage: "hammer.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(AppTheme.accent.opacity(0.10), in: Capsule())
            .accessibilityLabel("当前为原型模式，生成结果使用模拟图片")
    }
}
