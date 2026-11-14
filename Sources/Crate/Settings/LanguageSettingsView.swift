// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The language picker. Names are shown in their own writing system, as iOS's
/// own language list does. Choosing a language changes the interface at once
/// and never touches a VM's files.
struct LanguageSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.auroraReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                AuroraContentColumn(maxWidth: 680) {
                    VStack(alignment: .leading, spacing: AuroraSpace.xl) {
                        intro
                        preview
                        choices
                        note
                    }
                    .padding(.horizontal, AuroraSpace.lg)
                    .padding(.top, AuroraSpace.md)
                    .padding(.bottom, 44)
                }
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(L10n.string("language.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(l10n: "language.heading")
                .font(AuroraType.title)
                .foregroundStyle(AuroraPalette.textPrimary)
            Text(l10n: "language.subtitle")
                .font(AuroraType.body)
                .foregroundStyle(AuroraPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var preview: some View {
        AuroraCard(tint: preferences.isRightToLeft ? AuroraPalette.violet : AuroraPalette.cyan) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AuroraPalette.info)
                    Text(l10n: "language.preview")
                        .font(AuroraType.caption.weight(.semibold))
                        .foregroundStyle(AuroraPalette.info)
                    Spacer(minLength: 0)
                    Text(verbatim: currentName)
                        .font(AuroraType.caption)
                        .foregroundStyle(AuroraPalette.textTertiary)
                }
                Text(l10n: "language.sampleTitle")
                    .font(AuroraType.section)
                    .foregroundStyle(AuroraPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(l10n: "language.sampleBody")
                    .font(AuroraType.body)
                    .foregroundStyle(AuroraPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TechnicalText(value: "10.0.2.15", font: AuroraType.mono)
                    Text(verbatim: "·")
                        .foregroundStyle(AuroraPalette.textTertiary)
                    TechnicalText(value: "/home/user/project", font: AuroraType.mono)
                }
                .padding(.top, 2)
                if preferences.isRightToLeft {
                    Label {
                        Text(l10n: "language.rtlNote")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "text.alignright")
                    }
                    .font(AuroraType.footnote)
                    .foregroundStyle(AuroraPalette.violet)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.sm) {
            AuroraSectionHeader(titleKey: "language.choose",
                                subtitleKey: nil,
                                eyebrowKey: "language.choose.eyebrow")
            AuroraCard(padding: AuroraSpace.xs) {
                VStack(spacing: 0) {
                    ForEach(AppLanguage.allCases) { language in
                        row(language)
                        if language != AppLanguage.allCases[AppLanguage.allCases.count - 1] {
                            AuroraRule()
                                .padding(.horizontal, AuroraSpace.sm)
                        }
                    }
                }
            }
        }
    }

    private func row(_ language: AppLanguage) -> some View {
        let selected = preferences.language == language
        return Button {
            withAnimation(reduceMotion ? nil : .auroraSnap) { preferences.language = language }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title(for: language))
                        .font(.system(.body, design: .default, weight: .semibold))
                        .foregroundStyle(AuroraPalette.textPrimary)
                    Text(verbatim: subtitle(for: language))
                        .font(AuroraType.caption)
                        .foregroundStyle(AuroraPalette.textTertiary)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(AuroraPalette.accent)
                } else {
                    Circle()
                        .strokeBorder(AuroraPalette.textTertiary.opacity(0.45), lineWidth: 1.4)
                        .frame(width: 21, height: 21)
                }
            }
            .padding(.horizontal, AuroraSpace.sm)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(Text(verbatim: title(for: language)))
    }

    private func title(for language: AppLanguage) -> String {
        language == .system ? L10n.string("language.system") : language.nativeName
    }

    private func subtitle(for language: AppLanguage) -> String {
        if language == .system {
            return L10n.format("language.followsSystem", AppLanguage.matching().nativeName)
        }
        return language.shortCode
    }

    private var currentName: String {
        preferences.language == .system
            ? L10n.format("language.systemValue", AppLanguage.matching().nativeName)
            : preferences.language.nativeName
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(l10n: "language.dataSafe")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.shield")
            }
            .font(AuroraType.footnote)
            .foregroundStyle(AuroraPalette.success)

            Label {
                Text(l10n: "language.technical")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "terminal")
            }
            .font(AuroraType.footnote)
            .foregroundStyle(AuroraPalette.textTertiary)
        }
    }
}
