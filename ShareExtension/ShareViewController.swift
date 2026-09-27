import ImageIO
import UIKit
import UniformTypeIdentifiers

/// "Sticker Diary" in the share sheet: hands shared images to the app.
///
/// The images go into the App Group inbox first, then the extension tries to
/// open the app so the cut-out starts right away. iOS has no public API for a
/// share extension to open its app, so if the jump fails the extension says
/// the images are waiting, and the app picks them up the next time it opens.
final class ShareViewController: UIViewController {
    private static let maxPixelSize: CGFloat = 1600

    private let card = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let doneButton = UIButton(type: .system)

    private let ink = UIColor(red: 0.34, green: 0.24, blue: 0.18, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        showWorking()

        Task { @MainActor in
            let saved = await saveSharedImages()
            guard saved > 0 else {
                showMessage(
                    title: String(localized: "没有找到图片"),
                    message: String(localized: "请分享照片或截图。"),
                    symbol: "photo.badge.exclamationmark"
                )
                return
            }
            if await openHostApp() {
                extensionContext?.completeRequest(returningItems: nil)
            } else {
                showMessage(
                    title: String(localized: "已加入贴纸日记"),
                    message: String(localized: "打开贴纸日记，会接着把它做成贴纸。"),
                    symbol: "checkmark.circle.fill"
                )
            }
        }
    }

    // MARK: - Images

    /// Loads every shared image, downsampled, and writes it to the inbox.
    private func saveSharedImages() async -> Int {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }

        var saved = 0
        for (index, provider) in providers.prefix(20).enumerated() {
            guard let data = await loadJPEG(from: provider) else { continue }
            if ShareInbox.add(data, index: index) { saved += 1 }
        }
        return saved
    }

    /// Sources hand over a file URL, raw data or a UIImage depending on the app
    /// (the screenshot editor usually sends a UIImage). Share extensions get
    /// little memory, so full-size photos are downsampled straight from disk.
    private func loadJPEG(from provider: NSItemProvider) async -> Data? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) else { return nil }

        let image: UIImage?
        switch item {
        case let url as URL:
            image = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(Self.downsample)
        case let data as Data:
            image = CGImageSourceCreateWithData(data as CFData, nil).flatMap(Self.downsample)
        case let uiImage as UIImage:
            image = Self.scaled(uiImage)
        default:
            image = nil
        }
        return image?.jpegData(compressionQuality: 0.9)
    }

    private static func downsample(_ source: CGImageSource) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func scaled(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let ratio = min(1, maxPixelSize / max(pixelWidth, pixelHeight))
        let size = CGSize(width: pixelWidth * ratio, height: pixelHeight * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Opening the app

    /// `UIApplication.open` is marked unavailable in extensions, so find the
    /// application object up the responder chain and call it through the
    /// Objective-C runtime.
    private func openHostApp() async -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: UIApplication.self), current.responds(to: selector) {
                typealias OpenURL = @convention(c) (
                    AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?
                ) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                return await withCheckedContinuation { continuation in
                    open(current, selector, ShareInbox.openURL as NSURL, NSDictionary()) { success in
                        continuation.resume(returning: success)
                    }
                }
            }
            responder = current.next
        }
        return false
    }

    // MARK: - UI

    private func buildLayout() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)

        card.backgroundColor = UIColor(red: 0.98, green: 0.96, blue: 0.93, alpha: 1)
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        iconView.tintColor = ink
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)

        spinner.color = ink

        titleLabel.font = Self.rounded(size: 19, weight: .black)
        titleLabel.textColor = ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        messageLabel.font = Self.rounded(size: 14, weight: .semibold)
        messageLabel.textColor = ink.withAlphaComponent(0.6)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var buttonConfig = UIButton.Configuration.filled()
        buttonConfig.baseBackgroundColor = ink
        buttonConfig.baseForegroundColor = .white
        buttonConfig.cornerStyle = .capsule
        buttonConfig.title = String(localized: "好")
        buttonConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 32, bottom: 12, trailing: 32)
        doneButton.configuration = buttonConfig
        doneButton.addAction(UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, iconView, titleLabel, messageLabel, doneButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.setCustomSpacing(18, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 280),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
        ])
    }

    private func showWorking() {
        spinner.startAnimating()
        spinner.isHidden = false
        iconView.isHidden = true
        titleLabel.text = String(localized: "正在打开贴纸日记…")
        messageLabel.isHidden = true
        doneButton.isHidden = true
    }

    private func showMessage(title: String, message: String, symbol: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        iconView.image = UIImage(systemName: symbol)
        iconView.isHidden = false
        titleLabel.text = title
        messageLabel.text = message
        messageLabel.isHidden = false
        doneButton.isHidden = false
    }

    private static func rounded(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
