// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

// MARK: - Colour

extension Color {
    /// A colour with a variant for each appearance, so the light theme is as
    /// deliberate as the dark one.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(uiColor: UIColor(hex: hex, alpha: CGFloat(alpha)))
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Aurora's palette. The bright colours are atmosphere, never text: copy stays
/// on the high-contrast foreground colours so the interface remains readable.
enum AuroraPalette {
    static let midnight = Color(light: 0xF4F8FC, dark: 0x05070E)
    static let abyss = Color(light: 0xEAF0F8, dark: 0x090D18)
    static let surface = Color(light: 0xFFFFFF, dark: 0x111726)
    static let elevated = Color(light: 0xFFFFFF, dark: 0x171F31)
    static let raised = Color(light: 0xF7FAFE, dark: 0x1B2438)

    static let cyan = Color(hex: 0x63E6FF)
    static let blue = Color(hex: 0x5B8CFF)
    static let violet = Color(hex: 0xA88BFF)
    static let emerald = Color(hex: 0x55E6B4)
    static let rose = Color(hex: 0xFF87B7)
    static let amber = Color(hex: 0xFFC46B)
    static let coral = Color(hex: 0xFF8B7A)

    static let success = Color(light: 0x087A5A, dark: 0x55E6B4)
    static let info = Color(light: 0x08758F, dark: 0x63E6FF)
    static let warning = Color(light: 0x94600A, dark: 0xFFC46B)
    static let danger = Color(light: 0xB33B2E, dark: 0xFF8B7A)

    /// System controls (toggles, cursors, links) need a darker tone on a light
    /// surface than the decorative aurora cyan; the bright one is for the dark.
    static let accent = Color(light: 0x086E84, dark: 0x63E6FF)

    static let textPrimary = Color(light: 0x0A1424, dark: 0xF4F8FF)
    static let textSecondary = Color(light: 0x50617A, dark: 0xA4B2C8)
    static let textTertiary = Color(light: 0x7A889D, dark: 0x738199)
    static let hairline = Color(light: 0x0B1B2F, dark: 0xFFFFFF).opacity(0.12)
    static let glassTint = Color(light: 0xFFFFFF, dark: 0xFFFFFF)

    /// Deep enough for white button and tab labels to stay legible, while the
    /// bright palette above remains the atmosphere and the status colour.
    static let primaryGradient = LinearGradient(
        colors: [Color(hex: 0x0B7C92), Color(hex: 0x3457D5)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

    static let auroraGradient = LinearGradient(
        colors: [emerald, cyan, blue, violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

    static let wordmarkGradient = LinearGradient(
        colors: [Color(light: 0x073B4C, dark: 0xFFFFFF),
                 Color(light: 0x163B8C, dark: 0xBFF6FF),
                 Color(light: 0x5C3FA6, dark: 0xCDBFFF)],
        startPoint: .leading,
        endPoint: .trailing)

    static let subtleGradient = LinearGradient(
        colors: [cyan.opacity(0.14), violet.opacity(0.10), .clear],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

    /// The colour that says what a distribution is, without turning the card
    /// into a rainbow.
    static func tint(for distribution: Distribution) -> Color {
        switch distribution.id {
        case "debian": rose
        case "ubuntu": Color(hex: 0xFF9B6B)
        case "arch": violet
        case "omarchy": emerald
        default: cyan
        }
    }

    static func gradient(for distribution: Distribution) -> LinearGradient {
        let tint = tint(for: distribution)
        return LinearGradient(colors: [tint.opacity(0.85), blue.opacity(0.55), violet.opacity(0.35)],
                              startPoint: .topLeading,
                              endPoint: .bottomTrailing)
    }

    static func statusColor(_ status: MachineStatus) -> Color {
        switch status {
        case .running: success
        case .starting: info
        case .stopped: textTertiary
        case .failed: danger
        case .otherRunning: warning
        }
    }
}

// MARK: - Type

/// Semantic type: Dynamic Type applies to every size, and the system's own
/// Arabic and Chinese faces replace the Latin design automatically.
enum AuroraType {
    static let hero = Font.system(.largeTitle, design: .default, weight: .bold)
    static let title = Font.system(.title, design: .default, weight: .bold)
    static let section = Font.system(.title2, design: .default, weight: .semibold)
    static let cardTitle = Font.system(.title3, design: .default, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body, design: .default, weight: .regular)
    static let callout = Font.system(.callout, design: .default, weight: .regular)
    static let subheadline = Font.system(.subheadline, design: .default, weight: .regular)
    static let footnote = Font.system(.footnote, design: .default, weight: .regular)
    static let caption = Font.system(.caption, design: .default, weight: .medium)
    static let mono = Font.system(.caption, design: .monospaced, weight: .medium)
    static let monoBody = Font.system(.subheadline, design: .monospaced, weight: .regular)
    static let wordmark = Font.system(size: 42, weight: .bold, design: .rounded)
    static let splashWordmark = Font.system(size: 58, weight: .bold, design: .rounded)
}

// MARK: - Space and shape

enum AuroraSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 44
}

enum AuroraRadius {
    static let small: CGFloat = 12
    static let medium: CGFloat = 18
    static let large: CGFloat = 24
    static let card: CGFloat = 28
    static let hero: CGFloat = 34
    static let pill: CGFloat = 999
}

enum AuroraLayout {
    static let contentMaxWidth: CGFloat = 980
    static let cardMinWidth: CGFloat = 360
    static let sidebarWidth: CGFloat = 236
    static let railWidth: CGFloat = 88
}

// MARK: - Motion

extension EnvironmentValues {
    /// Reduced when the system asks for it or when crate's own animation switch
    /// is off. Every moving view reads this instead of the system flag alone.
    @Entry var auroraReduceMotion = false
}

extension Animation {
    static let auroraGlide = Animation.spring(duration: 0.55, bounce: 0.12)
    static let auroraSnap = Animation.spring(duration: 0.32, bounce: 0.08)
    static let auroraFade = Animation.easeInOut(duration: 0.35)
}

// MARK: - Distribution style

extension Distribution {
    var auroraTint: Color { AuroraPalette.tint(for: self) }
    var auroraGradient: LinearGradient { AuroraPalette.gradient(for: self) }
}

extension Machine {
    var auroraTint: Color { AuroraPalette.tint(for: distribution) }
    var auroraGradient: LinearGradient { AuroraPalette.gradient(for: distribution) }
}

// MARK: - Technical text

/// Commands, addresses and paths are laid out left-to-right even in Arabic:
/// reversing them would change what they mean. `Text(verbatim:)` keeps them
/// from being translated as well.
struct TechnicalText: View {
    let value: String
    var font: Font = AuroraType.monoBody

    var body: some View {
        Text(verbatim: value)
            .font(font)
            .environment(\.layoutDirection, .leftToRight)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
    }
}
