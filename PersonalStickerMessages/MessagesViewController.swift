import Messages
import UIKit

final class MessagesViewController: MSMessagesAppViewController {
    private let stickerBrowser = DynamicStickerBrowserViewController(stickerSize: .regular)

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(stickerBrowser)
        stickerBrowser.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stickerBrowser.view)
        NSLayoutConstraint.activate([
            stickerBrowser.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stickerBrowser.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stickerBrowser.view.topAnchor.constraint(equalTo: view.topAnchor),
            stickerBrowser.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        stickerBrowser.didMove(toParent: self)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        stickerBrowser.reloadStickers()
    }
}

private final class DynamicStickerBrowserViewController: MSStickerBrowserViewController {
    private var stickers: [MSSticker] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        reloadStickers()
    }

    func reloadStickers() {
        stickers = loadStickers()
        stickerBrowserView.reloadData()
    }

    override func numberOfStickers(in stickerBrowserView: MSStickerBrowserView) -> Int {
        stickers.count
    }

    override func stickerBrowserView(
        _ stickerBrowserView: MSStickerBrowserView,
        stickerAt index: Int
    ) -> MSSticker {
        stickers[index]
    }

    private func loadStickers() -> [MSSticker] {
        let fileManager = FileManager.default
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.jackyrwj.PersonalSticker"
        ) else { return [] }

        let manifestURL = container.appendingPathComponent("sticker-manifest.json")
        let imageDirectory = container.appendingPathComponent("ApprovedStickers", isDirectory: true)
        guard let data = try? Data(contentsOf: manifestURL),
              let packs = try? JSONDecoder().decode([ExtensionStickerPack].self, from: data) else {
            return []
        }

        return packs.flatMap(\.stickers).compactMap { sticker in
            let url = imageDirectory.appendingPathComponent(sticker.imageFilename)
            return try? MSSticker(contentsOfFileURL: url, localizedDescription: sticker.caption)
        }
    }
}

private struct ExtensionStickerPack: Decodable {
    let stickers: [ExtensionSticker]
}

private struct ExtensionSticker: Decodable {
    let caption: String
    let imageFilename: String
}
