// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum Format {
    /// "5.8 GB", "107 GB", "384 MB". Decimal units, as the Settings app uses,
    /// with one decimal only where it says something. The decimal separator
    /// follows the language chosen in crate.
    static func bytes(_ count: Int64) -> String {
        let gb = Double(count) / 1e9
        if gb >= 10 { return "\(number(gb, decimals: 0)) GB" }
        if gb >= 1 { return "\(number(gb, decimals: 1, minimum: 0)) GB" }
        return "\(number(Double(count) / 1e6, decimals: 0)) MB"
    }

    /// Memory in the binary units it's sold in: an "8 GB" iPhone has 8 GiB, and
    /// a VM given "4 GB" gets 4 GiB. Up to one decimal place, or exactly
    /// `decimals` for a figure that moves, so it doesn't look round when it isn't.
    static func memory(_ count: UInt64, decimals: Int? = nil) -> String {
        let gib = Double(count) / 1_073_741_824
        if gib >= 1 {
            let places = decimals ?? 1
            return "\(number(gib, decimals: places, minimum: decimals == nil ? 0 : places)) GB"
        }
        return "\(number(Double(count) / 1_048_576, decimals: 0)) MB"
    }

    /// "1 hour ago". Nil reads as "Never".
    static func relative(_ date: Date?) -> String {
        guard let date else { return L10n.string("common.never") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private static func number(_ value: Double, decimals: Int, minimum: Int? = nil) -> String {
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minimum ?? decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
    }

    /// Free space on the volume that holds the app's data.
    static func freeDiskBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
