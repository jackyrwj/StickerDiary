import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class GenerationViewModel {
    private(set) var phase: GenerationPhase = .preparing
    var drafts: [StickerDraft] = []
    var selectedDraft: StickerDraft?
    var packName = "我的常用表情"
    var isSaving = false
    var saveErrorMessage: String?

    private let request: GenerationRequest
    private let generator: any StickerGenerating

    init(
        request: GenerationRequest,
        generator: any StickerGenerating = MockStickerGenerationService()
    ) {
        self.request = request
        self.generator = generator
    }

    func start() async {
        guard drafts.isEmpty else { return }
        phase = .preparing
        do {
            drafts = try await generator.generate(from: request.photoData) { [weak self] index, reaction in
                await MainActor.run {
                    self?.phase = .generating(
                        completed: index,
                        total: ReactionIntent.allCases.count,
                        current: reaction
                    )
                }
            }
            phase = .reviewing
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    func retry() async {
        drafts = []
        await start()
    }

    func updateCaption(for id: UUID, caption: String) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let baseArtwork = UIImage(
            contentsOfFile: drafts[index].baseArtworkURL.path
        ) else {
            saveErrorMessage = "贴纸文字暂时无法更新，请重试。"
            return
        }
        let output = StickerRenderer.captionedArtwork(
            baseArtwork: baseArtwork,
            caption: trimmed
        )
        guard let pngData = output.pngData() else {
            saveErrorMessage = "贴纸文字暂时无法更新，请重试。"
            return
        }
        do {
            try pngData.write(
                to: drafts[index].temporaryImageURL,
                options: .atomic
            )
        } catch {
            saveErrorMessage = "贴纸文字暂时无法更新，请重试。"
            return
        }
        drafts[index].caption = trimmed
        selectedDraft = nil
    }

    func deleteDraft(id: UUID) {
        drafts.removeAll { $0.id == id }
        selectedDraft = nil
    }

    func save(to library: StickerLibrary) throws {
        isSaving = true
        defer { isSaving = false }
        do {
            let trimmedName = packName.trimmingCharacters(in: .whitespacesAndNewlines)
            try library.savePack(
                name: trimmedName.isEmpty ? "我的常用表情" : trimmedName,
                drafts: drafts
            )
            saveErrorMessage = nil
        } catch {
            saveErrorMessage = "保存失败，请确认设备还有足够空间后再试。"
            throw error
        }
    }
}
