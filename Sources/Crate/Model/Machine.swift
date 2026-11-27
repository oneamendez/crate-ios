// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct PortForward: Codable, Hashable, Sendable {
    let hostPort: UInt16
    let guestPort: UInt16

    init?(host: String, guest: String) {
        guard let hostPort = UInt16(host), hostPort > 0,
              let guestPort = UInt16(guest), guestPort > 0 else { return nil }
        self.hostPort = hostPort
        self.guestPort = guestPort
    }
}

/// One installed VM: a distribution at a version, and the hardware it is given.
struct Machine: Identifiable, Codable, Hashable {
    var id = UUID()
    var distributionID: String
    var version: String
    var codename: String?
    var cpuCount: Int
    var memoryGB: Int
    var diskGB: Int
    var diskUsedGB: Double
    var desktop: String
    var display: String
    var architecture = "arm64"
    /// An asset name. Nil until the VM has run once and there is something to show.
    var screenshot: String?
    var lastStarted: Date?
    /// The catalog image it was installed from ("debian-kde"); nil for a VM
    /// put on the iPhone by hand.
    var imageID: String?
    /// The kernel command line its image boots with; nil for one put on by
    /// hand, which gets MachineRunner's own.
    var cmdline: String?
    /// On iPhone Duo in landscape, the desktop runs on under the side bar to
    /// the screen's edge. Nil, from before there was the choice, is on.
    var fullWidthInLandscape: Bool?
    /// When its card's preview (GuestFiles.preview) was last saved; nil
    /// before it has been stopped from its screen.
    var previewDate: Date?
    /// Absent in saved VMs from before port forwarding.
    var portForwards: [PortForward]?

    var isFullWidthInLandscape: Bool { fullWidthInLandscape ?? true }

    var distribution: Distribution { .named(distributionID) }
    var name: String { distribution.name }

    /// "13.2" or "13.2 Trixie".
    var versionLabel: String {
        [version, codename].compactMap { $0 }.joined(separator: " ")
    }
}

// MARK: - Sample data

// For previewing the UI (`--samples`): they have no files, and the next
// launch without `--samples` takes them out of the list again.
extension Machine {
    static let sampleDebian = Machine(
        distributionID: "debian", version: "13.2", codename: "Trixie",
        cpuCount: 4, memoryGB: 6, diskGB: 32, diskUsedGB: 7.4,
        desktop: "Xfce", display: "1280 × 800", screenshot: "debian-xfce",
        lastStarted: Date(timeIntervalSinceNow: -3 * 3600))

    static let sampleArch = Machine(
        distributionID: "arch", version: "2026.11.01",
        cpuCount: 4, memoryGB: 4, diskGB: 32, diskUsedGB: 9.1,
        desktop: "Hyprland", display: "1280 × 800", screenshot: "arch-hyprland",
        lastStarted: Date(timeIntervalSinceNow: -2 * 86400))

    static let samples = [sampleDebian, sampleArch]
}
