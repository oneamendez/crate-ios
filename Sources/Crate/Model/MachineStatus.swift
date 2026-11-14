// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// What a VM is doing right now, as one value the dashboard can draw. This is
/// derived from `MachineRunner.phase`; it is never made up.
enum MachineStatus: Equatable {
    case running
    case starting
    case stopped
    case failed(String)
    case otherRunning

    var titleKey: String {
        switch self {
        case .running: "status.running"
        case .starting: "status.starting"
        case .stopped: "status.stopped"
        case .failed: "status.failed"
        case .otherRunning: "status.busy"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .starting: "arrow.triangle.2.circlepath"
        case .stopped: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .otherRunning: "hourglass"
        }
    }

    var error: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var isRunning: Bool {
        self == .running || self == .starting
    }
}
