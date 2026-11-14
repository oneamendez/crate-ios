// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The dashboard: brand, a welcome, the live install, and one glass card per
/// VM. Every figure comes from the store and the running engine.
struct HomeScreen: View {
    @Environment(MachineStore.self) private var store
    @Environment(MachineRunner.self) private var runner
    @Environment(Installer.self) private var installer
    @Environment(\.dynamicTypeSize) private var typeSize

    let onStart: (Machine) -> Void
    let onTerminal: (Machine) -> Void
    let onInstall: () -> Void
    let onShowJIT: () -> Void
    let onSettings: () -> Void

    @State private var dialog: HomeDialog?
    @State private var editing: Machine?

    private var greetingKey: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12: return "home.greeting.morning"
        case 12..<17: return "home.greeting.afternoon"
        case 17..<22: return "home.greeting.evening"
        default: return "home.greeting.night"
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 300 : 338,
                            maximum: 620),
                  spacing: 18, alignment: .top)]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    AuroraContentColumn {
                        VStack(alignment: .leading, spacing: AuroraSpace.xl) {
                            header
                            if installer.phase != .idle {
                                InstallActivityCard(onShowInstall: onInstall)
                            }
                            if store.machines.isEmpty {
                                AuroraCard(tint: AuroraPalette.cyan, padding: 4) {
                                    AuroraEmptyState(
                                        titleKey: "home.empty.title",
                                        messageKey: "home.empty.message",
                                        actionKey: "home.empty.action",
                                        action: onInstall)
                                }
                                .padding(.top, 4)
                            } else {
                                machines
                            }
                            footer
                        }
                        .padding(.horizontal, AuroraSpace.lg)
                        .padding(.top, AuroraSpace.sm)
                        .padding(.bottom, 42)
                    }
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog(
                L10n.format(dialog?.titleKey ?? "home.delete.title", dialog?.machine.name ?? ""),
                isPresented: Binding(get: { dialog != nil },
                                     set: { if !$0 { dialog = nil } }),
                titleVisibility: .visible,
                presenting: dialog
            ) { dialog in
                switch dialog {
                case .delete(let machine):
                    Button(role: .destructive) {
                        if runner.machineID == machine.id { runner.stop() }
                        store.delete(machine)
                    } label: {
                        Text(l10n: "home.delete.confirm")
                    }
                case .stop(let machine):
                    Button(role: .destructive) {
                        stop(machine)
                    } label: {
                        Text(l10n: "machine.stop.confirm")
                    }
                }
                Button(role: .cancel) {} label: {
                    Text(l10n: "common.cancel")
                }
            } message: { dialog in
                Text(verbatim: dialog.message)
            }
            .sheet(item: $editing) { machine in
                MachineSettingsSheet(machine: machine)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.lg) {
            HStack(spacing: AuroraSpace.sm) {
                CrateBrandLockup(markSize: 38, wordmarkSize: 25)
                Spacer(minLength: 8)
                AuroraJITBadge(compact: typeSize.isAccessibilitySize, action: onShowJIT)
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(AuroraIconButtonStyle(size: 42))
                .accessibilityLabel(Text(l10n: "home.settings.a11y"))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(l10n: greetingKey)
                    .font(AuroraType.hero)
                    .foregroundStyle(AuroraPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(l10n: "home.subtitle")
                    .font(AuroraType.body)
                    .foregroundStyle(AuroraPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: AuroraSpace.sm) {
                Button(action: onInstall) {
                    Label {
                        Text(l10n: "home.newVM")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(AuroraPrimaryButtonStyle())
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Machines

    private var machines: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.md) {
            HStack(alignment: .firstTextBaseline, spacing: AuroraSpace.sm) {
                AuroraSectionHeader(titleKey: "home.machines.title",
                                    subtitleKey: nil,
                                    eyebrowKey: "home.machines.eyebrow")
                Spacer(minLength: 0)
                Text(verbatim: "\(store.machines.count)")
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                    .foregroundStyle(AuroraPalette.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AuroraPalette.hairline, in: Capsule())
                    .accessibilityLabel(Text(l10n: "home.machines.count"))
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(store.machines) { machine in
                    let status = status(for: machine)
                    MachineCard(
                        machine: machine,
                        status: status,
                        isBusyElsewhere: status == .otherRunning,
                        onOpen: { onStart(machine) },
                        onTerminal: { onTerminal(machine) },
                        onStop: { dialog = .stop(machine) },
                        onEditSettings: { editing = machine },
                        onDelete: { dialog = .delete(machine) })
                }
            }
        }
    }

    /// Stops the VM from its card, keeping the same last-screen preview that
    /// stopping from the VM's own screen does.
    private func stop(_ machine: Machine) {
        if let image = runner.display.snapshot() {
            Task {
                if await MachinePreview.save(image, to: GuestFiles(for: machine).preview) {
                    store.previewSaved(machine)
                }
            }
        }
        runner.stop()
    }

    /// Derived from the engine's real phase, never assumed.
    private func status(for machine: Machine) -> MachineStatus {
        if runner.machineID == machine.id {
            switch runner.phase {
            case .starting: return .starting
            case .running: return .running
            case .failed(let message): return .failed(message)
            case .stopped, .idle: return .stopped
            }
        }
        return runner.isRunning ? .otherRunning : .stopped
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            AuroraRule()
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10, weight: .semibold))
                Text(l10n: "home.footer")
                    .font(AuroraType.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(AuroraPalette.textTertiary)
        }
        .padding(.top, AuroraSpace.sm)
    }
}

/// One destructive question at a time, so the two dialogs cannot compete for
/// presentation on the same view.
private enum HomeDialog {
    case delete(Machine)
    case stop(Machine)

    var machine: Machine {
        switch self {
        case .delete(let machine), .stop(let machine): machine
        }
    }

    var titleKey: String {
        switch self {
        case .delete: "home.delete.title"
        case .stop: "machine.stop.title"
        }
    }

    var message: String {
        switch self {
        case .delete(let machine):
            L10n.format("home.delete.message", Format.bytes(Int64(machine.diskUsedGB * 1e9)))
        case .stop(let machine):
            L10n.format("machine.stop.message", machine.name)
        }
    }
}

/// A quiet progress card for an install that is happening while another page
/// is showing. It reports the installer's own phase and can be opened.
struct InstallActivityCard: View {
    @Environment(Installer.self) private var installer
    let onShowInstall: () -> Void

    var body: some View {
        Button(action: onShowInstall) {
            AuroraCard(tint: AuroraPalette.cyan, padding: AuroraSpace.md) {
                HStack(spacing: AuroraSpace.md) {
                    ZStack {
                        Circle().fill(AuroraPalette.cyan.opacity(0.14)).frame(width: 42, height: 42)
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(AuroraPalette.info)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: InstallProgressText.title(for: installer))
                            .font(AuroraType.headline)
                            .foregroundStyle(AuroraPalette.textPrimary)
                            .lineLimit(1)
                        AuroraProgressBar(value: InstallProgressText.progress(for: installer), height: 5)
                        Text(verbatim: InstallProgressText.detail(for: installer))
                            .font(AuroraType.caption)
                            .foregroundStyle(AuroraPalette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AuroraPalette.textTertiary)
                        .auroraDirectional()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// One place for the installer's human-readable state, shared by Home and
/// Install.
@MainActor
enum InstallProgressText {
    static func title(for installer: Installer) -> String {
        let name = installer.image?.name ?? ""
        switch installer.phase {
        case .idle: return ""
        case .downloading: return L10n.format("install.phase.downloading", name)
        case .unpacking: return L10n.format("install.phase.unpacking", name)
        case .finishing: return L10n.format("install.phase.finishing", name)
        case .done(let machine): return L10n.format("install.phase.done", machine.name)
        case .failed: return L10n.string("install.phase.failed")
        }
    }

    static func detail(for installer: Installer) -> String {
        switch installer.phase {
        case .idle:
            return ""
        case .downloading(let done, let total):
            return L10n.format("install.phase.progress", Format.bytes(done), Format.bytes(total))
        case .unpacking(let done, let total):
            return L10n.format("install.phase.progress", Format.bytes(done), Format.bytes(total))
        case .finishing:
            return L10n.string("install.phase.finishingDetail")
        case .done:
            return L10n.string("install.phase.doneDetail")
        case .failed(let message):
            return message
        }
    }

    static func progress(for installer: Installer) -> Double? {
        switch installer.phase {
        case .downloading(let done, let total), .unpacking(let done, let total):
            return total > 0 ? Double(done) / Double(total) : nil
        default:
            return nil
        }
    }
}
