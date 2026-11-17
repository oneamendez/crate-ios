// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

@main
struct CrateApp: App {
    @UIApplicationDelegateAdaptor(CrateApplicationDelegate.self) private var applicationDelegate
    @State private var store: MachineStore
    @State private var jit: JITSession
    /// crate runs one VM per process: this is the one.
    @State private var runner = MachineRunner()
    /// Here rather than on the Install screen, so an install carries on while
    /// another tab shows.
    @State private var installer = Installer()
    private let options: LaunchOptions

    init() {
        AppLog.begin()
        MemoryLog.watchWarnings()
        let memory = MemoryReport()
        AppLog.write("memory: physical \(memory.physical), limit \(memory.limit.map(String.init) ?? "n/a"), "
                     + "available \(memory.available.map(String.init) ?? "n/a"), footprint \(memory.footprint) bytes")
        options = LaunchOptions.parse(ProcessInfo.processInfo.arguments)
        options.applyToDefaults()
        let store = MachineStore()
        if options.empty { store.removeAll() }
        if options.samples { store.restoreSamples() }
        _store = State(initialValue: store)
        // First, while a debugger that will leave once it has authorized the
        // code region is still attached.
        let jit = JITSession()
        jit.start()
        _jit = State(initialValue: jit)
    }

    var body: some Scene {
        WindowGroup {
            RootView(launchTab: options.tab, forceRail: options.rail)
                .environment(store)
                .environment(jit)
                .environment(runner)
                .environment(installer)
        }
    }
}

/// Launch arguments for looking at one state of the UI without tapping to it,
/// e.g. `xcrun simctl launch booted com.amendez.crate --tab=install --jit=off`.
struct LaunchOptions {
    var tab: AppTab?
    var jit: Bool?
    var empty = false
    var samples = false
    /// The open Duo's tab column, on any device.
    var rail = false

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        for argument in arguments.dropFirst() {
            switch argument {
            case "--tab=home": options.tab = .home
            case "--tab=install": options.tab = .install
            case "--tab=settings": options.tab = .settings
            case "--jit=on": options.jit = true
            case "--jit=off": options.jit = false
            case "--empty": options.empty = true
            case "--samples": options.samples = true
            case "--rail": options.rail = true
            default: break
            }
        }
        return options
    }

    /// `--jit=on|off` sets the debug builds' pretend-JIT switch, which the
    /// real JIT state overrides when it's on.
    func applyToDefaults() {
        if let jit { UserDefaults.standard.set(jit, forKey: SettingsKey.previewJIT) }
    }
}
