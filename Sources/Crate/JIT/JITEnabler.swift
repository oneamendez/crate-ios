// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import UIKit

/// Turning JIT on: getting a debugger to attach to crate while it runs.
extension JITSession {
    /// Asks `method` to attach, waits for the debugger to arrive, then claims
    /// the code region with it. Leaves `enablerError` set if it didn't work.
    /// `interactive` is false for the attempt crate makes by itself at launch,
    /// which doesn't open the setup sheet unasked.
    func turnOn(_ method: JITMethod, interactive: Bool = true) async {
        guard !isTurningOn, !isOn else { return }
        enablerError = nil
        isTurningOn = true
        defer { isTurningOn = false }
        AppLog.write("jit: turning on with \(method.rawValue)")

        let asked: Bool
        switch method {
        case .stikDebug:
            asked = await askStikDebug()
        case .builtInStikJIT:
            asked = await askBuiltIn(interactive: interactive)
        }
        guard asked else { return }

        // The built-in helper may first download Apple's developer disk image.
        let timeout: Duration = method == .builtInStikJIT ? .seconds(300) : .seconds(120)
        guard await waitForDebugger(upTo: timeout) else {
            if let helperFailure {
                fail(L10n.format("jit.error.helperFailed", helperFailure))
            } else {
                fail(L10n.format("jit.error.didntAttach", method.title))
            }
            return
        }
        AppLog.write("jit: debugger attached")
        await check()
    }

    /// Opens StikDebug and asks it to attach to this process with legacy.js,
    /// the script that answers crate's `brk #0x69`. StikDebug asks the user to
    /// confirm, attaches, and brings crate back to the front.
    private func askStikDebug() async -> Bool {
        var url = URLComponents()
        url.scheme = "stikdebug"
        url.host = "enable-jit"
        url.queryItems = [
            URLQueryItem(name: "bundle-id", value: Bundle.main.bundleIdentifier),
            URLQueryItem(name: "pid", value: String(getpid())),
            URLQueryItem(name: "script-name", value: "legacy.js"),
        ]
        guard let target = url.url, await UIApplication.shared.open(target) else {
            fail(L10n.string("jit.error.stikDebugMissing"))
            return false
        }
        AppLog.write("jit: opened \(target.absoluteString)")
        return true
    }

    /// Starts crate's helper extension, which attaches with StikJIT through
    /// LocalDevVPN's tunnel and runs legacy.js. Its reply comes after it has
    /// detached, or early with what stopped it, which ends the wait.
    private func askBuiltIn(interactive: Bool) async -> Bool {
        if getenv("LC_HOME_PATH") != nil {
            fail(L10n.string("jit.error.liveContainer"))
            return false
        }
        guard let pairing = PairingFile.read() else {
            AppLog.write("jit: built-in isn't set up (no pairing)")
            if interactive { showingSetup = true }
            return false
        }
        helperFailure = nil
        let request: [String: Any] = ["pid": Int(getpid()), "pairing": pairing]
        crate_helper_request(request) { reply, failure in
            let ok = reply?["ok"] as? Bool ?? false
            let summary = reply?["summary"] as? String ?? failure ?? "no reply"
            let lines = reply?["log"] as? [String] ?? []
            Task { @MainActor in
                for line in lines { AppLog.write("helper: \(line)") }
                AppLog.write("jit: helper replied: \(ok ? "" : "FAILED: ")\(summary)")
                if !ok { self.helperFailure = summary }
            }
        }
        AppLog.write("jit: started the built-in helper")
        return true
    }

    /// Polls for the debugger. crate may be in the background meanwhile; iOS
    /// suspends it there, and the polling picks up when it's back in front.
    private func waitForDebugger(upTo timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if Self.debuggerReady { return true }
            if helperFailure != nil { return false }
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return false }
        }
        return Self.debuggerReady
    }

    private func fail(_ message: String) {
        AppLog.write("jit: turning on failed: \(message)")
        enablerError = message
    }
}
