// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

struct SecurityKeyStatusView: View {
    let controller: SecurityKeyController
    @State private var confirmingDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: symbol)
                            .font(.title2)
                            .foregroundStyle(color)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.headline)
                            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Authenticator") {
                    Picker("Authenticator", selection: Binding(
                        get: { controller.backendKind },
                        set: { controller.selectBackend($0) }
                    )) {
                        ForEach(SecurityKeyBackendKind.availableCases) { kind in
                            Label(kind.shortTitle, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(authenticatorDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if controller.backendKind == .cratePasskeys {
                    cratePasskeysSection
                } else {
                    yubiKeySection
                }

                Section("Linux helper") {
                    Text(GuestToolServer.installCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = GuestToolServer.installCommand
                    } label: {
                        Label("Copy Install Command", systemImage: "doc.on.doc")
                    }
                    Text("Run this once in Debian or Ubuntu while the VM is open. Crate serves the bundled, source-built helper only through the VM's host address.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Security Key")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Delete every Crate passkey?",
                isPresented: $confirmingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All Crate Passkeys", role: .destructive) {
                    try? controller.deleteAllCratePasskeys()
                }
            } message: {
                Text("Websites using these credentials will need another sign-in method. This cannot be undone.")
            }
        }
    }

    private var cratePasskeysSection: some View {
        Section("Crate Passkeys") {
            Button {
                Task { await controller.connectNow() }
            } label: {
                Label("Check Device Authentication", systemImage: "faceid")
            }
            .disabled(isBusy)

            if controller.cratePasskeys.isEmpty {
                Text("No passkeys yet. Choose this authenticator in Linux, then create one on a website.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.cratePasskeys) { passkey in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(passkey.relyingPartyID)
                        if let userName = passkey.userName {
                            Text(userName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Delete All Crate Passkeys", role: .destructive) {
                    confirmingDeleteAll = true
                }
            }
            Text("Every registration and sign-in requires Face ID, Touch ID, or the device passcode. Private keys are non-exportable and remain in the Secure Enclave.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var yubiKeySection: some View {
        Section(controller.backendKind.title) {
            Button {
                Task { await controller.connectNow() }
            } label: {
                Label("Check \(controller.backendKind.title)", systemImage: controller.backendKind.symbol)
            }
            .disabled(isBusy)
            Text("Sign-in only: registration, reset, credential management, writes and vendor commands are blocked before reaching the physical key.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(controller.backendKind == .yubiKeyNFC
                 ? "When Linux asks for the key, hold the NFC side of the YubiKey against the top of the iPhone until the request completes."
                 : "YubiKey firmware 5.8 or newer is required for FIDO2 over the iPhone's public USB smart-card connection. Older NFC-capable keys can use the NFC option when it is available.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var authenticatorDescription: String {
        switch controller.backendKind {
        case .cratePasskeys:
            "Crate Passkeys creates device-only credentials in this iPhone or iPad's Secure Enclave. They do not sync to Apple Passwords."
        case .yubiKey:
            "USB-C YubiKey forwards assertion-only FIDO2 requests through the phone's public smart-card connection."
        case .yubiKeyNFC:
            "NFC YubiKey forwards the same assertion-only FIDO2 requests through an ISO 7816 NFC session."
        }
    }

    private var isBusy: Bool {
        switch controller.phase {
        case .connecting, .request: true
        default: false
        }
    }

    private var symbol: String {
        switch controller.phase {
        case .waitingForGuest: controller.backendKind.symbol
        case .connecting:
            switch controller.backendKind {
            case .cratePasskeys: "faceid"
            case .yubiKey: "cable.connector"
            case .yubiKeyNFC: "wave.3.right"
            }
        case .ready: "checkmark.shield.fill"
        case .request: "hand.tap.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch controller.phase {
        case .ready: .green
        case .request: .blue
        case .failed: .orange
        default: .secondary
        }
    }

    private var title: String {
        switch controller.phase {
        case .waitingForGuest: controller.backendKind.title
        case .connecting:
            controller.backendKind == .cratePasskeys
                ? "Checking device security…" : "Checking \(controller.backendKind.title)…"
        case .ready(let device): device.name
        case .request(let operation, _): operation.rawValue
        case .failed: "Security key unavailable"
        }
    }

    private var detail: String {
        switch controller.phase {
        case .waitingForGuest:
            controller.backendKind == .cratePasskeys
                ? "Start a VM with the Crate FIDO helper to create or use a device-only passkey."
                : "Start a VM with the Crate FIDO helper, or check the physical key now."
        case .connecting:
            controller.backendKind == .cratePasskeys
                ? "Crate is checking the Secure Enclave and device authentication."
                : controller.backendKind == .yubiKeyNFC
                    ? "Hold the YubiKey against the top of the iPhone."
                    : "Keep the USB-C key connected to the iPhone."
        case .ready(let device):
            device.detail ?? "Ready for an assertion request from the running VM."
        case .request(let operation, let relyingParty):
            if controller.backendKind == .cratePasskeys {
                if let relyingParty { "\(relyingParty) requested \(operation.rawValue.lowercased()). Approve it with device authentication." }
                else { "Approve the Linux request with device authentication." }
            } else if let relyingParty {
                "\(relyingParty) requested \(operation.rawValue.lowercased()). Touch the YubiKey when it flashes."
            } else {
                "Complete the request in Linux and touch the YubiKey when it flashes."
            }
        case .failed(let message):
            message
        }
    }
}

/// A small phone-only cue while the VM is on the phone or an external display.
struct SecurityKeyBanner: View {
    let controller: SecurityKeyController

    var body: some View {
        switch controller.phase {
        case .connecting:
            label(controller.backendKind == .cratePasskeys
                  ? "Checking Crate Passkeys…" : "Checking \(controller.backendKind.title)…",
                  symbol: controller.backendKind.symbol)
        case .request(let operation, let relyingParty):
            label(relyingParty.map { "\(operation.rawValue): \($0)" }
                  ?? operation.rawValue,
                  symbol: controller.backendKind == .cratePasskeys ? "faceid" : "hand.tap.fill")
        case .failed(let message):
            label(message, symbol: "exclamationmark.triangle.fill")
        default:
            EmptyView()
        }
    }

    private func label(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(radius: 8)
            .padding(12)
    }
}
