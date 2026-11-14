// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

@main
struct CrateApp: App {
    @State private var store: MachineStore
    @State private var jit: JITSession
    @State private var preferences: AppPreferences
    /// crate runs one VM per process: this is the one.
    @State private var runner = MachineRunner()
    /// Here rather than on the Install screen, so an install carries on while
    /// another tab shows.
    @State private var installer = Installer()
    private let options: LaunchOptions

    init() {
        AppLog.begin()
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
        // After launch arguments, so QA can open any language or appearance
        // without tapping through Settings.
        _preferences = State(initialValue: AppPreferences())
    }

    var body: some Scene {
        WindowGroup {
            RootView(launchTab: options.tab, forceRail: options.rail, skipIntro: options.skipIntro)
                .environment(store)
                .environment(jit)
                .environment(runner)
                .environment(installer)
                .environment(preferences)
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
    /// The animated opening, skipped for screenshots and UI tests.
    var skipIntro = false
    var language: AppLanguage?
    var appearance: AppAppearance?
    var animations: Bool?

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
            case "--skip-intro", "--no-splash": options.skipIntro = true
            case "--language=system": options.language = .system
            case "--language=en": options.language = .english
            case "--language=ar": options.language = .arabic
            case "--language=zh-Hans", "--language=zh": options.language = .simplifiedChinese
            case "--language=fr": options.language = .french
            case "--appearance=system": options.appearance = .system
            case "--appearance=light": options.appearance = .light
            case "--appearance=dark": options.appearance = .dark
            case "--animations=on": options.animations = true
            case "--animations=off": options.animations = false
            default: break
            }
        }
        return options
    }

    /// `--jit=on|off` sets the debug builds' pretend-JIT switch, which the
    /// real JIT state overrides when it's on. The appearance, language and
    /// animation switches are ordinary preferences and persist.
    func applyToDefaults() {
        let defaults = UserDefaults.standard
        if let jit { defaults.set(jit, forKey: SettingsKey.previewJIT) }
        if let language { defaults.set(language.rawValue, forKey: SettingsKey.appLanguage) }
        if let appearance { defaults.set(appearance.rawValue, forKey: SettingsKey.appAppearance) }
        if let animations { defaults.set(animations, forKey: SettingsKey.appAnimations) }
    }
}
