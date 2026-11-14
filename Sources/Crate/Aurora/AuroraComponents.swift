// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// MARK: - Surfaces

/// A translucent panel. The material is the surface; the gradient is only a
/// hint of light at its edge, which keeps text contrast high in both themes.
struct AuroraCard<Content: View>: View {
    var tint: Color
    var padding: CGFloat
    var cornerRadius: CGFloat
    private let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    init(tint: Color = .clear,
         padding: CGFloat = AuroraSpace.lg,
         cornerRadius: CGFloat = AuroraRadius.card,
         @ViewBuilder content: @escaping () -> Content) {
        self.tint = tint
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.white.opacity(colorScheme == .dark ? 0.055 : 0.38),
                                         tint.opacity(colorScheme == .dark ? 0.075 : 0.055),
                                         .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(LinearGradient(
                                colors: [Color.white.opacity(colorScheme == .dark ? 0.18 : 0.55),
                                         tint.opacity(0.20),
                                         AuroraPalette.hairline],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing),
                                lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.08),
                            radius: 24, y: 12)
            }
    }
}

/// A compact glass capsule, for controls that should feel placed on the photo
/// or on a gradient.
struct AuroraGlassPill<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Buttons

struct AuroraPrimaryButtonStyle: ButtonStyle {
    var fullWidth = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.auroraReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AuroraType.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 50)
            .background {
                Capsule()
                    .fill(AuroraPalette.primaryGradient)
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                    }
                    .shadow(color: AuroraPalette.cyan.opacity(isEnabled ? 0.26 : 0), radius: 18, y: 8)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.42)
            .saturation(isEnabled ? 1 : 0.35)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.975 : 1))
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct AuroraSecondaryButtonStyle: ButtonStyle {
    var fullWidth = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.auroraReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AuroraType.headline)
            .foregroundStyle(AuroraPalette.textPrimary)
            .padding(.horizontal, 18)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 48)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule().strokeBorder(LinearGradient(
                            colors: [.white.opacity(0.26), AuroraPalette.hairline],
                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.42)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.975 : 1))
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct AuroraDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AuroraType.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
            .background {
                Capsule()
                    .fill(LinearGradient(colors: [AuroraPalette.coral, Color(hex: 0xE65D6E)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .contentShape(Capsule())
    }
}

struct AuroraIconButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    @Environment(\.auroraReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(AuroraPalette.textPrimary)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.94 : 1))
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

// MARK: - Labels and metrics

/// A small, high-contrast badge for state. It always states the state in words;
/// colour is never the only signal.
struct AuroraStatusPill: View {
    let status: MachineStatus
    var compact = false

    private var color: Color { AuroraPalette.statusColor(status) }

    var body: some View {
        HStack(spacing: 5) {
            if status == .starting {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            } else {
                Image(systemName: status.systemImage)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(l10n: status.titleKey)
                .font(AuroraType.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 6)
        .background(color.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.24), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// A key and value, with the icon in the quiet part of the hierarchy.
struct AuroraMetricTile: View {
    let titleKey: String
    let value: String
    let systemImage: String
    var isTechnical = false
    var accent: Color = AuroraPalette.textSecondary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(l10n: titleKey)
                    .lineLimit(1)
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(AuroraType.caption)
            .foregroundStyle(accent)
            .labelStyle(.titleAndIcon)

            if isTechnical {
                TechnicalText(value: value, font: .system(.footnote, design: .monospaced, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            } else {
                Text(verbatim: value)
                    .font(.system(.subheadline, design: .default, weight: .semibold))
                    .foregroundStyle(AuroraPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AuroraSectionHeader: View {
    let titleKey: String
    var subtitleKey: String?
    var eyebrowKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let eyebrowKey {
                Text(l10n: eyebrowKey)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .auroraTracking(1.4)
                    .foregroundStyle(AuroraPalette.info)
            }
            Text(l10n: titleKey)
                .font(AuroraType.section)
                .foregroundStyle(AuroraPalette.textPrimary)
            if let subtitleKey {
                Text(l10n: subtitleKey)
                    .font(AuroraType.subheadline)
                    .foregroundStyle(AuroraPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Progress

/// A thin, luminous progress line. A nil value is indeterminate and uses the
/// system spinner, so progress is never invented.
struct AuroraProgressBar: View {
    let value: Double?
    var height: CGFloat = 7

    @Environment(\.auroraReduceMotion) private var reduceMotion

    private var clamped: Double {
        guard let value, value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    var body: some View {
        if value == nil {
            ProgressView()
                .tint(AuroraPalette.accent)
                .accessibilityLabel(Text(l10n: "progress.label"))
        } else {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AuroraPalette.hairline)
                    Capsule()
                        .fill(AuroraPalette.primaryGradient)
                        .frame(width: max(0, proxy.size.width * CGFloat(clamped)))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: clamped)
                }
            }
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel(Text(l10n: "progress.label"))
            .accessibilityValue(Text(verbatim: "\(Int((clamped * 100).rounded()))%"))
        }
    }
}

// MARK: - Choices

struct AuroraChoiceChip: View {
    let label: String
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.system(.subheadline, design: .default, weight: .semibold))
                .foregroundStyle(isSelected ? AuroraPalette.textPrimary : AuroraPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 15)
                .frame(minHeight: 40)
                .background {
                    ZStack {
                        if isSelected {
                            Capsule().fill(AuroraPalette.cyan.opacity(0.16))
                        } else {
                            Capsule().fill(.ultraThinMaterial)
                        }
                        Capsule().strokeBorder(isSelected ? AuroraPalette.accent.opacity(0.60) : AuroraPalette.hairline,
                                               lineWidth: isSelected ? 1.5 : 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Fields

/// A labelled input on a raised, hairline-edged surface. The field content can
/// be a TextField, SecureField, or a small HStack with a show/hide control.
struct AuroraField<Content: View>: View {
    let titleKey: String
    var systemImage: String?
    var isInvalid = false
    private let content: () -> Content

    init(titleKey: String,
         systemImage: String? = nil,
         isInvalid: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.titleKey = titleKey
        self.systemImage = systemImage
        self.isInvalid = isInvalid
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(l10n: titleKey)
            }
            .font(AuroraType.caption.weight(.semibold))
            .foregroundStyle(isInvalid ? AuroraPalette.danger : AuroraPalette.textSecondary)

            content()
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                .background(AuroraPalette.raised,
                            in: RoundedRectangle(cornerRadius: AuroraRadius.small, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AuroraRadius.small, style: .continuous)
                        .strokeBorder(isInvalid ? AuroraPalette.danger.opacity(0.55) : AuroraPalette.hairline,
                                      lineWidth: 1)
                }
        }
    }
}

// MARK: - Empty and loading

struct AuroraEmptyState: View {
    let titleKey: String
    let messageKey: String
    var actionKey: String?
    var actionSystemImage = "arrow.down.circle.fill"
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: AuroraSpace.md) {
            CrateMark(size: 76, glowing: true)
                .padding(.bottom, 4)
            Text(l10n: titleKey)
                .font(AuroraType.title)
                .foregroundStyle(AuroraPalette.textPrimary)
                .multilineTextAlignment(.center)
            Text(l10n: messageKey)
                .font(AuroraType.body)
                .foregroundStyle(AuroraPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionKey, let action {
                Button(action: action) {
                    Label {
                        Text(l10n: actionKey)
                    } icon: {
                        Image(systemName: actionSystemImage)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuroraPrimaryButtonStyle(fullWidth: true))
                .padding(.top, 6)
                .frame(maxWidth: 320)
            }
        }
        .padding(AuroraSpace.xxl)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }
}

struct AuroraLoadingState: View {
    var messageKey: String?

    var body: some View {
        VStack(spacing: AuroraSpace.sm) {
            ProgressView()
                .controlSize(.large)
                .tint(AuroraPalette.accent)
            if let messageKey {
                Text(l10n: messageKey)
                    .font(AuroraType.footnote)
                    .foregroundStyle(AuroraPalette.textSecondary)
            }
        }
        .padding(AuroraSpace.xl)
    }
}

// MARK: - Layout

/// A subtle rule that fades at both ends, so panels do not need hard borders.
struct AuroraRule: View {
    var body: some View {
        LinearGradient(colors: [.clear, AuroraPalette.hairline, .clear],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
    }
}

/// The page's content column: readable width on iPad, full width on iPhone.
struct AuroraContentColumn<Content: View>: View {
    var maxWidth: CGFloat = AuroraLayout.contentMaxWidth
    private let content: () -> Content

    init(maxWidth: CGFloat = AuroraLayout.contentMaxWidth,
         @ViewBuilder content: @escaping () -> Content) {
        self.maxWidth = maxWidth
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
