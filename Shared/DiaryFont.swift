import CoreText
import SwiftUI
import UIKit

/// Handwriting faces for the diary. All are SIL OFL fonts (licences in
/// Fonts/*-OFL.txt and Fonts/Chinese/*-OFL.txt); Gaegu is subset to Latin.
/// The Latin faces have no CJK glyphs, so each app language offers its own set.
enum DiaryHandwriting: String, CaseIterable, Identifiable {
    case patrickHand
    case caveat
    case gaegu
    case kalam
    case indieFlower
    case shadowsIntoLight
    // Chinese faces. LXGW WenKai reserves its name, so ship it unmodified (no subsetting).
    case lxgwWenKai
    case xiaolai
    case zcoolKuaiLe
    case zcoolXiaoWei
    case maShanZheng
    case longCang
    case zhiMangXing

    var id: String { rawValue }

    /// Shown in the picker in its own face; font names aren't translated.
    var displayName: String {
        switch self {
        case .patrickHand: "Patrick Hand"
        case .caveat: "Caveat"
        case .gaegu: "Gaegu"
        case .kalam: "Kalam"
        case .indieFlower: "Indie Flower"
        case .shadowsIntoLight: "Shadows Into Light"
        case .lxgwWenKai: "霞鹜文楷"
        case .xiaolai: "小赖字体"
        case .zcoolKuaiLe: "站酷快乐体"
        case .zcoolXiaoWei: "站酷小薇"
        case .maShanZheng: "马善政楷书"
        case .longCang: "龙藏体"
        case .zhiMangXing: "智莽行"
        }
    }

    fileprivate var postScriptName: String {
        switch self {
        case .patrickHand: "PatrickHand-Regular"
        case .caveat: "Caveat-Regular"
        case .gaegu: "Gaegu-Regular"
        case .kalam: "Kalam-Regular"
        case .indieFlower: "IndieFlower-Regular"
        case .shadowsIntoLight: "ShadowsIntoLight"
        case .lxgwWenKai: "LXGWWenKaiLite-Regular"
        case .xiaolai: "Xiaolai"
        case .zcoolKuaiLe: "ZCOOLKuaiLe-Regular"
        case .zcoolXiaoWei: "ZCOOLXiaoWei-Regular"
        case .maShanZheng: "MaShanZheng-Regular"
        case .longCang: "LongCang-Regular"
        case .zhiMangXing: "ZhiMangXing-Regular"
        }
    }

    fileprivate var fileName: String {
        switch self {
        case .patrickHand: "PatrickHand-Regular"
        case .caveat: "Caveat"
        case .gaegu: "Gaegu-Regular"
        case .kalam: "Kalam-Regular"
        case .indieFlower: "IndieFlower-Regular"
        case .shadowsIntoLight: "ShadowsIntoLight"
        case .lxgwWenKai: "LXGWWenKaiLite-Regular"
        case .xiaolai: "Xiaolai-Regular"
        case .zcoolKuaiLe: "ZCOOLKuaiLe-Regular"
        case .zcoolXiaoWei: "ZCOOLXiaoWei-Regular"
        case .maShanZheng: "MaShanZheng-Regular"
        case .longCang: "LongCang-Regular"
        case .zhiMangXing: "ZhiMangXing-Regular"
        }
    }

    /// Point-size multiplier so every face reads at roughly the same size as
    /// the semibold serif it replaces (they differ a lot in x-height).
    fileprivate var scale: CGFloat {
        switch self {
        case .patrickHand: 1.1
        case .caveat: 1.3
        case .gaegu: 1.4
        case .kalam: 1.0
        case .indieFlower: 1.1
        case .shadowsIntoLight: 1.05
        case .lxgwWenKai, .xiaolai, .zcoolKuaiLe, .zcoolXiaoWei, .maShanZheng: 1.0
        case .longCang: 1.1
        case .zhiMangXing: 1.05
        }
    }

    fileprivate var hasCJKGlyphs: Bool {
        switch self {
        case .patrickHand, .caveat, .gaegu, .kalam, .indieFlower, .shadowsIntoLight: false
        case .lxgwWenKai, .xiaolai, .zcoolKuaiLe, .zcoolXiaoWei, .maShanZheng, .longCang, .zhiMangXing: true
        }
    }

    /// Faces offered in the current app language.
    static var available: [DiaryHandwriting] {
        allCases.filter { $0.hasCJKGlyphs == AppLocale.isChinese }
    }

    /// Free default face for the current app language.
    static var standard: DiaryHandwriting {
        AppLocale.isChinese ? .lxgwWenKai : .patrickHand
    }

    /// Everything except each language's default face is a Pro perk.
    var isPremium: Bool { self != .patrickHand && self != .lxgwWenKai }

    func isLocked(isPro: Bool) -> Bool { isPremium && !isPro }

    /// The face actually used: falls back to the default when Pro lapses or the
    /// choice belongs to the other app language, without forgetting the choice.
    func resolved(isPro: Bool) -> DiaryHandwriting {
        isLocked(isPro: isPro) || hasCJKGlyphs != AppLocale.isChinese ? Self.standard : self
    }
}

/// Typeface for diary body text, shared by the app and the widget.
enum DiaryFont {
    /// Stored in the App Group so the widget follows the choice.
    static let selectionKey = "diaryHandwriting"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: SharedStickerStore.appGroupID) ?? .standard
    }

    private static let premiumUnlockedKey = "diaryHandwritingPremiumUnlocked"

    /// The face the user picked, even if it is currently locked.
    static var stored: DiaryHandwriting {
        defaults.string(forKey: selectionKey).flatMap(DiaryHandwriting.init(rawValue:)) ?? .standard
    }

    /// Mirrors Pro status for the widget, which can't ask StoreKit. Kept at its
    /// last value until the app learns the real status, so launch doesn't flicker.
    static var premiumUnlocked: Bool {
        get { defaults.bool(forKey: premiumUnlockedKey) }
        set { defaults.set(newValue, forKey: premiumUnlockedKey) }
    }

    /// The face actually used (see `DiaryHandwriting.resolved`).
    static var selected: DiaryHandwriting {
        stored.resolved(isPro: premiumUnlocked)
    }

    /// Chinese fonts ship only in the app bundle to keep the widget small; the
    /// widget reads them from its containing app (PlugIns/X.appex -> X.app).
    private static let fontBundles: [Bundle] = {
        let main = Bundle.main
        guard main.bundleURL.pathExtension == "appex",
              let app = Bundle(url: main.bundleURL.deletingLastPathComponent().deletingLastPathComponent())
        else { return [main] }
        return [main, app]
    }()

    private static var registered: Set<DiaryHandwriting> = []

    private static func loadedFont(_ face: DiaryHandwriting, size: CGFloat) -> UIFont? {
        if !registered.contains(face) {
            registered.insert(face)
            if let url = fontBundles.lazy.compactMap({ $0.url(forResource: face.fileName, withExtension: "ttf") }).first {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        return UIFont(name: face.postScriptName, size: size * face.scale)
    }

    static func uiFont(size: CGFloat, weight: UIFont.Weight = .semibold, handwriting: DiaryHandwriting? = nil) -> UIFont {
        let face = handwriting ?? selected
        if let font = loadedFont(face, size: size) ?? loadedFont(.standard, size: size) {
            return font
        }
        let baseDescriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        let descriptor = baseDescriptor.withDesign(.serif) ?? baseDescriptor
        return UIFont(descriptor: descriptor, size: size)
    }

    static func font(size: CGFloat, weight: UIFont.Weight = .semibold, handwriting: DiaryHandwriting? = nil) -> Font {
        Font(uiFont(size: size, weight: weight, handwriting: handwriting))
    }
}

private struct DiaryFontIDKey: EnvironmentKey {
    static let defaultValue = DiaryHandwriting.patrickHand.rawValue
}

extension EnvironmentValues {
    /// Changes when the diary face changes, so text views restyle themselves.
    var diaryFontID: String {
        get { self[DiaryFontIDKey.self] }
        set { self[DiaryFontIDKey.self] = newValue }
    }
}

extension DiaryFont {
    /// Interface text: always the language's default handwriting (Patrick Hand /
    /// LXGW WenKai), never the user's diary pick, so changing the diary font
    /// doesn't reflow the UI. The faces have one weight, so `weight` and
    /// `design` are ignored.
    static func display(size: CGFloat, weight: Font.Weight = .black, design: Font.Design = .rounded) -> Font {
        font(size: size * 1.05, handwriting: .standard)
    }
}
