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
    var mode: StickerGenerationMode = .mock

    var body: some View {
        Label(label, systemImage: mode == .mock ? "hammer.fill" : "cloud.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(AppTheme.accent.opacity(0.10), in: Capsule())
            .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        switch mode {
        case .mock: "原型模式 · 暂用模拟图"
        case .backend: "AI 后端生成模式"
        }
    }

    private var accessibilityLabel: String {
        switch mode {
        case .mock: "当前为原型模式，生成结果使用模拟图片"
        case .backend: "当前使用 AI 后端生成图片"
        }
    }
}
