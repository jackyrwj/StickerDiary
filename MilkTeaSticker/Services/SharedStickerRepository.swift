import Foundation

struct SharedStickerDescriptor: Codable, Hashable, Sendable {
    let id: UUID
    let caption: String
    let filename: String
}

enum SharedStickerRepository {
    static let appGroupIdentifier = "group.com.jackyrwj.PersonalSticker"
    static let manifestFilename = "sticker-manifest.json"

    static func containerURL(fileManager: FileManager = .default) throws -> URL {
        if let groupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return groupURL
        }

        guard let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return documents.appendingPathComponent("SharedStickers", isDirectory: true)
    }

    static func stickersDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = try containerURL(fileManager: fileManager)
            .appendingPathComponent("ApprovedStickers", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    static func manifestURL(fileManager: FileManager = .default) throws -> URL {
        try containerURL(fileManager: fileManager)
            .appendingPathComponent(manifestFilename)
    }
}
