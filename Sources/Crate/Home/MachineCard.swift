// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// One installed VM on the dashboard. The preview carries the distribution's
/// colour; everything below it is live state from the store and the engine.
struct MachineCard: View {
    let machine: Machine
    let status: MachineStatus
    let isBusyElsewhere: Bool
    let onOpen: () -> Void
    let onTerminal: () -> Void
    let onStop: () -> Void
    let onEditSettings: () -> Void
    let onDelete: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme

    private let shape = RoundedRectangle(cornerRadius: AuroraRadius.card, style: .continuous)

    private var previewHeight: CGFloat {
        typeSize.isAccessibilitySize ? 150 : 188
    }

    private var primaryKey: String {
        switch status {
        case .running: "machine.open"
        case .starting: "machine.viewStartup"
        case .failed: "machine.viewError"
        case .otherRunning: "machine.busy"
        case .stopped: "machine.start"
        }
    }

    private var primaryIcon: String {
        switch status {
        case .running: "display"
        case .starting: "hourglass"
        case .failed: "exclamationmark.triangle"
        case .otherRunning: "hourglass"
        case .stopped: "play.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
            details
        }
        .background {
            shape
                .fill(.ultraThinMaterial)
                .overlay {
                    shape.fill(LinearGradient(
                        colors: [machine.auroraTint.opacity(colorScheme == .dark ? 0.10 : 0.055),
                                 Color.white.opacity(colorScheme == .dark ? 0.025 : 0.26),
                                 .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(
                        colors: [Color.white.opacity(colorScheme == .dark ? 0.18 : 0.55),
                                 machine.auroraTint.opacity(0.20),
                                 AuroraPalette.hairline],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                }
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.10),
                radius: 22, y: 12)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            MachineScreenshot(machine: machine)
                .frame(height: previewHeight)
                .frame(maxWidth: .infinity)
                .clipped()

            LinearGradient(colors: [.black.opacity(0.02), .clear, .black.opacity(0.62)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top, spacing: AuroraSpace.sm) {
                    AuroraGlassPill {
                        HStack(spacing: 6) {
                            DistributionBadge(distribution: machine.distribution, size: 22)
                            Text(verbatim: machine.distribution.name)
                                .font(.system(.caption, design: .default, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    Spacer(minLength: 0)
                    AuroraStatusPill(status: status)
                        .padding(3)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: machine.name)
                        .font(.system(.title2, design: .default, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                    Spacer(minLength: 0)
                    Text(verbatim: machine.versionLabel)
                        .font(.system(.footnote, design: .monospaced, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .padding(16)
            // The preview is always a dark surface, so its glass and status
            // colours keep their dark-theme contrast even in Light mode.
            .environment(\.colorScheme, .dark)
        }
        .frame(height: previewHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: L10n.format("machine.card.a11y", machine.name)))
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: machine.name)
                        .font(AuroraType.cardTitle)
                        .foregroundStyle(AuroraPalette.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                    systemLine
                }
                Spacer(minLength: 0)
                moreMenu
            }

            if case .failed(let message) = status {
                errorLine(message)
            }
            if case .otherRunning = status {
                Label {
                    Text(l10n: "machine.otherRunning")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hourglass")
                }
                .font(AuroraType.footnote)
                .foregroundStyle(AuroraPalette.warning)
            }

            specs

            if status == .running {
                HostMemoryLine()
            }

            actions
        }
        .padding(AuroraSpace.lg)
    }

    private var systemLine: some View {
        HStack(spacing: 5) {
            Text(l10n: machine.distribution.family.titleKey)
            Text(verbatim: "·")
            Text(verbatim: machine.desktop)
                .environment(\.layoutDirection, .leftToRight)
            Text(verbatim: "·")
            Text(verbatim: machine.architecture)
                .environment(\.layoutDirection, .leftToRight)
        }
        .font(AuroraType.subheadline)
        .foregroundStyle(AuroraPalette.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.78)
    }

    private var specs: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .leading),
                            GridItem(.flexible(), spacing: 12, alignment: .leading)],
                  alignment: .leading, spacing: 12) {
            AuroraMetricTile(titleKey: "machine.cpu",
                             value: Self.cores(machine.cpuCount),
                             systemImage: "cpu")
            AuroraMetricTile(titleKey: "machine.memory",
                             value: Format.memory(UInt64(machine.memoryGB) << 30),
                             systemImage: "memorychip")
            AuroraMetricTile(titleKey: "machine.storage",
                             value: L10n.format("machine.storage.value",
                                                Format.bytes(Int64(machine.diskUsedGB * 1e9)),
                                                "\(machine.diskGB) GB"),
                             systemImage: "internaldrive")
            AuroraMetricTile(titleKey: "machine.desktop",
                             value: machine.desktop,
                             systemImage: "macwindow",
                             isTechnical: true,
                             accent: machine.auroraTint)
            AuroraMetricTile(titleKey: "machine.display",
                             value: machine.display,
                             systemImage: "display",
                             isTechnical: true)
            AuroraMetricTile(titleKey: "machine.lastUsed",
                             value: Format.relative(machine.lastStarted),
                             systemImage: "clock")
        }
    }

    private static func cores(_ count: Int) -> String {
        count == 1 ? L10n.string("machine.core.one") : L10n.format("machine.core.many", "\(count)")
    }

    private func errorLine(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AuroraPalette.danger)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n: "machine.error.title")
                    .font(AuroraType.caption.weight(.semibold))
                    .foregroundStyle(AuroraPalette.danger)
                Text(verbatim: message)
                    .font(AuroraType.footnote)
                    .foregroundStyle(AuroraPalette.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AuroraPalette.danger.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: AuroraRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AuroraRadius.small, style: .continuous)
                .strokeBorder(AuroraPalette.danger.opacity(0.18), lineWidth: 1)
        }
    }

    private var actions: some View {
        HStack(spacing: 9) {
            Button(action: onOpen) {
                Label {
                    Text(l10n: primaryKey)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                } icon: {
                    Image(systemName: primaryIcon)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AuroraPrimaryButtonStyle(fullWidth: true))
            .disabled(isBusyElsewhere)

            Button(action: onTerminal) {
                Image(systemName: "apple.terminal")
            }
            .buttonStyle(AuroraIconButtonStyle(size: 48))
            .disabled(isBusyElsewhere)
            .accessibilityLabel(Text(l10n: "machine.terminal.a11y"))

            if status == .running || status == .starting {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(AuroraIconButtonStyle(size: 48))
                .accessibilityLabel(Text(l10n: "machine.stop.a11y"))
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button(action: onEditSettings) {
                Label {
                    Text(l10n: "machine.edit")
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
            if status == .running || status == .starting {
                Button(role: .destructive, action: onStop) {
                    Label {
                        Text(l10n: "machine.stop")
                    } icon: {
                        Image(systemName: "stop.fill")
                    }
                }
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label {
                    Text(l10n: "machine.delete")
                } icon: {
                    Image(systemName: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AuroraPalette.textPrimary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(AuroraPalette.hairline, lineWidth: 1))
        }
        .tint(AuroraPalette.textPrimary)
        .accessibilityLabel(Text(l10n: "machine.more"))
    }
}

/// The VM's last screen, or a composed placeholder before it has one.
struct MachineScreenshot: View {
    let machine: Machine

    @State private var preview: UIImage?

    var body: some View {
        Rectangle()
            .fill(machine.auroraGradient)
            .opacity(0.38)
            .overlay {
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                } else if let name = machine.screenshot {
                    Image(name)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .task(id: machine.previewDate) {
                guard machine.previewDate != nil else { return }
                preview = await MachinePreview.load(GuestFiles(for: machine).preview)
            }
            .accessibilityLabel(Text(verbatim: L10n.format("machine.screenshot.a11y", machine.name)))
    }

    private var placeholder: some View {
        ZStack {
            Rectangle()
                .fill(machine.auroraGradient)
                .opacity(0.34)
            VStack(spacing: 10) {
                DistributionBadge(distribution: machine.distribution, size: 62)
                Text(l10n: "machine.noScreenshot")
                    .font(AuroraType.footnote)
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
    }
}

/// The process's real memory footprint, refreshed while the VM runs. It is
/// labelled as crate's memory, not presented as guest usage that iOS does not
/// expose.
struct HostMemoryLine: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let report = MemoryReport()
            if let limit = report.limit, limit > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(l10n: "machine.appMemory")
                            .font(AuroraType.caption)
                            .foregroundStyle(AuroraPalette.textSecondary)
                        Spacer(minLength: 0)
                        Text(verbatim: L10n.format("machine.appMemory.value",
                                                   Format.memory(report.footprint, decimals: 1),
                                                   Format.memory(limit, decimals: 1)))
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .foregroundStyle(AuroraPalette.textTertiary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    AuroraProgressBar(value: min(1, Double(report.footprint) / Double(limit)), height: 4)
                }
            }
        }
    }
}
