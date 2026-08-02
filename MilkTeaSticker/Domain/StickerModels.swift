import Foundation

enum ReactionIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case received
    case okay
    case laughing
    case speechless
    case shocked
    case angry
    case wronged
    case refuse
    case please
    case thanks
    case onTheWay
    case goodNight

    var id: String { rawValue }

    var caption: String {
        switch self {
        case .received: "收到"
        case .okay: "好的"
        case .laughing: "哈哈哈"
        case .speechless: "无语"
        case .shocked: "震惊"
        case .angry: "生气"
        case .wronged: "委屈"
        case .refuse: "不要"
        case .please: "求求了"
        case .thanks: "谢谢"
        case .onTheWay: "在路上"
        case .goodNight: "晚安"
        }
    }

    var emoji: String {
        switch self {
        case .received: "✅"
        case .okay: "👌"
        case .laughing: "🤣"
        case .speechless: "😑"
        case .shocked: "😲"
        case .angry: "😤"
        case .wronged: "🥺"
        case .refuse: "🙅"
        case .please: "🙏"
        case .thanks: "💛"
        case .onTheWay: "🏃"
        case .goodNight: "🌙"
        }
    }

    var direction: String {
        switch self {
        case .received: "认真点头，双手接住消息"
        case .okay: "自信比出 OK 手势"
        case .laughing: "笑到前仰后合"
        case .speechless: "面无表情，双手抱胸"
        case .shocked: "睁大眼睛，身体后仰"
        case .angry: "鼓起脸颊，头顶冒火"
        case .wronged: "眼含泪光，低头抿嘴"
        case .refuse: "双臂交叉，明确摇头"
        case .please: "双手合十，期待恳求"
        case .thanks: "微笑鞠躬，双手送出爱心"
        case .onTheWay: "背包快跑，带运动感"
        case .goodNight: "抱着枕头安静入睡"
        }
    }
}

struct StickerDraft: Identifiable, Sendable {
    let id: UUID
    let reaction: ReactionIntent
    var caption: String
    let baseArtworkURL: URL
    let temporaryImageURL: URL
}

struct ReactionSticker: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let reaction: ReactionIntent
    var caption: String
    let imageFilename: String
    var isFavorite: Bool
}

struct StickerPack: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var stickers: [ReactionSticker]
}

struct GenerationRequest: Hashable, Identifiable {
    let id = UUID()
    let photoData: [Data]
}

enum GenerationPhase: Equatable {
    case preparing
    case generating(completed: Int, total: Int, current: ReactionIntent)
    case reviewing
    case failed(message: String)
}

protocol StickerGenerating: Sendable {
    var mode: StickerGenerationMode { get }

    func generate(
        from referencePhotoData: [Data],
        progress: @escaping (Int, ReactionIntent) async -> Void
    ) async throws -> [StickerDraft]
}

enum StickerGenerationMode: Equatable, Sendable {
    case mock
    case backend
}

extension StickerGenerating {
    var mode: StickerGenerationMode { .mock }
}
