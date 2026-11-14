// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home
    case install
    case settings

    var id: Self { self }

    var titleKey: String {
        switch self {
        case .home: "tab.home"
        case .install: "tab.install"
        case .settings: "tab.settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .install: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }

    var selectedSystemImage: String {
        switch self {
        case .home: "house.fill"
        case .install: "arrow.down.circle.fill"
        case .settings: "gearshape.fill"
        }
    }
}

/// One VM open over the tabs, and which of its screens to show first.
private struct ActiveMachine: Identifiable {
    let id = UUID()
    let machine: Machine
    let pane: MachinePane
}

/// The Aurora shell: the three pages, the adaptive navigation, and the opening
/// animation over a dashboard that is already alive behind it.
struct RootView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(JITSession.self) private var jit
    @AppStorage(SettingsKey.jitAtLaunch) private var jitAtLaunch = true
    @AppStorage(SettingsKey.jitMethod) private var jitMethod = JITMethod.standard.rawValue

    /// Crate reopens on the tab it was left on.
    @SceneStorage("tab") private var tab = AppTab.home
    @State private var running: ActiveMachine?
    @State private var didLaunch = false
    @State private var fold = FoldSignals()
    @State private var showIntro: Bool

    /// A tab to open on regardless, from a launch argument.
    private let launchTab: AppTab?
    private let forceRail: Bool

    init(launchTab: AppTab? = nil, forceRail: Bool = false, skipIntro: Bool = false) {
        self.launchTab = launchTab
        self.forceRail = forceRail
        _showIntro = State(initialValue: !skipIntro)
    }

    /// The tabs go in a column on the right whenever the Duo is open in
    /// portrait, so they stay where they are when it's closed. Closed (and open
    /// in landscape) iOS's own layout gets the floating bar, and a regular-width
    /// screen gets the full side column.
    private var usesRail: Bool {
        forceRail || (fold.hasHinge && fold.verticalEdge == nil)
    }

    private var usesSidebar: Bool {
        !usesRail && horizontalSizeClass == .regular
    }

    var body: some View {
        ZStack {
            pages

            if showIntro {
                AuroraSplashView {
                    withAnimation(reduceMotion ? .linear(duration: 0.15) : .easeInOut(duration: 0.4)) {
                        showIntro = false
                    }
                }
                .zIndex(10)
                .transition(.opacity)
            }
        }
        .environment(\.locale, preferences.locale)
        .environment(\.layoutDirection, preferences.layoutDirection)
        .environment(\.auroraReduceMotion, reduceMotion)
        // The opening is always midnight; matching the status bar to it avoids
        // a dark background with dark status text in the light appearance.
        .preferredColorScheme(showIntro ? .dark : preferences.appearance.colorScheme)
        .tint(AuroraPalette.accent)
        .readFoldSignals($fold)
        .environment(\.hasHinge, fold.hasHinge)
        .fullScreenCover(item: $running) { active in
            MachineScreen(machine: active.machine, initialPane: active.pane)
        }
        // Over the tabs; the VM screen, when it's up, shows its own.
        .sheet(isPresented: running == nil ? Bindable(jit).showingSetup : .constant(false)) {
            JITSetupView()
                .environment(jit)
                .environment(preferences)
                .tint(AuroraPalette.accent)
        }
        .task { openLaunchTab() }
        .onChange(of: jit.state, initial: true) { launchSettled() }
        .sensoryFeedback(.selection, trigger: tab)
    }

    private var reduceMotion: Bool {
        preferences.reducesMotion(system: systemReduceMotion)
    }

    @ViewBuilder
    private var pages: some View {
        Group {
            if usesRail {
                HStack(spacing: 0) {
                    page
                    AuroraSidebar(selection: $tab, compact: true, onShowJIT: showJIT)
                }
            } else if usesSidebar {
                HStack(spacing: 0) {
                    AuroraSidebar(selection: $tab, compact: false, onShowJIT: showJIT)
                    page
                }
            } else {
                page
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        AuroraTabBar(selection: $tab)
                            .background { Color.clear }
                    }
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .home:
            HomeScreen(
                onStart: { open($0, pane: .display) },
                onTerminal: { open($0, pane: .console) },
                onInstall: { tab = .install },
                onShowJIT: showJIT,
                onSettings: { tab = .settings })
                .id(preferences.resolvedLanguageCode)
        case .install:
            InstallScreen(onShowHome: { tab = .home })
                .id(preferences.resolvedLanguageCode)
        case .settings:
            SettingsScreen()
        }
    }

    private func open(_ machine: Machine, pane: MachinePane) {
        running = ActiveMachine(machine: machine, pane: pane)
    }

    private func showJIT() {
        tab = .settings
    }

    private func openLaunchTab() {
        if let launchTab { tab = launchTab }
    }

    /// With nothing attached and "Turn on JIT when crate opens" set, JIT goes
    /// on at launch, once the launch's own check settles. No VM starts by
    /// itself: that's left to Start.
    private func launchSettled() {
        guard !didLaunch, jit.state != .checking else { return }
        didLaunch = true
        if !jit.isOn, jit.state == .off(.noDebugger), jitAtLaunch {
            Task { await jit.turnOn(JITMethod(rawValue: jitMethod) ?? .standard, interactive: false) }
        }
    }
}

extension EnvironmentValues {
    /// iPhone Duo: what only applies to its hinge, folds and side bars shows.
    @Entry var hasHinge = false
}
