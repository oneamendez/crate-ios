// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Crate's mark: a translucent crate holding three glowing windows, one for
/// each kind of computer it can bring along. Drawn from shapes, so it stays
/// sharp at every size and follows the appearance.
struct CrateMark: View {
    var size: CGFloat = 64
    var glowing = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.255, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x15233B), Color(hex: 0x0A1322)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.255, style: .continuous)
                        .fill(LinearGradient(colors: [AuroraPalette.cyan.opacity(0.18),
                                                      AuroraPalette.violet.opacity(0.10),
                                                      .clear],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.255, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.45),
                                                              AuroraPalette.cyan.opacity(0.28),
                                                              .white.opacity(0.08)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: max(1, size * 0.012))
                }
                .shadow(color: glowing ? AuroraPalette.cyan.opacity(0.42) : .black.opacity(0.18),
                        radius: glowing ? size * 0.34 : size * 0.12,
                        y: glowing ? 0 : size * 0.06)
            glyph
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var glyph: some View {
        ZStack {
            // The crate, seen slightly from above.
            RoundedRectangle(cornerRadius: size * 0.075, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2C405F), Color(hex: 0x18263E)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.61, height: size * 0.42)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.075, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: max(1, size * 0.012))
                }
                .offset(y: size * 0.075)

            // The open rim.
            Capsule()
                .fill(LinearGradient(colors: [AuroraPalette.cyan, AuroraPalette.blue],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: size * 0.66, height: size * 0.055)
                .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: max(0.5, size * 0.006)))
                .offset(y: -size * 0.155)

            // Three windows, one per colour in the aurora.
            HStack(spacing: size * 0.045) {
                window(AuroraPalette.cyan, width: size * 0.14)
                window(AuroraPalette.violet, width: size * 0.15)
                window(AuroraPalette.emerald, width: size * 0.14)
            }
            .offset(y: -size * 0.025)

            // The crate's front slats.
            VStack(spacing: size * 0.045) {
                Capsule().fill(.white.opacity(0.22)).frame(width: size * 0.40, height: max(1, size * 0.010))
                Capsule().fill(.white.opacity(0.14)).frame(width: size * 0.31, height: max(1, size * 0.010))
            }
            .offset(y: size * 0.195)
        }
    }

    private func window(_ color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: width * 0.22, style: .continuous)
            .fill(LinearGradient(colors: [color, color.opacity(0.55)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: width, height: width * 1.18)
            .overlay {
                RoundedRectangle(cornerRadius: width * 0.22, style: .continuous)
                    .strokeBorder(.white.opacity(0.55), lineWidth: max(0.5, width * 0.05))
            }
            .shadow(color: color.opacity(0.45), radius: width * 0.28)
    }
}

/// The product name, with the optional "Aurora Edition" line. Latin in every
/// language, as a brand name is.
struct CrateWordmark: View {
    var size: CGFloat = 27
    var showsEdition = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "crate")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .tracking(size * 0.015)
                .foregroundStyle(AuroraPalette.wordmarkGradient)
                .accessibilityLabel("Crate")
            if showsEdition {
                Text(verbatim: "AURORA EDITION")
                    .font(.system(size: max(8, size * 0.25), weight: .semibold, design: .rounded))
                    .tracking(max(1, size * 0.08))
                    .foregroundStyle(AuroraPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crate, Aurora Edition")
    }
}

/// A distribution's badge: its initial on the colour that identifies it, not a
/// made-up logo for a project whose own mark is copyrighted.
struct DistributionBadge: View {
    let distribution: Distribution
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(AuroraPalette.gradient(for: distribution))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .strokeBorder(.white.opacity(0.30), lineWidth: 1)
                }
                .shadow(color: AuroraPalette.tint(for: distribution).opacity(0.28),
                        radius: size * 0.28, y: size * 0.10)
            Text(verbatim: initial)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initial: String {
        switch distribution.id {
        case "debian": "D"
        case "ubuntu": "U"
        case "arch": "A"
        case "omarchy": "O"
        default: String(distribution.name.prefix(1))
        }
    }
}

/// The brand lockup used in navigation: mark and wordmark together.
struct CrateBrandLockup: View {
    var markSize: CGFloat = 38
    var wordmarkSize: CGFloat = 25
    var showsEdition = false

    var body: some View {
        HStack(spacing: 10) {
            CrateMark(size: markSize)
            CrateWordmark(size: wordmarkSize, showsEdition: showsEdition)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crate, Aurora Edition")
    }
}
