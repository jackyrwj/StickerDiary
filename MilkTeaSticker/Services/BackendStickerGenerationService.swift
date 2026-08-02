import Foundation
import UIKit

struct BackendStickerGenerationService: StickerGenerating {
    let baseURL: URL
    var mode: StickerGenerationMode { .backend }

    func generate(
        from referencePhotoData: [Data],
        progress: @escaping (Int, ReactionIntent) async -> Void
    ) async throws -> [StickerDraft] {
        guard !referencePhotoData.isEmpty else {
            throw BackendGenerationError.invalidPhotos
        }

        let referenceImages = try await MainActor.run {
            try referencePhotoData.prefix(4).map { data -> BackendReferenceImage in
                guard let jpeg = StickerRenderer.preparedReferenceJPEG(from: data) else {
                    throw BackendGenerationError.invalidPhotos
                }
                return BackendReferenceImage(
                    dataURL: "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
                )
            }
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

            let imageData = try await generateOne(
                referenceImages: referenceImages,
                reaction: reaction
            )
            let foreground = await StickerForegroundExtractor.extract(from: imageData)
            let rendered = try await MainActor.run {
                guard let generatedImage = UIImage(data: imageData) else {
                    throw BackendGenerationError.invalidResponse
                }
                let baseArtwork = StickerRenderer.normalizedArtwork(
                    foreground ?? generatedImage
                )
                let output = StickerRenderer.captionedArtwork(
                    baseArtwork: baseArtwork,
                    caption: reaction.caption
                )
                guard let basePNG = baseArtwork.pngData(),
                      let outputPNG = output.pngData() else {
                    throw BackendGenerationError.invalidResponse
                }
                return (basePNG, outputPNG)
            }

            let id = UUID()
            let baseURL = cacheDirectory.appendingPathComponent("\(id.uuidString)-base.png")
            let outputURL = cacheDirectory.appendingPathComponent("\(id.uuidString).png")
            try rendered.0.write(to: baseURL, options: .atomic)
            try rendered.1.write(to: outputURL, options: .atomic)
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

    private func generateOne(
        referenceImages: [BackendReferenceImage],
        reaction: ReactionIntent
    ) async throws -> Data {
        let endpoint = baseURL.appendingPathComponent("v1/stickers/generate")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 200
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try JSONEncoder().encode(
            BackendGenerationRequest(
                referenceImages: referenceImages,
                reactionId: reaction.rawValue
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendGenerationError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let failure = try? JSONDecoder().decode(BackendFailureResponse.self, from: data)
            throw BackendGenerationError.server(
                failure?.error.message ?? "生成服务返回错误（\(httpResponse.statusCode)）"
            )
        }

        let result = try JSONDecoder().decode(BackendGenerationResponse.self, from: data)
        guard let imageData = Data(base64Encoded: result.imageBase64),
              !imageData.isEmpty else {
            throw BackendGenerationError.invalidResponse
        }
        return imageData
    }
}

enum StickerGenerationServiceFactory {
    static func makeDefault(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> any StickerGenerating {
#if DEBUG
        if let backendURL = launchValue(named: "-StickerBackendURL", arguments: arguments),
           let url = URL(string: backendURL),
           let scheme = url.scheme,
           ["http", "https"].contains(scheme) {
            return BackendStickerGenerationService(baseURL: url)
        }
#endif
        return MockStickerGenerationService()
    }

    private static func launchValue(named name: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

private struct BackendReferenceImage: Encodable, Sendable {
    let dataURL: String
}

private struct BackendGenerationRequest: Encodable, Sendable {
    let referenceImages: [BackendReferenceImage]
    let reactionId: String
}

private struct BackendGenerationResponse: Decodable, Sendable {
    let imageBase64: String
    let mimeType: String
    let providerRequestId: String?
}

private struct BackendFailureResponse: Decodable, Sendable {
    let error: BackendFailure
}

private struct BackendFailure: Decodable, Sendable {
    let code: String
    let message: String
    let retryable: Bool
}

private enum BackendGenerationError: LocalizedError {
    case invalidPhotos
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidPhotos:
            "参考照片无法读取，请重新选择。"
        case .invalidResponse:
            "生成结果无法读取，请重试。"
        case .server(let message):
            message
        }
    }
}
