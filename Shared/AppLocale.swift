import Foundation

/// Language helpers shared by the app and the widget.
///
/// Chinese keeps the hand-tuned date patterns the app has always used; every
/// other language gets the system's localized template so the order and
/// punctuation look native (e.g. "Wednesday, Sep 24").
enum AppLocale {
    /// The language the UI is actually shown in (not just the device language).
    static var languageCode: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    static var isChinese: Bool {
        languageCode.hasPrefix("zh")
    }

    /// Locale matching the UI language, keeping the device's region conventions
    /// when the device language is the same.
    static var locale: Locale {
        if isChinese { return Locale(identifier: "zh_CN") }
        let current = Locale.current
        if current.language.languageCode?.identifier == Locale(identifier: languageCode).language.languageCode?.identifier {
            return current
        }
        return Locale(identifier: languageCode)
    }

    /// Chinese paragraphs start with two full-width spaces; other languages don't indent.
    static var paragraphIndent: String {
        isChinese ? "\u{3000}\u{3000}" : ""
    }

    static func dateFormatter(chinese pattern: String, template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        if isChinese {
            formatter.dateFormat = pattern
        } else {
            formatter.setLocalizedDateFormatFromTemplate(template)
        }
        return formatter
    }

    static func string(from date: Date, chinese pattern: String, template: String) -> String {
        dateFormatter(chinese: pattern, template: template).string(from: date)
    }

    /// Single-letter weekday headers, Sunday first.
    static var veryShortWeekdaySymbols: [String] {
        if isChinese { return ["日", "一", "二", "三", "四", "五", "六"] }
        let formatter = DateFormatter()
        formatter.locale = locale
        return formatter.veryShortStandaloneWeekdaySymbols
    }
}
