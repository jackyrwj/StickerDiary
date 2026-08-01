import UIKit

struct MockStickerGenerationService: StickerGenerating {
    enum GenerationError: LocalizedError {
        case invalidPhoto

        var errorDescription: String? {
            "无法读取所选照片，请换一张再试。"
        }
    }

    func generate(
        from referencePhotoData: [Data],
        progress: @escaping (Int, ReactionIntent) async -> Void
    ) async throws -> [StickerDraft] {
        guard let data = referencePhotoData.first,
              let reference = UIImage(data: data) else {
            throw GenerationError.invalidPhoto
        }

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalStickerDrafts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        var drafts: [StickerDraft] = []
        for (index, reaction) in ReactionIntent.allCases.enumerated() {
            try Task.checkCancellation()
            await progress(index, reaction)
            try await Task.sleep(for: .milliseconds(160))

            let baseArtwork = await MainActor.run {
                StickerRenderer.mockArtwork(reference: reference, reaction: reaction)
            }
            let id = UUID()
            let baseURL = cacheDirectory.appendingPathComponent("\(id.uuidString)-base.png")
            let outputURL = cacheDirectory.appendingPathComponent("\(id.uuidString).png")
            let output = await MainActor.run {
                StickerRenderer.captionedArtwork(
                    baseArtwork: baseArtwork,
                    caption: reaction.caption
                )
            }
            guard let basePNG = baseArtwork.pngData(),
                  let outputPNG = output.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }
            try basePNG.write(to: baseURL, options: .atomic)
            try outputPNG.write(to: outputURL, options: .atomic)
            drafts.append(
                StickerDraft(
                    id: id,
                    reaction: reaction,
                    caption: reaction.caption,
                    baseArtworkURL: baseURL,
                    temporaryImageURL: outputURL
                )
            )
        }
        return drafts
    }
}

@MainActor
enum StickerRenderer {
    static func mockArtwork(reference: UIImage, reaction: ReactionIntent) -> UIImage {
        let size = CGSize(width: 408, height: 408)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let canvas = CGRect(origin: .zero, size: size)
            context.cgContext.clear(canvas)

            let bubble = CGRect(x: 36, y: 22, width: 336, height: 336)
            let bubblePath = UIBezierPath(roundedRect: bubble, cornerRadius: 84)
            UIColor.white.setStroke()
            bubblePath.lineWidth = 18
            context.cgContext.saveGState()
            bubblePath.addClip()
            UIColor.systemPurple.withAlphaComponent(0.12).setFill()
            bubblePath.fill()
            drawAspectFill(reference, in: bubble, context: context.cgContext)
            context.cgContext.restoreGState()
            bubblePath.stroke()

            let emoji = reaction.emoji as NSString
            emoji.draw(
                in: CGRect(x: 252, y: 195, width: 120, height: 120),
                withAttributes: [.font: UIFont.systemFont(ofSize: 76)]
            )
        }
    }

    static func captionedArtwork(baseArtwork: UIImage, caption: String) -> UIImage {
        let size = baseArtwork.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            baseArtwork.draw(in: CGRect(origin: .zero, size: size))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(
                    ofSize: caption.count <= 4 ? 52 : 40,
                    weight: .black
                ),
                .foregroundColor: UIColor.label,
                .strokeColor: UIColor.white,
                .strokeWidth: -8,
                .paragraphStyle: paragraph
            ]
            (caption as NSString).draw(
                in: CGRect(x: 12, y: 334, width: 384, height: 66),
                withAttributes: attributes
            )
        }
    }

    private static func drawAspectFill(
        _ image: UIImage,
        in rect: CGRect,
        context: CGContext
    ) {
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let targetSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let targetRect = CGRect(
            x: rect.midX - targetSize.width / 2,
            y: rect.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        image.draw(in: targetRect)
    }
}
