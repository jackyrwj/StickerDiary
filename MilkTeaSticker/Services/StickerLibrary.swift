import Foundation
import Observation

@MainActor
@Observable
final class StickerLibrary {
    private(set) var packs: [StickerPack] = []
    private(set) var lastErrorMessage: String?

    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(fileManager: FileManager = .default, loadFromDisk: Bool = true) {
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if loadFromDisk {
            load()
        }
    }

    func savePack(name: String, drafts: [StickerDraft]) throws {
        let directory = try SharedStickerRepository.stickersDirectory(fileManager: fileManager)
        var stickers: [ReactionSticker] = []

        for draft in drafts {
            let filename = "\(draft.id.uuidString).png"
            let destination = directory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: draft.temporaryImageURL, to: destination)
            stickers.append(
                ReactionSticker(
                    id: draft.id,
                    reaction: draft.reaction,
                    caption: draft.caption,
                    imageFilename: filename,
                    isFavorite: false
                )
            )
        }

        packs.insert(
            StickerPack(
                id: UUID(),
                name: name,
                createdAt: .now,
                stickers: stickers
            ),
            at: 0
        )
        try persist()
    }

    func imageURL(for sticker: ReactionSticker) -> URL? {
        try? SharedStickerRepository.stickersDirectory(fileManager: fileManager)
            .appendingPathComponent(sticker.imageFilename)
    }

    func toggleFavorite(packID: UUID, stickerID: UUID) {
        guard let packIndex = packs.firstIndex(where: { $0.id == packID }),
              let stickerIndex = packs[packIndex].stickers.firstIndex(
                where: { $0.id == stickerID }
              ) else { return }
        packs[packIndex].stickers[stickerIndex].isFavorite.toggle()
        try? persist()
    }

    func deletePack(id: UUID) {
        guard let pack = packs.first(where: { $0.id == id }) else { return }
        for sticker in pack.stickers {
            if let url = imageURL(for: sticker) {
                try? fileManager.removeItem(at: url)
            }
        }
        packs.removeAll { $0.id == id }
        try? persist()
    }

    private func load() {
        do {
            let url = try SharedStickerRepository.manifestURL(fileManager: fileManager)
            guard fileManager.fileExists(atPath: url.path) else { return }
            packs = try decoder.decode([StickerPack].self, from: Data(contentsOf: url))
        } catch {
            lastErrorMessage = "贴纸库暂时无法读取。"
        }
    }

    private func persist() throws {
        let url = try SharedStickerRepository.manifestURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(packs).write(to: url, options: .atomic)
        lastErrorMessage = nil
    }
}

extension StickerLibrary {
    static var preview: StickerLibrary {
        StickerLibrary(loadFromDisk: false)
    }
}
