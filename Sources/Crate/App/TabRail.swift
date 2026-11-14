// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import os

// MARK: - Fold signals

/// What iOS says about the device's fold, for choosing where the tabs go.
struct FoldSignals: Equatable {
    /// Whether this is a foldable at all. Stays false on every other iPhone.
    var hasHinge = false
    var isClosed = false
    /// Where the system puts vertical bars, if it does: on the Duo when closed,
    /// and when open in landscape. Nil open in portrait and on other iPhones.
    var verticalEdge: HorizontalEdge?
}

extension View {
    /// Keeps `signals` current. Does nothing before iOS 27.1, which has no Duo.
    func readFoldSignals(_ signals: Binding<FoldSignals>) -> some View {
        modifier(FoldSignalReader(signals: signals))
    }
}

private struct FoldSignalReader: ViewModifier {
    @Binding var signals: FoldSignals

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(HingeReader(signals: $signals))
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct HingeReader: ViewModifier {
    @Binding var signals: FoldSignals
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    private static let log = Logger(subsystem: "com.amendez.crate", category: "layout")

    func body(content: Content) -> some View {
        content
            .onChange(of: verticalEdge, initial: true) { _, edge in
                signals.verticalEdge = edge
                Self.log.notice("vertical edge: \(String(describing: edge), privacy: .public)")
            }
            .onHingeChange { _, new in
                // A nil hinge means this view stopped getting updates (it's
                // moving), not that the device lost its hinge.
                guard let hinge = new.hinge else { return }
                signals.hasHinge = true
                signals.isClosed = hinge.status == .closed
                Self.log.notice("hinge: \(String(describing: hinge.status), privacy: .public)")
            }
    }
}
