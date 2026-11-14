// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Pick a real catalog image, give it real hardware, and install it. The
/// catalog, downloads, checksums and cloud-init seed are the same engine path
/// as before; only the presentation is new.
struct InstallScreen: View {
    @Environment(MachineStore.self) private var store
    @Environment(Installer.self) private var installer
    @Environment(\.dynamicTypeSize) private var typeSize

    let onShowHome: () -> Void

    @State private var catalog = CatalogState.loading
    @State private var selectedID: String?
    @AppStorage(SettingsKey.installMemoryGB) private var memoryGB = 6
    @AppStorage(SettingsKey.installCPUCount) private var cpuCount = 4
    @AppStorage(SettingsKey.installDiskGB) private var diskGB = 32
    @State private var askingForAccount = false
    @State private var confirmingCancel = false
    @State private var didClampCPU = false

    private let memoryChoices = [4, 6, 8]
    private let diskChoices = [32, 48, 64]
    private let diskDefault = 32

    enum CatalogState {
        case loading
        case loaded([CatalogImage])
        case failed(String)
    }

    private var images: [CatalogImage] {
        if case .loaded(let images) = catalog { return images }
        return []
    }

    private var selected: CatalogImage? {
        images.first { $0.id == selectedID } ?? images.first
    }

    private var maximumCPUs: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    }

    private var cpuChoices: [Int] {
        let choices = [1, 2, 4, 6, 8].filter { $0 <= maximumCPUs }
        return choices.isEmpty ? [1] : choices
    }

    /// Nil when iOS doesn't say, in which case Install stays available.
    private var freeBytes: Int64? { Format.freeDiskBytes() }

    /// The disk as unpacked, and one part of the download beside it.
    private func neededBytes(_ image: CatalogImage) -> Int64 {
        image.installedBytes + (image.disk.parts.map(\.size).max() ?? 0)
    }

    private var hasRoom: Bool {
        guard let selected else { return false }
        return freeBytes.map { $0 >= neededBytes(selected) } ?? true
    }

    private var catalogColumns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 310,
                            maximum: 540), spacing: 14, alignment: .top)]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    AuroraContentColumn {
                        VStack(alignment: .leading, spacing: AuroraSpace.xl) {
                            pageHeader
                            catalogSection
                            if let selected {
                                configuration(for: selected)
                            }
                            installFooter
                        }
                        .padding(.horizontal, AuroraSpace.lg)
                        .padding(.top, AuroraSpace.sm)
                        .padding(.bottom, 44)
                    }
                }
                .scrollIndicators(.hidden)
                .refreshable { await loadCatalog() }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await loadCatalog()
                clampCPU()
            }
            .onAppear { clampCPU() }
            .onChange(of: selectedID) {
                if case .done = installer.phase { installer.reset() }
            }
            .sheet(isPresented: $askingForAccount) {
                if let selected {
                    AccountSheet(image: selected) { owner in
                        askingForAccount = false
                        installer.install(selected, memoryGB: memoryGB, diskGB: diskGB,
                                          cpuCount: cpuCount, owner: owner, into: store)
                    }
                }
            }
            .alert(L10n.format("install.cancel.title", installer.image?.name ?? ""),
                   isPresented: $confirmingCancel) {
                Button(role: .destructive) {
                    installer.cancel()
                } label: {
                    Text(l10n: "install.cancel.stop")
                }
                Button(role: .cancel) {} label: {
                    Text(l10n: "install.cancel.keep")
                }
            } message: {
                Text(l10n: "install.cancel.message")
            }
        }
    }

    // MARK: - Header

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n: "install.eyebrow")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .auroraTracking(1.6)
                        .foregroundStyle(AuroraPalette.info)
                    Text(l10n: "install.title")
                        .font(AuroraType.hero)
                        .foregroundStyle(AuroraPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(l10n: "install.subtitle")
                        .font(AuroraType.body)
                        .foregroundStyle(AuroraPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                CrateMark(size: 58)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Catalog

    @ViewBuilder
    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.md) {
            AuroraSectionHeader(titleKey: "install.choose.title",
                                subtitleKey: "install.choose.subtitle",
                                eyebrowKey: "install.choose.eyebrow")

            switch catalog {
            case .loading:
                AuroraCard(tint: AuroraPalette.cyan) {
                    AuroraLoadingState(messageKey: "install.catalog.loading")
                        .frame(maxWidth: .infinity)
                }
            case .failed(let message):
                AuroraCard(tint: AuroraPalette.coral) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(AuroraPalette.danger)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(l10n: "install.catalog.failed")
                                    .font(AuroraType.headline)
                                    .foregroundStyle(AuroraPalette.textPrimary)
                                Text(verbatim: message)
                                    .font(AuroraType.subheadline)
                                    .foregroundStyle(AuroraPalette.textSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Button {
                            Task { await loadCatalog() }
                        } label: {
                            Label {
                                Text(l10n: "install.tryAgain")
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(AuroraSecondaryButtonStyle())
                    }
                }
            case .loaded(let images):
                if images.isEmpty {
                    AuroraCard {
                        AuroraEmptyState(titleKey: "install.catalog.empty.title",
                                         messageKey: "install.catalog.empty.message")
                    }
                } else {
                    LazyVGrid(columns: catalogColumns, alignment: .leading, spacing: 14) {
                        ForEach(images) { image in
                            CatalogImageCard(
                                image: image,
                                isSelected: image.id == selected?.id,
                                isInstalled: store.isInstalled(image)) {
                                    selectedID = image.id
                                }
                                .disabled(installer.isBusy)
                        }
                    }
                }
            }
        }
    }

    private func loadCatalog() async {
        if case .loaded = catalog {} else { catalog = .loading }
        do {
            let fetched = try await Catalog.fetch()
            catalog = .loaded(fetched.images)
            if selectedID == nil { selectedID = fetched.images.first?.id }
        } catch {
            if case .loaded = catalog { return }
            catalog = .failed(error.localizedDescription)
        }
    }

    // MARK: - Configuration

    private func configuration(for image: CatalogImage) -> some View {
        VStack(alignment: .leading, spacing: AuroraSpace.md) {
            AuroraSectionHeader(titleKey: "install.config.title",
                                subtitleKey: nil,
                                eyebrowKey: "install.config.eyebrow")

            AuroraCard(tint: image.distribution.auroraTint) {
                VStack(alignment: .leading, spacing: AuroraSpace.lg) {
                    HStack(spacing: 12) {
                        DistributionBadge(distribution: image.distribution, size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: image.name)
                                .font(AuroraType.cardTitle)
                                .foregroundStyle(AuroraPalette.textPrimary)
                            Text(verbatim: "\(image.version) · \(image.desktop)")
                                .font(AuroraType.subheadline)
                                .foregroundStyle(AuroraPalette.textSecondary)
                                .environment(\.layoutDirection, .leftToRight)
                        }
                        Spacer(minLength: 0)
                        AuroraGlassPill {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(image.distribution.auroraTint)
                                    .frame(width: 6, height: 6)
                                Text(l10n: "install.config.selected")
                                    .font(AuroraType.caption.weight(.semibold))
                                    .foregroundStyle(AuroraPalette.textSecondary)
                            }
                        }
                    }

                    AuroraRule()

                    ChoiceRow(titleKey: "install.config.cpu",
                              systemImage: "cpu",
                              choices: cpuChoices.map { Choice(value: $0, label: "\($0)") },
                              selection: $cpuCount)
                    ChoiceRow(titleKey: "install.config.memory",
                              systemImage: "memorychip",
                              choices: memoryChoices.map { Choice(value: $0, label: "\($0) GB") },
                              selection: $memoryGB)
                    ChoiceRow(titleKey: "install.config.storage",
                              systemImage: "internaldrive",
                              choices: diskChoices.map { Choice(value: $0, label: "\($0) GB") },
                              selection: $diskGB)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(l10n: "install.config.cpuNote")
                        Text(l10n: "install.config.storageNote")
                    }
                    .font(AuroraType.footnote)
                    .foregroundStyle(AuroraPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                    if let warning = memoryWarning {
                        Label {
                            Text(verbatim: warning)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(AuroraType.footnote)
                        .foregroundStyle(AuroraPalette.warning)
                    }
                }
            }
            .disabled(installer.isBusy)
            .opacity(installer.isBusy ? 0.72 : 1)
        }
    }

    private var memoryWarning: String? {
        guard let limit = MemoryReport().limit, UInt64(memoryGB) << 30 > limit else { return nil }
        return L10n.format("install.config.memoryWarning", Format.memory(limit))
    }

    // MARK: - Install

    @ViewBuilder
    private var installFooter: some View {
        switch installer.phase {
        case .idle:
            if let selected {
                AuroraCard(tint: selected.distribution.auroraTint) {
                    VStack(alignment: .leading, spacing: AuroraSpace.md) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(l10n: "install.ready.title")
                                    .font(AuroraType.cardTitle)
                                    .foregroundStyle(AuroraPalette.textPrimary)
                                Text(verbatim: spaceNeeded(selected))
                                    .font(AuroraType.footnote)
                                    .foregroundStyle(hasRoom ? AuroraPalette.textSecondary : AuroraPalette.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        Button {
                            askingForAccount = true
                        } label: {
                            Label {
                                Text(verbatim: L10n.format("install.installNamed", selected.name))
                            } icon: {
                                Image(systemName: "arrow.down.circle.fill")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AuroraPrimaryButtonStyle(fullWidth: true))
                        .disabled(!hasRoom)
                    }
                }
            }
        case .downloading, .unpacking:
            progressCard(cancellable: true)
        case .finishing:
            progressCard(cancellable: false)
        case .done(let machine):
            AuroraCard(tint: AuroraPalette.emerald) {
                VStack(alignment: .leading, spacing: AuroraSpace.md) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(AuroraPalette.success)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: L10n.format("install.done.title", machine.name))
                                .font(AuroraType.cardTitle)
                                .foregroundStyle(AuroraPalette.textPrimary)
                            Text(l10n: "install.done.message")
                                .font(AuroraType.subheadline)
                                .foregroundStyle(AuroraPalette.textSecondary)
                        }
                    }
                    Button {
                        installer.reset()
                        onShowHome()
                    } label: {
                        Label {
                            Text(l10n: "install.done.home")
                        } icon: {
                            Image(systemName: "house.fill")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AuroraPrimaryButtonStyle(fullWidth: true))
                }
            }
        case .failed(let message):
            AuroraCard(tint: AuroraPalette.coral) {
                VStack(alignment: .leading, spacing: AuroraSpace.md) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(AuroraPalette.danger)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l10n: "install.failed.title")
                                .font(AuroraType.cardTitle)
                                .foregroundStyle(AuroraPalette.textPrimary)
                            Text(verbatim: message)
                                .font(AuroraType.subheadline)
                                .foregroundStyle(AuroraPalette.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                    Button {
                        installer.reset()
                    } label: {
                        Text(l10n: "common.dismiss")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AuroraSecondaryButtonStyle(fullWidth: true))
                }
            }
        }
    }

    private func progressCard(cancellable: Bool) -> some View {
        AuroraCard(tint: AuroraPalette.cyan) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: InstallProgressText.title(for: installer))
                            .font(AuroraType.headline)
                            .foregroundStyle(AuroraPalette.textPrimary)
                        Text(verbatim: InstallProgressText.detail(for: installer))
                            .font(AuroraType.footnote)
                            .foregroundStyle(AuroraPalette.textSecondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if let progress = InstallProgressText.progress(for: installer) {
                        Text(verbatim: "\(Int((progress * 100).rounded()))%")
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                            .foregroundStyle(AuroraPalette.info)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                AuroraProgressBar(value: InstallProgressText.progress(for: installer))
                Text(l10n: "install.keepOpen")
                    .font(AuroraType.caption)
                    .foregroundStyle(AuroraPalette.textTertiary)
                if cancellable {
                    Button(role: .destructive) {
                        confirmingCancel = true
                    } label: {
                        Text(l10n: "install.cancel.button")
                    }
                    .font(AuroraType.subheadline.weight(.semibold))
                    .foregroundStyle(AuroraPalette.danger)
                }
            }
        }
    }

    private func spaceNeeded(_ image: CatalogImage) -> String {
        let needed = neededBytes(image)
        guard let free = freeBytes else {
            return L10n.format("install.space.unknown",
                               Format.bytes(image.downloadBytes), Format.bytes(needed))
        }
        if free < needed {
            return L10n.format("install.space.short", Format.bytes(needed - free), image.name)
        }
        return L10n.format("install.space.ok",
                           Format.bytes(image.downloadBytes), Format.bytes(needed), Format.bytes(free))
    }

    private func clampCPU() {
        guard !didClampCPU else { return }
        didClampCPU = true
        if !cpuChoices.contains(cpuCount) {
            cpuCount = cpuChoices.last ?? 2
        }
        if !memoryChoices.contains(memoryGB) {
            memoryGB = memoryChoices.first ?? 4
        }
        if !diskChoices.contains(diskGB) {
            diskGB = diskDefault
        }
    }
}

// MARK: - Catalog card

struct CatalogImageCard: View {
    let image: CatalogImage
    let isSelected: Bool
    let isInstalled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            AuroraCard(tint: isSelected ? image.distribution.auroraTint : .clear, padding: AuroraSpace.md) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        DistributionBadge(distribution: image.distribution, size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(verbatim: image.name)
                                    .font(AuroraType.headline)
                                    .foregroundStyle(AuroraPalette.textPrimary)
                                    .lineLimit(1)
                                Text(verbatim: image.version)
                                    .font(.system(.caption, design: .monospaced, weight: .medium))
                                    .foregroundStyle(AuroraPalette.textTertiary)
                                    .lineLimit(1)
                                    .environment(\.layoutDirection, .leftToRight)
                            }
                            Text(verbatim: image.desktop)
                                .font(AuroraType.subheadline)
                                .foregroundStyle(AuroraPalette.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isSelected ? AnyShapeStyle(AuroraPalette.accent)
                                             : AnyShapeStyle(AuroraPalette.textTertiary.opacity(0.55)))
                    }

                    HStack(spacing: 8) {
                        Label {
                            Text(verbatim: Format.bytes(image.downloadBytes))
                        } icon: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(AuroraType.caption)
                        .foregroundStyle(AuroraPalette.textTertiary)
                        .environment(\.layoutDirection, .leftToRight)

                        if isInstalled {
                            Text(l10n: "install.installed")
                                .font(AuroraType.caption.weight(.semibold))
                                .foregroundStyle(AuroraPalette.success)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(AuroraPalette.success.opacity(0.12), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: AuroraRadius.card, style: .continuous)
                    .strokeBorder(isSelected ? image.distribution.auroraTint.opacity(0.75) : .clear,
                                  lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(Text(verbatim: "\(image.name), \(image.version), \(image.desktop)"))
    }
}

// MARK: - Configuration choices

private struct Choice: Identifiable {
    let value: Int
    let label: String
    var id: Int { value }
}

private struct ChoiceRow: View {
    let titleKey: String
    let systemImage: String
    let choices: [Choice]
    @Binding var selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label {
                Text(l10n: titleKey)
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            .font(AuroraType.caption.weight(.semibold))
            .foregroundStyle(AuroraPalette.textSecondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8, alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                ForEach(choices) { choice in
                    AuroraChoiceChip(label: choice.label,
                                     isSelected: selection == choice.value) {
                        selection = choice.value
                    }
                }
            }
        }
    }
}

// MARK: - Account

/// The account to make in the VM, asked for before installing: the user name
/// and password to sign in with, and the computer's name.
struct AccountSheet: View {
    let image: CatalogImage
    let onInstall: (SeedDisk) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var password = ""
    @State private var hostname = ""
    @State private var showsPassword = false
    @FocusState private var passwordFocused: Bool

    private var userValid: Bool { SeedDisk.isValid(user: user) }
    private var hostnameValid: Bool { SeedDisk.isValid(hostname: hostname) }

    private var canInstall: Bool {
        userValid && !password.isEmpty && hostnameValid
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    AuroraContentColumn(maxWidth: 620) {
                        VStack(alignment: .leading, spacing: AuroraSpace.xl) {
                            header
                            accountFields
                            computerFields
                            note
                            Button {
                                onInstall(SeedDisk(user: user, password: password, hostname: hostname,
                                                   timeZone: TimeZone.current.identifier,
                                                   vendorData: image.vendorData))
                            } label: {
                                Label {
                                    Text(l10n: "account.install")
                                } icon: {
                                    Image(systemName: "arrow.down.circle.fill")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AuroraPrimaryButtonStyle(fullWidth: true))
                            .disabled(!canInstall)
                        }
                        .padding(.horizontal, AuroraSpace.lg)
                        .padding(.top, AuroraSpace.md)
                        .padding(.bottom, 38)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
            }
            .navigationTitle(L10n.format("account.title", image.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(l10n: "common.cancel")
                    }
                }
            }
            .onAppear {
                if hostname.isEmpty { hostname = image.distributionID }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            DistributionBadge(distribution: image.distribution, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n: "account.eyebrow")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .auroraTracking(1.4)
                    .foregroundStyle(AuroraPalette.info)
                Text(verbatim: image.name)
                    .font(AuroraType.title)
                    .foregroundStyle(AuroraPalette.textPrimary)
                Text(l10n: "account.subtitle")
                    .font(AuroraType.subheadline)
                    .foregroundStyle(AuroraPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountFields: some View {
        AuroraCard(tint: image.distribution.auroraTint) {
            VStack(alignment: .leading, spacing: AuroraSpace.lg) {
                Text(l10n: "account.yourAccount")
                    .font(AuroraType.cardTitle)
                    .foregroundStyle(AuroraPalette.textPrimary)

                AuroraField(titleKey: "account.user",
                            systemImage: "person",
                            isInvalid: !user.isEmpty && !userValid) {
                    TextField("", text: $user, prompt: Text(l10n: "account.user.placeholder"))
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                }
                if !user.isEmpty && !userValid {
                    Text(l10n: "account.user.invalid")
                        .font(AuroraType.footnote)
                        .foregroundStyle(AuroraPalette.danger)
                }

                passwordField

                Text(l10n: "account.password.note")
                    .font(AuroraType.footnote)
                    .foregroundStyle(AuroraPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var passwordField: some View {
        AuroraField(titleKey: "account.password", systemImage: "lock") {
            HStack(spacing: 8) {
                Group {
                    if showsPassword {
                        TextField("", text: $password, prompt: Text(l10n: "account.password.placeholder"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("", text: $password, prompt: Text(l10n: "account.password.placeholder"))
                    }
                }
                .textContentType(.newPassword)
                .focused($passwordFocused)
                .environment(\.layoutDirection, .leftToRight)

                Button {
                    let wasFocused = passwordFocused
                    showsPassword.toggle()
                    if wasFocused { DispatchQueue.main.async { passwordFocused = true } }
                } label: {
                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                        .foregroundStyle(AuroraPalette.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(l10n: showsPassword ? "account.hidePassword" : "account.showPassword"))
            }
        }
    }

    private var computerFields: some View {
        AuroraCard(tint: AuroraPalette.violet) {
            VStack(alignment: .leading, spacing: AuroraSpace.lg) {
                Text(l10n: "account.computer")
                    .font(AuroraType.cardTitle)
                    .foregroundStyle(AuroraPalette.textPrimary)
                AuroraField(titleKey: "account.hostname",
                            systemImage: "desktopcomputer",
                            isInvalid: !hostname.isEmpty && !hostnameValid) {
                    TextField("", text: $hostname, prompt: Text(l10n: "account.hostname.placeholder"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                }
                if !hostname.isEmpty && !hostnameValid {
                    Text(l10n: "account.hostname.invalid")
                        .font(AuroraType.footnote)
                        .foregroundStyle(AuroraPalette.danger)
                } else {
                    Text(l10n: "account.hostname.note")
                        .font(AuroraType.footnote)
                        .foregroundStyle(AuroraPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var note: some View {
        Label {
            Text(l10n: "account.firstBoot")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(AuroraType.footnote)
        .foregroundStyle(AuroraPalette.textSecondary)
    }

}
