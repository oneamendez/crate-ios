// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// One VM's settings: its CPUs and memory for the next start, its disk (fixed
/// by what was installed), and the Duo's full-width display choice. Nothing is
/// presented as live that only takes effect at boot.
struct MachineSettingsSheet: View {
    let machine: Machine

    @Environment(MachineStore.self) private var store
    @Environment(MachineRunner.self) private var runner
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hasHinge) private var hasHinge

    @State private var draft: Machine
    @State private var logURL: URL?

    init(machine: Machine) {
        self.machine = machine
        _draft = State(initialValue: machine)
    }

    private var current: Machine {
        store.machines.first { $0.id == machine.id } ?? machine
    }

    private var isRunning: Bool {
        runner.machineID == machine.id && runner.isRunning
    }

    private var maximumCPUs: Int { max(1, ProcessInfo.processInfo.activeProcessorCount - 1) }

    private var cpuChoices: [Int] {
        let choices = [1, 2, 4, 6, 8].filter { $0 <= maximumCPUs }
        return choices.isEmpty ? [1] : choices
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    AuroraContentColumn(maxWidth: 640) {
                        VStack(alignment: .leading, spacing: AuroraSpace.xl) {
                            header
                            hardware
                            storage
                            if hasHinge { displayOptions }
                            logs
                        }
                        .padding(.horizontal, AuroraSpace.lg)
                        .padding(.top, AuroraSpace.md)
                        .padding(.bottom, 38)
                    }
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(L10n.string("machine.settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Text(l10n: "common.done")
                    }
                }
            }
            .onAppear {
                draft = current
                clampCPU()
                if logURL == nil { logURL = LogExport.prepare() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            DistributionBadge(distribution: machine.distribution, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: machine.name)
                    .font(AuroraType.title)
                    .foregroundStyle(AuroraPalette.textPrimary)
                Text(verbatim: "\(machine.versionLabel) · \(machine.desktop)")
                    .font(AuroraType.subheadline)
                    .foregroundStyle(AuroraPalette.textSecondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Spacer(minLength: 0)
            AuroraStatusPill(status: isRunning ? .running : .stopped)
        }
    }

    private var hardware: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.sm) {
            AuroraSectionHeader(titleKey: "machine.settings.hardware",
                                subtitleKey: "machine.settings.hardware.subtitle",
                                eyebrowKey: nil)
            AuroraCard {
                VStack(alignment: .leading, spacing: AuroraSpace.lg) {
                    VStack(alignment: .leading, spacing: 9) {
                        Label {
                            Text(l10n: "install.config.cpu")
                        } icon: {
                            Image(systemName: "cpu")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .font(AuroraType.caption.weight(.semibold))
                        .foregroundStyle(AuroraPalette.textSecondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8, alignment: .leading)],
                                  alignment: .leading, spacing: 8) {
                            ForEach(cpuChoices, id: \.self) { value in
                                AuroraChoiceChip(label: "\(value)",
                                                 isSelected: draft.cpuCount == value) {
                                    draft.cpuCount = value
                                }
                            }
                        }
                    }

                    AuroraRule()

                    VStack(alignment: .leading, spacing: 9) {
                        Label {
                            Text(l10n: "install.config.memory")
                        } icon: {
                            Image(systemName: "memorychip")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .font(AuroraType.caption.weight(.semibold))
                        .foregroundStyle(AuroraPalette.textSecondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 8, alignment: .leading)],
                                  alignment: .leading, spacing: 8) {
                            ForEach([2, 4, 6, 8], id: \.self) { value in
                                AuroraChoiceChip(label: "\(value) GB",
                                                 isSelected: draft.memoryGB == value) {
                                    draft.memoryGB = value
                                }
                            }
                        }
                    }

                    Text(l10n: isRunning ? "machine.settings.nextStartRunning" : "machine.settings.nextStart")
                        .font(AuroraType.footnote)
                        .foregroundStyle(isRunning ? AuroraPalette.warning : AuroraPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(isRunning)
                .opacity(isRunning ? 0.66 : 1)
            }
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.sm) {
            AuroraSectionHeader(titleKey: "machine.settings.storage",
                                subtitleKey: nil,
                                eyebrowKey: nil)
            AuroraCard {
                VStack(spacing: 0) {
                    HStack {
                        Text(l10n: "machine.storage")
                            .font(AuroraType.subheadline)
                            .foregroundStyle(AuroraPalette.textSecondary)
                        Spacer(minLength: 8)
                        Text(verbatim: L10n.format("machine.storage.value",
                                                   Format.bytes(Int64(machine.diskUsedGB * 1e9)),
                                                   "\(machine.diskGB) GB"))
                            .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                            .foregroundStyle(AuroraPalette.textPrimary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .padding(.vertical, 4)
                    Text(l10n: "machine.settings.storage.note")
                        .font(AuroraType.footnote)
                        .foregroundStyle(AuroraPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
        }
    }

    private var displayOptions: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.sm) {
            AuroraSectionHeader(titleKey: "machine.settings.display",
                                subtitleKey: nil,
                                eyebrowKey: nil)
            AuroraCard {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { draft.isFullWidthInLandscape },
                        set: { draft.fullWidthInLandscape = $0 })) {
                        Text(l10n: "machine.settings.fullWidth")
                            .font(AuroraType.subheadline.weight(.semibold))
                            .foregroundStyle(AuroraPalette.textPrimary)
                    }
                    .tint(AuroraPalette.accent)
                    Text(l10n: "machine.settings.fullWidth.note")
                        .font(AuroraType.footnote)
                        .foregroundStyle(AuroraPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: AuroraSpace.sm) {
            AuroraSectionHeader(titleKey: "logs.title",
                                subtitleKey: "logs.subtitle",
                                eyebrowKey: nil)
            AuroraCard {
                if let logURL {
                    ShareLink(item: logURL) {
                        Label {
                            Text(l10n: "logs.export")
                        } icon: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .font(AuroraType.subheadline.weight(.semibold))
                        .foregroundStyle(AuroraPalette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                } else {
                    AuroraLoadingState()
                }
            }
        }
    }

    private func clampCPU() {
        if !cpuChoices.contains(draft.cpuCount) {
            draft.cpuCount = cpuChoices.last ?? 1
        }
    }

    private func save() {
        var changed = current
        changed.cpuCount = draft.cpuCount
        changed.memoryGB = draft.memoryGB
        changed.fullWidthInLandscape = draft.isFullWidthInLandscape
        store.update(changed)
        dismiss()
    }
}
