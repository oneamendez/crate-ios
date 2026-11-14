// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// What Built-in StikJIT needs, step by step, and the actions that get each:
/// this iPhone paired with crate, LocalDevVPN connected, and Apple's developer
/// disk image mounted. JITSetupView shows it.
@MainActor @Observable
final class JITSetup {
    enum Pairing: Equatable {
        case idle
        /// Getting ready to advertise.
        case starting
        /// Advertising: the code to type in Settings, and whether Settings has
        /// connected and is asking for it.
        case showing(code: String, connected: Bool)
        case failed(String)
    }

    enum Preparation: Equatable {
        case idle
        case working
        case ready(String)
        case failed(String)
    }

    private(set) var hasPairingFile = PairingFile.exists
    private(set) var pairing = Pairing.idle
    /// Nil while checking.
    private(set) var tunnel: LocalDevVPN.Tunnel?
    private(set) var preparation = Preparation.idle
    var importError: String?

    let pictureInPicture = PairingCodePictureInPicture()
    private var host: OnDevicePairing?
    /// A little more time in the background, in case Picture in Picture is off.
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    /// iOS 27 can pair with an app on the same device; earlier, the pairing
    /// file has to come from a computer.
    var canPairOnDevice: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    var isReady: Bool { hasPairingFile && tunnel == .up }

    // MARK: - Pairing

    func startPairing() {
        cancelPairing()
        pairing = .starting
        let host = OnDevicePairing { [weak self] event in self?.handle(event) }
        self.host = host
        host.start()
        AppLog.write("jit: pairing on this iPhone: starting")
    }

    func cancelPairing() {
        host?.cancel()
        finishPairing()
        if case .failed = pairing {} else { pairing = .idle }
    }

    /// Ends pairing. Picture in Picture, if it's up over Settings, says how it
    /// ended until crate is back in front (`returnedToFront()`).
    private func finishPairing(paired: Bool? = nil) {
        host = nil
        if let paired, pictureInPicture.isActive {
            pictureInPicture.finish(paired: paired)
        } else {
            pictureInPicture.stop()
        }
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    /// Floats the code over Settings and opens Settings, from the button tap
    /// Picture in Picture needs to start.
    func openSettings() {
        pictureInPicture.startNow()
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Pairing") { [weak self] in
                guard let self else { return }
                AppLog.write("jit: pairing: background time ran out")
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
        // Settings' top level. No link reaches Developer Mode itself: on iOS 27
        // every Privacy and Developer Mode path tried lands on the Apps list,
        // further from it. crate's own page if even this one stops working.
        let top = URL(string: "App-prefs:")!
        UIApplication.shared.open(top) { opened in
            if !opened { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
        }
    }

    private func handle(_ event: OnDevicePairing.Event) {
        switch event {
        case .ready(let code):
            pairing = .showing(code: code, connected: false)
            pictureInPicture.start()
            pictureInPicture.show(code: code, connected: false)
            AppLog.write("jit: pairing: advertising")
        case .connected:
            guard case .showing(let code, _) = pairing else { return }
            pairing = .showing(code: code, connected: true)
            pictureInPicture.show(code: code, connected: true)
            AppLog.write("jit: pairing: Settings connected")
            // Settings normally finishes within a minute of asking for the code.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                guard let self, case .showing(_, true) = self.pairing else { return }
                AppLog.write("jit: pairing: no answer from Settings in 3 minutes")
                self.cancelPairing()
                self.pairing = .failed(L10n.string("jit.pairing.timeout"))
            }
        case .paired(let record):
            finishPairing(paired: true)
            do {
                try PairingFile.store(record)
                hasPairingFile = true
                pairing = .idle
                preparation = .idle
            } catch {
                pairing = .failed(L10n.format("jit.pairing.saveFailed", error.localizedDescription))
            }
        case .failed(let message):
            finishPairing(paired: false)
            pairing = .failed(message)
            AppLog.write("jit: pairing failed: \(message)")
        }
    }

    func forgetPairing() {
        cancelPairing()
        PairingFile.forget()
        hasPairingFile = false
        preparation = .idle
    }

    func importFile(_ result: Result<URL, Error>) {
        importError = nil
        do {
            try PairingFile.importFile(from: result.get())
            hasPairingFile = true
            preparation = .idle
        } catch let error as CocoaError where error.code == .userCancelled {
            return
        } catch {
            importError = error.localizedDescription
        }
    }

    /// crate is in front again: closes Picture in Picture once pairing is over.
    func returnedToFront() {
        if host == nil { pictureInPicture.stop() }
    }

    // MARK: - LocalDevVPN

    func checkTunnel() async {
        tunnel = nil
        tunnel = await LocalDevVPN.probe()
    }

    func connectVPN() {
        UIApplication.shared.open(LocalDevVPN.isInstalled ? LocalDevVPN.connectURL : LocalDevVPN.appStoreURL)
    }

    // MARK: - Developer disk image

    /// Asks the helper to mount Apple's developer disk image, downloading it
    /// the first time. Turning JIT on does this too; doing it here shows any
    /// problem before then.
    func prepare() {
        guard let pairing = PairingFile.read() else { return }
        preparation = .working
        crate_helper_request(["op": "prepare", "pairing": pairing]) { reply, failure in
            let ok = reply?["ok"] as? Bool ?? false
            let summary = reply?["summary"] as? String ?? failure ?? "no reply"
            let lines = reply?["log"] as? [String] ?? []
            Task { @MainActor in
                for line in lines { AppLog.write("helper: \(line)") }
                AppLog.write("jit: prepare: \(ok ? "" : "FAILED: ")\(summary)")
                self.preparation = ok ? .ready(summary) : .failed(summary)
            }
        }
    }
}
