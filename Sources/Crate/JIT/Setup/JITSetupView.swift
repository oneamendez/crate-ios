// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UniformTypeIdentifiers

/// "Set Up JIT": the steps Built-in StikJIT needs, each with its status and
/// the action that gets it, then Turn On JIT.
struct JITSetupView: View {
    @Environment(JITSession.self) private var jit
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var setup = JITSetup()
    @State private var importing = false
    @State private var confirmingForget = false

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                Form {
                    intro
                    pairingSection
                    vpnSection
                    diskImageSection
                    turnOnSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(L10n.string("jit.setup.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(l10n: "common.done")
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data, .item]) {
                setup.importFile($0)
            }
            .task { await setup.checkTunnel() }
            .onChange(of: scenePhase) {
                AppLog.write("jit: setup: crate is \(scenePhase == .active ? "in front" : scenePhase == .background ? "in the background" : "inactive")")
                // Back from LocalDevVPN or Settings.
                if scenePhase == .active {
                    setup.returnedToFront()
                    Task { await setup.checkTunnel() }
                }
            }
            .onDisappear {
                setup.cancelPairing()
                jit.pairingChanged()
            }
        }
    }

    private var rowBackground: Color {
        AuroraPalette.surface.opacity(0.76)
    }

    private var intro: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                CrateMark(size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n: "jit.setup.hero")
                        .font(AuroraType.cardTitle)
                        .foregroundStyle(AuroraPalette.textPrimary)
                    Text(l10n: "jit.setup.hero.body")
                        .font(AuroraType.footnote)
                        .foregroundStyle(AuroraPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - 1. Pairing

    private var pairingSection: some View {
        Section {
            StepStatus(titleKey: "jit.thisIPhone", done: setup.hasPairingFile,
                       status: setup.hasPairingFile ? L10n.string("jit.paired") : L10n.string("jit.notPaired"))
            switch setup.pairing {
            case .idle:
                if setup.canPairOnDevice {
                    Button {
                        setup.startPairing()
                    } label: {
                        Label {
                            Text(l10n: setup.hasPairingFile ? "jit.pairAgain" : "jit.pairThisIPhone")
                        } icon: {
                            Image(systemName: "link")
                        }
                    }
                }
            case .starting:
                HStack {
                    Text(l10n: "jit.pairing.starting")
                    Spacer()
                    ProgressView()
                }
            case .showing(let code, _):
                pairingInProgress(code: code)
            case .failed(let message):
                Text(verbatim: message)
                    .foregroundStyle(AuroraPalette.danger)
                Button {
                    setup.startPairing()
                } label: {
                    Label {
                        Text(l10n: "jit.tryAgain")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            Button {
                importing = true
            } label: {
                Label {
                    Text(l10n: "jit.usePairingFile")
                } icon: {
                    Image(systemName: "doc.badge.plus")
                }
            }
            if setup.hasPairingFile && setup.pairing == .idle {
                Button(role: .destructive) {
                    confirmingForget = true
                } label: {
                    Label {
                        Text(l10n: "jit.forgetPairing")
                    } icon: {
                        Image(systemName: "link.badge.minus")
                    }
                }
                .confirmationDialog(
                    L10n.string("jit.forget.title"),
                    isPresented: $confirmingForget,
                    titleVisibility: .visible
                ) {
                    Button(role: .destructive) {
                        setup.forgetPairing()
                    } label: {
                        Text(l10n: "jit.forget.confirm")
                    }
                    Button(role: .cancel) {} label: {
                        Text(l10n: "common.cancel")
                    }
                } message: {
                    Text(l10n: "jit.forget.message")
                }
            }
            if let importError = setup.importError {
                Text(verbatim: importError)
                    .foregroundStyle(AuroraPalette.danger)
            }
        } header: {
            Text(l10n: "jit.step1")
        } footer: {
            Text(verbatim: pairingFooter)
                .foregroundStyle(AuroraPalette.textTertiary)
        }
        .listRowBackground(rowBackground)
    }

    /// The code card, which is also what floats over Settings, kept small,
    /// with Open Settings right under it.
    @ViewBuilder
    private func pairingInProgress(code: String) -> some View {
        PairingCodeView(pictureInPicture: setup.pictureInPicture)
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxHeight: 120)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: L10n.format("jit.pairing.codeA11y",
                                                           code.map(String.init).joined(separator: " "))))
        Button {
            setup.openSettings()
        } label: {
            Label {
                Text(l10n: "jit.openSettings")
            } icon: {
                Image(systemName: "gear")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuroraPrimaryButtonStyle(fullWidth: true))
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        Button(role: .cancel) {
            setup.cancelPairing()
        } label: {
            Text(l10n: "jit.cancelPairing")
        }
    }

    private var pairingFooter: String {
        switch setup.pairing {
        case .showing(let code, true):
            return L10n.format("jit.pair.footer.settingsCode", PairingCodePictureInPicture.spaced(code))
        case .showing:
            return L10n.string("jit.pair.footer.settings")
        default:
            return setup.canPairOnDevice
                ? L10n.string("jit.pair.footer.onDevice")
                : L10n.string("jit.pair.footer.file")
        }
    }

    // MARK: - 2. LocalDevVPN

    private var vpnSection: some View {
        Section {
            StepStatus(titleKey: "jit.localdevvpn", done: setup.tunnel == .up, status: tunnelStatus)
            if setup.tunnel != .up {
                Button {
                    setup.connectVPN()
                } label: {
                    Label {
                        Text(l10n: LocalDevVPN.isInstalled ? "jit.connectVPN" : "jit.getVPN")
                    } icon: {
                        Image(systemName: "network.badge.shield.half.filled")
                    }
                }
            }
            Button {
                Task { await setup.checkTunnel() }
            } label: {
                Label {
                    Text(l10n: "jit.checkAgain")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(setup.tunnel == nil)
        } header: {
            Text(l10n: "jit.step2")
        } footer: {
            Text(l10n: setup.tunnel == .localNetworkDenied
                 ? "jit.vpn.footer.denied"
                 : "jit.vpn.footer.normal")
                .foregroundStyle(AuroraPalette.textTertiary)
        }
        .listRowBackground(rowBackground)
    }

    private var tunnelStatus: String {
        switch setup.tunnel {
        case nil: L10n.string("jit.tunnel.checking")
        case .up: L10n.string("jit.tunnel.connected")
        case .localNetworkDenied: L10n.string("jit.tunnel.localNetworkOff")
        case .down: L10n.string("jit.tunnel.notConnected")
        }
    }

    // MARK: - 3. Disk image

    private var diskImageSection: some View {
        Section {
            switch setup.preparation {
            case .idle:
                StepStatus(titleKey: "jit.deviceDisk", done: false, status: L10n.string("jit.notChecked"))
                Button {
                    setup.prepare()
                } label: {
                    Label {
                        Text(l10n: "jit.prepareNow")
                    } icon: {
                        Image(systemName: "externaldrive.badge.checkmark")
                    }
                }
                .disabled(!setup.isReady)
            case .working:
                HStack {
                    Text(l10n: "jit.deviceDisk")
                    Spacer()
                    ProgressView()
                }
            case .ready:
                StepStatus(titleKey: "jit.deviceDisk", done: true, status: L10n.string("jit.ready"))
            case .failed(let message):
                StepStatus(titleKey: "jit.deviceDisk", done: false, status: L10n.string("jit.didntWork"))
                Text(verbatim: message)
                    .foregroundStyle(AuroraPalette.danger)
                Button {
                    setup.prepare()
                } label: {
                    Label {
                        Text(l10n: "jit.tryAgain")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(!setup.isReady)
            }
        } header: {
            Text(l10n: "jit.step3")
        } footer: {
            Text(l10n: "jit.disk.footer")
                .foregroundStyle(AuroraPalette.textTertiary)
        }
        .listRowBackground(rowBackground)
    }

    // MARK: - Turn on

    private var turnOnSection: some View {
        Section {
            Button {
                dismiss()
                Task { await jit.turnOn(.builtInStikJIT) }
            } label: {
                Label {
                    Text(l10n: "jit.turnOn")
                } icon: {
                    Image(systemName: "bolt.fill")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AuroraPrimaryButtonStyle(fullWidth: true))
            .disabled(!setup.isReady)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }
}

/// A step's name and where it stands, with a check once it's done.
private struct StepStatus: View {
    let titleKey: String
    let done: Bool
    let status: String

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AuroraPalette.success)
                }
                Text(verbatim: status)
            }
        } label: {
            Text(l10n: titleKey)
        }
    }
}
