// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// One VM's settings, from its card's menu.
struct MachineSettingsSheet: View {
    let machine: Machine

    @Environment(MachineStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hasHinge) private var hasHinge

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Memory limit", selection: memoryGB) {
                        ForEach(memoryChoices, id: \.self) { gb in
                            Text("\(gb) GB").tag(gb)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("Memory Limit")
                } footer: {
                    Text(memoryFooter)
                }

                Section {
                    ForEach(portForwards.wrappedValue, id: \.hostPort) { rule in
                        NavigationLink {
                            PortForwardEditor(rules: portForwards, original: rule)
                        } label: {
                            LabeledContent("127.0.0.1:\(String(rule.hostPort))",
                                           value: "VM port \(String(rule.guestPort))")
                        }
                    }
                    .onDelete { offsets in
                        var rules = portForwards.wrappedValue
                        rules.remove(atOffsets: offsets)
                        portForwards.wrappedValue = rules
                    }
                    NavigationLink {
                        PortForwardEditor(rules: portForwards)
                    } label: {
                        Label("Add Port", systemImage: "plus")
                    }
                } header: {
                    Text("Port Forwarding")
                } footer: {
                    Text("Connect to a VM service on this device using 127.0.0.1 and the device port. TCP rules apply the next time the VM starts.")
                }

                if hasHinge {
                    Section {
                        Toggle("Full Width in Landscape", isOn: fullWidth)
                    } header: {
                        Text("Display")
                    } footer: {
                        Text("With iPhone Duo open in landscape, the desktop runs under the toolbar to the edge of the screen, the toolbar's buttons over it. Off, it stops beside them.")
                    }
                }
            }
            .navigationTitle("\(machine.name) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Memory

    /// What Install offers, and the VM's own if it's something else.
    private var memoryChoices: [Int] {
        Set(InstallScreen.memoryChoices + [current.memoryGB]).sorted()
    }

    /// The guest learns its memory as it boots, so a change waits for the next
    /// start: a running VM keeps what it started with.
    private var memoryFooter: String {
        var text = "The most memory the VM may use. A change applies the next time the VM starts."
        if let limit = MemoryReport().limit, UInt64(current.memoryGB) << 30 > limit {
            text += " crate can only claim \(Format.memory(limit)) on this \(UIDevice.current.localizedModel), so the VM gets less."
        }
        return text
    }

    private var memoryGB: Binding<Int> {
        Binding(
            get: { current.memoryGB },
            set: { gb in
                var changed = current
                changed.memoryGB = gb
                store.update(changed)
            })
    }

    // MARK: - Display

    /// Saved as it changes, from the store's copy: the sheet's own may be stale.
    private var fullWidth: Binding<Bool> {
        Binding(
            get: { current.isFullWidthInLandscape },
            set: { on in
                var changed = current
                changed.fullWidthInLandscape = on
                store.update(changed)
            })
    }

    private var current: Machine {
        store.machines.first { $0.id == machine.id } ?? machine
    }

    private var portForwards: Binding<[PortForward]> {
        Binding(
            get: { current.portForwards ?? [] },
            set: { rules in
                var changed = current
                changed.portForwards = rules
                store.update(changed)
            })
    }
}

private struct PortForwardEditor: View {
    @Binding private var rules: [PortForward]
    @Environment(\.dismiss) private var dismiss
    private let original: PortForward?
    @State private var host: String
    @State private var guest: String

    init(rules: Binding<[PortForward]>, original: PortForward? = nil) {
        _rules = rules
        self.original = original
        _host = State(initialValue: original.map { String($0.hostPort) } ?? "")
        _guest = State(initialValue: original.map { String($0.guestPort) } ?? "")
    }

    private var rule: PortForward? { PortForward(host: host, guest: guest) }

    private var hostInUse: Bool {
        guard let port = UInt16(host), port != original?.hostPort else { return false }
        return rules.contains { $0.hostPort == port }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Device port") {
                    TextField("8080", text: $host).accessibilityLabel("Device port")
                }
                LabeledContent("VM port") {
                    TextField("80", text: $guest).accessibilityLabel("VM port")
                }
            } footer: {
                if hostInUse {
                    Text("Another rule already uses this device port.")
                } else {
                    Text("Enter port numbers from 1 to 65535.")
                }
            }
            .multilineTextAlignment(.trailing)
            .keyboardType(.numberPad)
        }
        .navigationTitle(original == nil ? "Add Port" : "Edit Port")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let rule, !hostInUse else { return }
                    if let original, let index = rules.firstIndex(of: original) {
                        rules[index] = rule
                    } else {
                        rules.append(rule)
                    }
                    dismiss()
                }
                .disabled(rule == nil || hostInUse)
            }
        }
    }
}
