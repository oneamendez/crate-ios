// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import SwiftUI

// MARK: - Language

/// Every language crate ships with. `system` follows the iPhone or iPad and
/// changes with it; the rest stay until changed.
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system
    case english = "en"
    case arabic = "ar"
    case simplifiedChinese = "zh-Hans"
    case french = "fr"

    var id: Self { self }

    /// The `.lproj` folder and `Locale` identifier, or nil for the system.
    var code: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .arabic: "ar"
        case .simplifiedChinese: "zh-Hans"
        case .french: "fr"
        }
    }

    /// Shown in the language's own writing system, as iOS's language list does.
    var nativeName: String {
        switch self {
        case .system: "" // Localised by the UI, which knows the current language.
        case .english: "English"
        case .arabic: "العربية"
        case .simplifiedChinese: "简体中文"
        case .french: "Français"
        }
    }

    var englishName: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .arabic: "Arabic"
        case .simplifiedChinese: "Chinese (Simplified)"
        case .french: "French"
        }
    }

    var isRightToLeft: Bool { self == .arabic }

    /// A compact code for the picker: ZH, not ZH-HANS.
    var shortCode: String {
        switch self {
        case .system: "AUTO"
        case .english: "EN"
        case .arabic: "AR"
        case .simplifiedChinese: "ZH"
        case .french: "FR"
        }
    }

    /// The first supported language in iOS's preference list, English if none.
    static func matching(_ preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        for identifier in preferred {
            let lower = identifier.lowercased()
            if lower.hasPrefix("ar") { return .arabic }
            if lower.hasPrefix("zh") { return .simplifiedChinese }
            if lower.hasPrefix("fr") { return .french }
            if lower.hasPrefix("en") { return .english }
        }
        return .english
    }

    /// A stored raw value or iOS's own choice, never `system` itself.
    static func resolvedCode(selection raw: String) -> String {
        let selection = AppLanguage(rawValue: raw) ?? .system
        switch selection {
        case .system: matching().code ?? "en"
        default: selection.code ?? "en"
        }
    }

    /// The display name to pair with `system` in the language picker.
    static func resolutionLabel(for selection: AppLanguage) -> String {
        selection == .system ? matching().nativeName : selection.nativeName
    }
}

// MARK: - Appearance

enum AppAppearance: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var titleKey: String {
        switch self {
        case .system: "appearance.system"
        case .light: "appearance.light"
        case .dark: "appearance.dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }
}

// MARK: - Preferences

/// The few choices that shape the whole app rather than a VM. They live in
/// UserDefaults beside crate's existing settings, so they survive launches and
/// never touch VM data.
@Observable
final class AppPreferences {
    private let defaults: UserDefaults

    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: SettingsKey.appLanguage) }
    }

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: SettingsKey.appAppearance) }
    }

    var animationsEnabled: Bool {
        didSet { defaults.set(animationsEnabled, forKey: SettingsKey.appAnimations) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: SettingsKey.appLanguage) ?? "") ?? .system
        appearance = AppAppearance(rawValue: defaults.string(forKey: SettingsKey.appAppearance) ?? "") ?? .system
        if defaults.object(forKey: SettingsKey.appAnimations) == nil {
            animationsEnabled = true
        } else {
            animationsEnabled = defaults.bool(forKey: SettingsKey.appAnimations)
        }
    }

    /// The language actually in use: `system` has already become one of the four.
    var resolvedLanguageCode: String {
        language.code ?? AppLanguage.matching().code ?? "en"
    }

    var resolvedLanguage: AppLanguage {
        AppLanguage(rawValue: resolvedLanguageCode) ?? .english
    }

    var locale: Locale { Locale(identifier: resolvedLanguageCode) }

    var layoutDirection: LayoutDirection {
        L10n.isRightToLeft(languageCode: resolvedLanguageCode) ? .rightToLeft : .leftToRight
    }

    var isRightToLeft: Bool { layoutDirection == .rightToLeft }

    /// A translation in the selected language, for strings built in code rather
    /// than by SwiftUI's `LocalizedStringKey`.
    func string(_ key: String) -> String {
        L10n.string(key, languageCode: resolvedLanguageCode)
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        L10n.format(key, languageCode: resolvedLanguageCode, arguments: arguments)
    }

    /// Whether motion should be limited. The system setting always wins; crate's
    /// switch can only reduce motion further.
    func reducesMotion(system: Bool) -> Bool {
        system || !animationsEnabled
    }
}

// MARK: - Localisation

/// Localisation by native `.strings` files, with an explicit bundle so that a
/// language chosen in Settings takes effect immediately rather than after a
/// relaunch. SwiftUI text uses the locale environment; strings assembled in
/// code use this helper.
enum L10n {
    static func isRightToLeft(languageCode: String) -> Bool {
        languageCode.lowercased().hasPrefix("ar")
    }

    /// The selected language's code, resolving `system` through iOS.
    static var languageCode: String {
        AppLanguage.resolvedCode(
            selection: UserDefaults.standard.string(forKey: SettingsKey.appLanguage) ?? AppLanguage.system.rawValue)
    }

    static var locale: Locale { Locale(identifier: languageCode) }
    static var layoutDirection: LayoutDirection {
        isRightToLeft(languageCode: languageCode) ? .rightToLeft : .leftToRight
    }

    static func string(_ key: String, languageCode: String? = nil) -> String {
        let code = languageCode ?? self.languageCode
        if let value = lookup(key, languageCode: code) { return value }
        if code != "en", let value = lookup(key, languageCode: "en") { return value }
        return key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, languageCode: languageCode, arguments: arguments)
    }

    static func format(_ key: String, languageCode: String, arguments: [CVarArg]) -> String {
        let template = string(key, languageCode: languageCode)
        return String(format: template, locale: Locale(identifier: languageCode), arguments: arguments)
    }

    private static func lookup(_ key: String, languageCode: String) -> String? {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        return value == key ? nil : value
    }
}

// MARK: - Small SwiftUI conveniences

extension Text {
    /// A translated string by key, resolved through SwiftUI's locale so it
    /// follows the language picker live.
    init(l10n key: String) {
        self.init(LocalizedStringKey(key))
    }
}

extension View {
    /// Copy that follows the app's writing direction.
    func auroraTextAlignment() -> some View {
        multilineTextAlignment(.leading)
    }

    /// Keeps an icon that points somewhere pointing the right way in Arabic.
    func auroraDirectional() -> some View {
        flipsForRightToLeftLayoutDirection(true)
    }

    /// Letter spacing for small Latin eyebrow labels. Arabic joining is harmed
    /// by tracking, so it is switched off in a right-to-left layout.
    func auroraTracking(_ amount: CGFloat) -> some View {
        modifier(AuroraTracking(amount: amount))
    }
}

private struct AuroraTracking: ViewModifier {
    @Environment(\.layoutDirection) private var layoutDirection
    let amount: CGFloat

    func body(content: Content) -> some View {
        content.tracking(layoutDirection == .rightToLeft ? 0 : amount)
    }
}
