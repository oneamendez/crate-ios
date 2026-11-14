// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The floating tab bar on iPhone. It sits above the home indicator and lets
/// the aurora show through; each title is localised and follows the app's
/// writing direction.
struct AuroraTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var selectedPill
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.auroraReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                item(tab)
            }
        }
        .padding(6)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule().strokeBorder(LinearGradient(
                        colors: [.white.opacity(colorScheme == .dark ? 0.20 : 0.55),
                                 AuroraPalette.hairline],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10),
                        radius: 20, y: 8)
        }
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func item(_ tab: AppTab) -> some View {
        let isSelected = tab == selection
        return Button {
            withAnimation(reduceMotion ? nil : .auroraSnap) { selection = tab }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? tab.selectedSystemImage : tab.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(height: 20)
                Text(l10n: tab.titleKey)
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.white : AuroraPalette.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background {
                if isSelected {
                    Capsule()
                        .fill(AuroraPalette.primaryGradient)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 1))
                        .matchedGeometryEffect(id: "aurora.tab", in: selectedPill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(Text(l10n: tab.titleKey))
    }
}

/// The larger column used on iPad, and the compact one used on iPhone Duo when
/// open in portrait. It keeps the tabs in the same place as the device folds.
struct AuroraSidebar: View {
    @Binding var selection: AppTab
    var compact = false
    var onShowJIT: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.auroraReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: compact ? .center : .leading, spacing: AuroraSpace.md) {
            brand
                .padding(.top, AuroraSpace.xl)
                .padding(.horizontal, compact ? 0 : AuroraSpace.lg)

            VStack(spacing: 6) {
                ForEach(AppTab.allCases) { tab in
                    item(tab)
                }
            }
            .padding(.horizontal, compact ? 10 : AuroraSpace.sm)
            .padding(.top, AuroraSpace.sm)

            Spacer(minLength: 0)

            AuroraJITBadge(compact: compact, action: onShowJIT)
                .padding(.bottom, AuroraSpace.xl)

            if !compact {
                Text(verbatim: "AURORA EDITION")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(AuroraPalette.textTertiary)
                    .padding(.horizontal, AuroraSpace.xl)
                    .padding(.bottom, AuroraSpace.lg)
            }
        }
        .frame(width: compact ? AuroraLayout.railWidth : AuroraLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: compact ? .leading : .trailing) {
                    LinearGradient(colors: [.clear, AuroraPalette.hairline],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var brand: some View {
        if compact {
            CrateMark(size: 42)
        } else {
            CrateBrandLockup(markSize: 44, wordmarkSize: 28, showsEdition: true)
        }
    }

    private func item(_ tab: AppTab) -> some View {
        let isSelected = tab == selection
        return Button {
            withAnimation(reduceMotion ? nil : .auroraSnap) { selection = tab }
        } label: {
            Group {
                if compact {
                    VStack(spacing: 4) {
                        Image(systemName: isSelected ? tab.selectedSystemImage : tab.systemImage)
                            .font(.system(size: 19, weight: .semibold))
                        Text(l10n: tab.titleKey)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(width: 60, height: 54)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? tab.selectedSystemImage : tab.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 24)
                        Text(l10n: tab.titleKey)
                            .font(.system(.subheadline, design: .default, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                }
            }
            .foregroundStyle(isSelected ? AuroraPalette.textPrimary : AuroraPalette.textSecondary)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(LinearGradient(colors: [AuroraPalette.cyan.opacity(0.18),
                                                      AuroraPalette.violet.opacity(0.11)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(AuroraPalette.accent.opacity(0.35), lineWidth: 1)
                        }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(Text(l10n: tab.titleKey))
    }
}

/// A compact live JIT indicator. Its label says the state, so the colour is not
/// the only signal.
struct AuroraJITBadge: View {
    @Environment(JITSession.self) private var jit
    var compact = false
    var action: () -> Void

    private var isChecking: Bool { jit.isTurningOn || jit.state == .checking }
    private var color: Color {
        if isChecking { return AuroraPalette.info }
        return jit.isOn ? AuroraPalette.success : AuroraPalette.textTertiary
    }

    private var accessibilityKey: String {
        if isChecking { return "jit.badge.turningOn" }
        return jit.isOn ? "jit.badge.on" : "jit.badge.off"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isChecking {
                    ProgressView().controlSize(.mini).tint(color)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .shadow(color: color.opacity(0.7), radius: 5)
                }
                if compact {
                    Text(verbatim: "JIT")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AuroraPalette.textPrimary)
                } else {
                    Text(verbatim: "JIT")
                        .font(AuroraType.caption.weight(.semibold))
                        .foregroundStyle(AuroraPalette.textPrimary)
                    Text(l10n: jit.isOn ? "jit.badge.onShort" : "jit.badge.offShort")
                        .font(AuroraType.caption)
                        .foregroundStyle(AuroraPalette.textSecondary)
                }
            }
            .padding(.horizontal, compact ? 8 : 11)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(AuroraPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(l10n: accessibilityKey))
        .accessibilityHint(Text(l10n: "jit.badge.hint"))
    }
}
