// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

/// Personalisation, JIT, memory, motion, logs and the project's credits, on one
/// calm page. The language picker sits first, where it is easy to find.
struct SettingsScreen: View {
    @Environment(JITSession.self) private var jit
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.auroraReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @AppStorage(SettingsKey.jitMethod) private var jitMethod = JITMethod.standard.rawValue
    @AppStorage(SettingsKey.jitAtLaunch) private var jitAtLaunch = true
    @AppStorage(SettingsKey.codeRegionMB) private var codeRegionMB = CodeRegion.standard

    @State private var memory = MemoryReport()
    @State private var logURL: URL?

    private var selectedMethod: JITMethod {
        JITMethod(rawValue: jitMethod) ?? .standard
    }

    private var languageValue: String {
        if preferences.language == .system {
            return L10n.format("language.systemValue", AppLanguage.matching().nativeName)
        }
        return preferences.language.nativeName
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    AuroraContentColumn {
                        VStack(alignment: .leading, spacing: AuroraSpace.xl) {
                            header
                            personalisationSection
                            jitSection
                            memorySection
                            motionSection
                            logsSection
                            aboutSection
                            footer
                        }
                        .padding(.horizontal, AuroraSpace.lg)
                        .padding(.top, AuroraSpace.sm)
                        .padding(.bottom, 44)
                    }
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await refreshMemory() }
            .onAppear { logURL = LogExport.prepare() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(l10n: "settings.eyebrow")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .auroraTracking(1.6)
                    .foregroundStyle(AuroraPalette.info)
                Text(l10n: "settings.title")
                    .font(AuroraType.hero)
                    .foregroundStyle(AuroraPalette.textPrimary)
                Text(l10n: "settings.subtitle")
                    .font(AuroraType.body)
                    .foregroundStyle(AuroraPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            CrateMark(size: 58)
                .padding(.top, 6)
        }
        .padding(.top, 6)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            AuroraRule()
            HStack(spacing: 6) {
                Text(verbatim: "crate")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                Text(verbatim: "·")
                Text(l10n: "settings.footer")
                    .font(AuroraType.caption)
            }
            .foregroundStyle(AuroraPalette.textTertiary)
        }
        .padding(.top, AuroraSpace.sm)
    }

    // MARK: - Personalisation

    private var personalisationSection: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.sm) {
            AuroraSectionHeader(titleKey: "settings.personalisation",
                                subtitleKey: nil,
                                eyebrowKey: "settings.personalisation.eyebrow")
            AuroraCard {
                VStack(spacing: 0) {
                    NavigationLink {
                        LanguageSettingsView()
                    } label: {
                        rowLabel(icon: "globe",
                                 tint: AuroraPalette.cyan,
                                 titleKey: "language.title",
                                 subtitleKey: "language.settings.subtitle") {
                            HStack(spacing: 8) {
                                Text(verbatim: languageValue)
                                    .font(AuroraType.footnote.weight(.semibold))
                                    .foregroundStyle(AuroraPalette.textSecondary)
                                    .lineLimit(1)
                                Image(systemName: "chevron.forward")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(AuroraPalette.textTertiary)
                                    .auroraDirectional()
                            }
                        }
                        .padding(.vertical, AuroraSpace.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.language")

                    AuroraRule()

                    VStack(alignment: .leading, spacing: 12) {
                        rowLabel(icon: "circle.lefthalf.filled",
                                 tint: AuroraPalette.violet,
                                 titleKey: "appearance.title",
                                 subtitleKey: "appearance.subtitle")
                        appearancePicker
                    }
                    .padding(.top, AuroraSpace.md)
                }
            }
        }
    }

    private var appearancePicker: some View {
        HStack(spacing: 6) {
            ForEach(AppAppearance.allCases) { option in
                let selected = preferences.appearance == option
                Button {
                    withAnimation(reduceMotion ? nil : .auroraSnap) { preferences.appearance = option }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: option.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                        Text(l10n: option.titleKey)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selected ? AuroraPalette.textPrimary : AuroraPalette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: AuroraRadius.small, style: .continuous)
                            .fill(selected ? AuroraPalette.cyan.opacity(0.14) : Color.clear)
                            .overlay {
                                RoundedRectangle(cornerRadius: AuroraRadius.small, style: .continuous)
                                    .strokeBorder(selected ? AuroraPalette.accent.opacity(0.55) : AuroraPalette.hairline,
                                                  lineWidth: 1)
                            }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: AuroraRadius.small, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: - JIT

    private var jitSection: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.sm) {
            AuroraSectionHeader(titleKey: "settings.jit",
                                subtitleKey: nil,
                                eyebrowKey: "settings.jit.eyebrow")
            AuroraCard {
                VStack(spacing: AuroraSpace.md) {
                    HStack(spacing: 12) {
                        rowLabel(icon: "bolt.fill",
                                 tint: AuroraPalette.amber,
                                 titleKey: "jit.status.title",
                                 subtitleKey: "jit.status.subtitle")
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            if jit.isTurningOn || jit.state == .checking {
                                ProgressView().controlSize(.mini)
                            } else {
                                Circle()
                                    .fill(jitStatusColor)
                                    .frame(width: 8, height: 8)
                            }
                            Text(verbatim: jitStatusText)
                                .font(AuroraType.footnote.weight(.semibold))
                                .foregroundStyle(AuroraPalette.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }

                    if !jit.isOn {
                        Button {
                            Task { await jit.turnOn(selectedMethod) }
                        } label: {
                            if jit.isTurningOn {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label {
                                    Text(l10n: "jit.turnOn")
                                } icon: {
                                    Image(systemName: "bolt.fill")
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(AuroraPrimaryButtonStyle(fullWidth: true))
                        .disabled(jit.isTurningOn || jit.state == .checking || jit.state == .off(.notEligible))
                    }

                    AuroraRule()

                    VStack(alignment: .leading, spacing: 9) {
                        Text(l10n: "jit.method")
                            .font(AuroraType.caption.weight(.semibold))
                            .foregroundStyle(AuroraPalette.textSecondary)
                        HStack(spacing: 8) {
                            ForEach(JITMethod.allCases) { method in
                                AuroraChoiceChip(label: L10n.string(method.titleKey),
                                                 isSelected: selectedMethod == method) {
                                    jitMethod = method.rawValue
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if selectedMethod == .builtInStikJIT {
                        AuroraRule()
                        Button {
                            jit.showingSetup = true
                        } label: {
                            rowLabel(icon: "checklist",
                                     tint: AuroraPalette.cyan,
                                     titleKey: "jit.setUp",
                                     subtitleKey: "jit.setUp.subtitle") {
                                HStack(spacing: 6) {
                                    Text(l10n: jit.isPaired ? "jit.paired" : "jit.notSetUp")
                                        .font(AuroraType.footnote.weight(.semibold))
                                        .foregroundStyle(jit.isPaired ? AuroraPalette.success : AuroraPalette.textSecondary)
                                    Image(systemName: "chevron.forward")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(AuroraPalette.textTertiary)
                                        .auroraDirectional()
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    AuroraRule()

                    HStack(spacing: 12) {
                        rowLabel(icon: "power",
                                 tint: AuroraPalette.emerald,
                                 titleKey: "jit.atLaunch",
                                 subtitleKey: "jit.atLaunch.subtitle")
                        Spacer(minLength: 0)
                        Toggle("", isOn: $jitAtLaunch)
                            .labelsHidden()
                            .tint(AuroraPalette.accent)
                            .accessibilityLabel(Text(l10n: "jit.atLaunch"))
                    }

                    AuroraRule()

                    Menu {
                        ForEach(CodeRegion.choices, id: \.self) { mb in
                            Button {
                                codeRegionMB = mb
                            } label: {
                                Text(verbatim: "\(mb) MB")
                            }
                        }
                    } label: {
                        rowLabel(icon: "cpu",
                                 tint: AuroraPalette.violet,
                                 titleKey: "jit.region",
                                 subtitleKey: "jit.region.subtitle") {
                            HStack(spacing: 6) {
                                Text(verbatim: "\(codeRegionMB) MB")
                                    .font(.system(.footnote, design: .monospaced, weight: .semibold))
                                    .foregroundStyle(AuroraPalette.textSecondary)
                                    .environment(\.layoutDirection, .leftToRight)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(AuroraPalette.textTertiary)
                            }
                        }
                    }
                    .tint(AuroraPalette.textPrimary)

                    Text(verbatim: jitFooter)
                        .font(AuroraType.footnote)
                        .foregroundStyle(AuroraPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var jitStatusText: String {
        switch jit.state {
        case .checking: return L10n.string("jit.status.checking")
        case .on(let mb): return L10n.format("jit.status.on", "\(mb)")
        case .off where jit.isOn: return L10n.string("jit.status.pretend")
        case .off: return L10n.string("jit.status.off")
        case .failed: return L10n.string("jit.status.failed")
        }
    }

    private var jitStatusColor: Color {
        switch jit.state {
        case .on: return AuroraPalette.success
        case .failed: return AuroraPalette.danger
        case .off where jit.isOn: return AuroraPalette.success
        case .checking, .off: return AuroraPalette.textTertiary
        }
    }

    private var jitFooter: String {
        var parts: [String] = []
        if let problem = jit.problem { parts.append(problem) }
        switch selectedMethod {
        case .builtInStikJIT:
            parts.append(L10n.string("jit.footer.builtIn"))
        case .stikDebug:
            parts.append(L10n.string("jit.footer.stikDebug"))
        }
        parts.append(L10n.string("jit.footer.general"))
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.sm) {
            AuroraSectionHeader(titleKey: "settings.memory",
                                subtitleKey: nil,
                                eyebrowKey: "settings.memory.eyebrow")
            AuroraCard {
                VStack(spacing: 0) {
                    valueRow(titleKey: "memory.increasedLimit",
                             value: memory.hasIncreasedLimit ? L10n.string("common.yes") : L10n.string("common.no"))
                    AuroraRule()
                    valueRow(titleKey: "memory.limit",
                             value: memory.limit.map { Format.memory($0) } ?? L10n.string("memory.notReported"))
                    AuroraRule()
                    valueRow(titleKey: "memory.available",
                             value: memory.available.map { Format.memory($0, decimals: 2) } ?? L10n.string("memory.notReported"),
                             animates: true)
                    AuroraRule()
                    valueRow(titleKey: "memory.footprint", value: Format.memory(memory.footprint, decimals: 1))
                    AuroraRule()
                    valueRow(titleKey: "memory.total", value: Format.memory(memory.physical))

                    Text(verbatim: memoryFooter)
                        .font(AuroraType.footnote)
                        .foregroundStyle(AuroraPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, AuroraSpace.md)
                }
            }
        }
    }

    private var memoryFooter: String {
        memory.available == nil
            ? L10n.string("memory.footer.simulator")
            : L10n.string("memory.footer.device")
    }

    private func valueRow(titleKey: String, value: String, animates: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(l10n: titleKey)
                .font(AuroraType.subheadline)
                .foregroundStyle(AuroraPalette.textSecondary)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                .foregroundStyle(AuroraPalette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .environment(\.layoutDirection, .leftToRight)
                .contentTransition(animates ? .numericText() : .identity)
        }
        .padding(.vertical, 9)
    }

    private func refreshMemory() async {
        while !Task.isCancelled {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                memory = MemoryReport()
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    // MARK: - Motion and accessibility

    private var motionSection: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.sm) {
            AuroraSectionHeader(titleKey: "settings.motion",
                                subtitleKey: nil,
                                eyebrowKey: "settings.motion.eyebrow")
            AuroraCard {
                VStack(spacing: AuroraSpace.md) {
                    HStack(spacing: 12) {
                        rowLabel(icon: "sparkles",
                                 tint: AuroraPalette.cyan,
                                 titleKey: "motion.animations",
                                 subtitleKey: "motion.animations.subtitle")
                        Spacer(minLength: 0)
                        Toggle("", isOn: Binding(
                            get: { preferences.animationsEnabled },
                            set: { preferences.animationsEnabled = $0 }))
                            .labelsHidden()
                            .tint(AuroraPalette.accent)
                            .accessibilityLabel(Text(l10n: "motion.animations"))
                    }

                    AuroraRule()

                    HStack(spacing: 12) {
                        rowLabel(icon: "figure.walk",
                                 tint: AuroraPalette.violet,
                                 titleKey: "motion.systemReduction",
                                 subtitleKey: "motion.systemReduction.subtitle")
                        Spacer(minLength: 0)
                        Text(l10n: systemReduceMotion ? "motion.on" : "motion.off")
                            .font(AuroraType.footnote.weight(.semibold))
                            .foregroundStyle(systemReduceMotion ? AuroraPalette.success : AuroraPalette.textSecondary)
                    }

                    AuroraRule()

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        rowLabel(icon: "gearshape",
                                 tint: AuroraPalette.emerald,
                                 titleKey: "a11y.settings",
                                 subtitleKey: "a11y.settings.subtitle") {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AuroraPalette.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Logs

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.sm) {
            AuroraSectionHeader(titleKey: "logs.title",
                                subtitleKey: "logs.subtitle",
                                eyebrowKey: nil)
            AuroraCard {
                if let logURL {
                    ShareLink(item: logURL) {
                        rowLabel(icon: "square.and.arrow.up",
                                 tint: AuroraPalette.cyan,
                                 titleKey: "logs.export",
                                 subtitleKey: "logs.export.subtitle") {
                            Image(systemName: "chevron.forward")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AuroraPalette.textTertiary)
                                .auroraDirectional()
                        }
                        .padding(.vertical, AuroraSpace.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    AuroraLoadingState()
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.sm) {
            AuroraSectionHeader(titleKey: "settings.about",
                                subtitleKey: nil,
                                eyebrowKey: "settings.about.eyebrow")
            AuroraCard(tint: AuroraPalette.violet) {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        CrateMark(size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            CrateWordmark(size: 26, showsEdition: true)
                            Text(verbatim: L10n.format("about.version", version, build))
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                                .foregroundStyle(AuroraPalette.textTertiary)
                                .environment(\.layoutDirection, .leftToRight)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, AuroraSpace.md)

                    AuroraRule()

                    Link(destination: URL(string: "https://github.com/oneamendez/crate-ios")!) {
                        rowLabel(icon: "chevron.left.forwardslash.chevron.right",
                                 tint: AuroraPalette.cyan,
                                 titleKey: "about.repository",
                                 subtitleKey: "about.repository.subtitle") {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AuroraPalette.textTertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    AuroraRule()

                    Link(destination: URL(string: "https://github.com/oneamendez/crate-ios#readme")!) {
                        rowLabel(icon: "book",
                                 tint: AuroraPalette.emerald,
                                 titleKey: "about.docs",
                                 subtitleKey: "about.docs.subtitle") {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AuroraPalette.textTertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    AuroraRule()

                    NavigationLink {
                        AcknowledgementsScreen()
                    } label: {
                        rowLabel(icon: "doc.text",
                                 tint: AuroraPalette.rose,
                                 titleKey: "about.licenses",
                                 subtitleKey: "about.licenses.subtitle") {
                            Image(systemName: "chevron.forward")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AuroraPalette.textTertiary)
                                .auroraDirectional()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    Text(l10n: "about.licenseFooter")
                        .font(AuroraType.footnote)
                        .foregroundStyle(AuroraPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, AuroraSpace.md)
                }
            }
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowLabel<Trailing: View>(icon: String,
                                          tint: Color,
                                          titleKey: String,
                                          subtitleKey: String?,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n: titleKey)
                    .font(AuroraType.subheadline.weight(.semibold))
                    .foregroundStyle(AuroraPalette.textPrimary)
                if let subtitleKey {
                    Text(l10n: subtitleKey)
                        .font(AuroraType.caption)
                        .foregroundStyle(AuroraPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rowLabel(icon: String,
                          tint: Color,
                          titleKey: String,
                          subtitleKey: String?) -> some View {
        rowLabel(icon: icon, tint: tint, titleKey: titleKey, subtitleKey: subtitleKey) {
            EmptyView()
        }
    }
}
