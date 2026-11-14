// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftTerm
import SwiftUI

/// The VM's console as a terminal: SwiftTerm (MIT) draws what the guest prints
/// and turns typing into the bytes a terminal sends.
struct ConsoleView: UIViewRepresentable {
    let bridge: ConsoleBridge
    /// Each new value brings the keyboard up: iPhone Duo folded like a laptop,
    /// its half below the fold made for one.
    var keyboardRequests = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        // A terminal is a technical surface: commands, paths and addresses
        // keep their left-to-right order in every app language.
        view.semanticContentAttribute = .forceLeftToRight
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        // The replay of what the guest printed so far (connect hands it over
        // at once, and SwiftTerm answers as it reads) holds its old questions
        // to the terminal, such as systemd asking at boot where the cursor is.
        // Answered now, long after the asker gave up, the answers would reach
        // whatever reads the console next: the login prompt, as typed text.
        context.coordinator.answering = false
        bridge.connect { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        context.coordinator.answering = true
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if keyboardRequests != context.coordinator.keyboardRequests {
            context.coordinator.keyboardRequests = keyboardRequests
            view.becomeFirstResponder()
        }
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.bridge.disconnect()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let bridge: ConsoleBridge
        /// False while replaying old output, whose questions are stale.
        var answering = true
        /// ConsoleView.keyboardRequests, as last acted on.
        var keyboardRequests = 0

        init(bridge: ConsoleBridge) {
            self.bridge = bridge
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard answering else { return }
            bridge.send(data)
        }

        // A serial console has no window size to report, no title and no
        // working directory; the rest needs nothing yet.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
