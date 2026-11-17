// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A VM, full screen. With JIT on it boots in crate and shows either its screen
/// or its console, a terminal on the serial port, with a switch between them
/// in the toolbar. Without JIT it offers to turn it on.
struct MachineScreen: View {
    let machine: Machine

    @Environment(MachineStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(JITSession.self) private var jit
    @Environment(MachineRunner.self) private var runner
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.jitMethod) private var jitMethod = JITMethod.standard.rawValue
    @AppStorage(SettingsKey.externalDisplayLayout)
    private var externalDisplayLayout = ExternalDisplayLayoutMode.standard.rawValue

    @State private var confirmingStop = false
    @State private var showing = Showing.display
    @State private var showsKeyboard = false
    @State private var hasPicture = false
    /// How many times the hinge has opened or closed further.
    @State private var folds = 0
    /// iPhone Duo is open: its inner display is the one in use.
    @State private var isOpen = false
    /// For ConsoleView: raised once each fold into the laptop posture.
    @State private var keyboardRequests = 0
    @State private var keyboardRaisedAtFold: Int?
    /// The last screenshot, shown in the corner for a few seconds.
    @State private var screenshot: Screenshot?
    /// The one whose share sheet is up.
    @State private var sharing: Screenshot?
    /// The display's white flash as a screenshot is taken.
    @State private var flash = false
    @State private var showingSecurityKey = false
    /// Nothing but the guest, edge to edge. A three-finger tap brings the
    /// controls back (DisplayView).
    @State private var isImmersive = false
    @State private var showsImmersiveHint = false

    /// The VM's screen, or its console.
    enum Showing: Hashable {
        case display
        case console
    }
    /// Debug builds pretending JIT is on have no code region to run in: they
    /// walk through a pretend boot instead.
    @State private var pretendRunning = false

    private var isThisMachine: Bool { runner.machineID == machine.id }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // On the display the keyboard covers the VM's screen rather
                // than shrinking it: a smaller view would offer the guest a new
                // desktop size, which it keeps once the keyboard goes. The
                // display moves its picture clear of the keyboard itself
                // (DisplayView). The console makes room for it, so the line
                // being typed stays in sight.
                .ignoresSafeArea(.keyboard, edges: showing == .display ? .all : [])
                .overlay(alignment: .bottomLeading) {
                    if let screenshot { thumbnail(screenshot) }
                }
                .overlay(alignment: .top) {
                    SecurityKeyBanner(controller: runner.securityKey)
                }
                .background(Color.black.ignoresSafeArea())
                .modifier(MachineTitle(title: "\(machine.name) \(machine.version)"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .confirmationDialog("Stop \(machine.name)?", isPresented: $confirmingStop,
                                    titleVisibility: .visible) {
                    Button("Stop VM", role: .destructive) { stop() }
                } message: {
                    Text("Anything not saved in \(machine.name) is lost.")
                }
                .sheet(item: $sharing) { shot in
                    ShareSheet(items: [shot.file])
                        .presentationDetents([.medium, .large])
                        .ignoresSafeArea()
                }
                .sheet(isPresented: $showingSecurityKey) {
                    SecurityKeyStatusView(controller: runner.securityKey)
                        .presentationDetents([.medium, .large])
                        .preferredColorScheme(nil)
                }
                .sensoryFeedback(.impact(weight: .light), trigger: screenshot?.id)
        }
        .toolbarVisibility(isImmersive ? .hidden : .automatic, for: .navigationBar)
        .statusBarHidden(isImmersive)
        .persistentSystemOverlays(isImmersive ? .hidden : .automatic)
        .ignoresSafeArea(.container, edges: isImmersive ? .all : [])
        .overlay(alignment: .top) {
            if isImmersive && showsImmersiveHint {
                Label("Three-finger tap for controls", systemImage: "hand.tap")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        // A connected display shows the VM's screen while this is up, the
        // console included (ExternalDisplay).
        .background { ExternalDisplayRegistration(bridge: runner.display) }
        .preferredColorScheme(.dark)
        .modifier(FollowsHinge(folds: $folds, isOpen: $isOpen))
        .task(id: jit.isOn) { boot() }
        .onAppear { HardwareMouse.shared.start(bridge: runner.display) }
        .onDisappear { HardwareMouse.shared.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { runner.securityKey.suspend() }
        }
        .onChange(of: isRunning) { _, running in
            if !running { leaveImmersive() }
        }
        .sheet(isPresented: Bindable(jit).showingSetup) {
            JITSetupView()
                .environment(jit)
                .preferredColorScheme(nil)
        }
    }

    private var isRunning: Bool {
        (isThisMachine && runner.isRunning) || pretendRunning
    }

    /// The system's toolbar, so it goes where iOS puts bars: along the top on
    /// most iPhones, down the side on iPhone Duo's outer display and its inner
    /// one in landscape. Stop (confirmed, since the VM loses whatever its guest
    /// hasn't saved) or Close comes first, as navigation does; then the switch
    /// between the VM's screen and its console, and the keyboard. Short of
    /// room, as down the side with the keyboard up, the keyboard is the last
    /// to go into the overflow menu: it's the one used all the time. A
    /// screenshot, used now and then, is always in that menu.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isRunning {
            ToolbarItem(placement: .cancellationAction) {
                Button("Stop", systemImage: "stop.fill") { confirmingStop = true }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle("Display", systemImage: "display", isOn: shows(.display))
                Toggle("Terminal", systemImage: "apple.terminal", isOn: shows(.console))
            }
            ToolbarItem(placement: .secondaryAction) { securityKeyButton }
            ToolbarItem(placement: .secondaryAction) { externalDisplayButton }
            if showing == .display {
                if #available(iOS 27.0, *) {
                    keyboardItem.visibilityPriority(.high)
                    ToolbarOverflowMenu {
                        pasteButton
                        immersiveButton
                        screenshotButton
                    }
                } else {
                    keyboardItem
                    ToolbarItem(placement: .secondaryAction) { pasteButton }
                    ToolbarItem(placement: .secondaryAction) { immersiveButton }
                    ToolbarItem(placement: .secondaryAction) { screenshotButton }
                }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
    }

    private var keyboardItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Toggle("Keyboard", systemImage: "keyboard", isOn: $showsKeyboard)
        }
    }

    private var screenshotButton: some View {
        Button("Take Screenshot", systemImage: "camera.viewfinder", action: takeScreenshot)
            .disabled(!hasPicture)
    }

    /// The system control reads the clipboard only after it is tapped, then
    /// Crate types the text through the guest's ordinary virtual keyboard.
    private var pasteButton: some View {
        PasteButton(payloadType: String.self) { strings in
            runner.display.typeClipboardText(strings.joined(separator: "\n"))
        }
    }

    private var immersiveButton: some View {
        Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
            enterImmersive()
        }
        .keyboardShortcut("f", modifiers: [.control, .command])
    }

    private func enterImmersive() {
        showsKeyboard = false
        withAnimation(.snappy) {
            isImmersive = true
            showsImmersiveHint = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard isImmersive else { return }
            withAnimation(.easeOut) { showsImmersiveHint = false }
        }
    }

    private func leaveImmersive() {
        guard isImmersive || showsImmersiveHint else { return }
        withAnimation(.snappy) {
            isImmersive = false
            showsImmersiveHint = false
        }
    }

    private var securityKeyButton: some View {
        Button("Security Key", systemImage: "key.horizontal") {
            showingSecurityKey = true
        }
    }

    private var externalDisplayButton: some View {
        Menu("External Display", systemImage: "display") {
            ForEach(ExternalDisplayLayoutMode.allCases) { mode in
                Button {
                    ExternalDisplay.shared.setLayoutMode(mode)
                } label: {
                    Label(
                        mode.title,
                        systemImage: externalDisplayLayout == mode.rawValue
                            ? "checkmark.circle.fill"
                            : mode.icon
                    )
                }
            }
            Divider()
            Text("Full 32:9 requires Full Wide on the monitor")
        }
    }

    /// The display's screen as it is now, into Photos, with a flash over the
    /// display and the picture in the corner for a few seconds, to share.
    private func takeScreenshot() {
        guard let image = runner.display.snapshot() else { return }
        flash = true
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeOut(duration: 0.4)) { flash = false }
        }
        Task {
            guard var shot = await Screenshot.make(image, of: machine.name) else { return }
            shot.saved = await shot.saveToPhotos()
            AppLog.write("screenshot: \(image.width)x\(image.height), \(shot.saved ? "in Photos" : "not in Photos")")
            withAnimation(.snappy) { screenshot = shot }
            try? await Task.sleep(for: .seconds(5))
            if screenshot?.id == shot.id { withAnimation(.snappy) { screenshot = nil } }
        }
    }

    /// The last screenshot, small: tapping it shares it.
    private func thumbnail(_ shot: Screenshot) -> some View {
        Button {
            sharing = shot
            withAnimation(.snappy) { screenshot = nil }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(uiImage: shot.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    }
                    .shadow(radius: 8)
                Text(shot.saved ? "Saved to Photos" : "Tap to Share")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .padding(16)
        .transition(.move(edge: .leading).combined(with: .opacity))
        .accessibilityLabel(shot.saved ? "Screenshot, saved to Photos. Share" : "Screenshot. Share")
    }

    /// On while `view` shows; turning it on shows it.
    private func shows(_ view: Showing) -> Binding<Bool> {
        Binding(get: { showing == view }, set: { if $0 { showing = view } })
    }

    @ViewBuilder
    private var content: some View {
        if !jit.isOn {
            centered { needsJIT }
        } else if jit.region == nil {
            if !pretendRunning {
                pretendBoot
            } else if showing == .display {
                display
            } else {
                console
            }
        } else if isThisMachine {
            switch runner.phase {
            case .idle, .starting, .running:
                if showing == .display {
                    display
                } else {
                    console
                }
            case .stopped(let message):
                centered { ended(message, failed: false) }
            case .failed(let message):
                centered { ended(message, failed: true) }
            }
        } else if runner.isRunning {
            centered {
                Text("Another VM is running. Stop it first: crate runs one VM at a time.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        } else {
            centered { ProgressView().controlSize(.large) }
        }
    }

    /// The VM's screen. With iPhone Duo folded like a laptop it sits above the
    /// fold, as wide as the display, and the keyboard, when it's up, below.
    private var display: some View {
        GeometryReader { proxy in
            let open = Self.aboveFold(in: proxy, after: folds)
            let portrait = isOpen && open == nil && proxy.size.height > proxy.size.width
            DisplayView(bridge: runner.display, showsKeyboard: $showsKeyboard,
                        hasPicture: $hasPicture, openRegion: open,
                        usesPortraitDesktop: portrait,
                        onShowControls: leaveImmersive)
                .onChange(of: open) { _, open in Self.log(open, in: proxy.size) }
        }
        // The keyboard covers the desktop rather than resizing it, which the
        // guest would redo its layout for.
        .ignoresSafeArea(.keyboard)
        .modifier(UnderSideBar(isOn: isOpen && machine.isFullWidthInLandscape))
        .overlay {
            Color.white
                .opacity(flash ? 0.7 : 0)
                .allowsHitTesting(false)
        }
        .overlay {
            if !hasPicture {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Starting the desktop…")
                        .font(.headline)
                    Text("The terminal shows the boot.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The console. With iPhone Duo folded like a laptop it sits above the
    /// fold, and the keyboard comes up below it as the iPhone folds; put
    /// away, it stays away until the next fold.
    private var console: some View {
        GeometryReader { proxy in
            let open = Self.aboveFold(in: proxy, after: folds)
            ConsoleView(bridge: runner.console, keyboardRequests: keyboardRequests)
                .frame(width: proxy.size.width, height: open?.height ?? proxy.size.height)
                .onChange(of: open, initial: true) { _, open in
                    Self.log(open, in: proxy.size)
                    if open != nil, keyboardRaisedAtFold != folds {
                        keyboardRaisedAtFold = folds
                        keyboardRequests += 1
                    }
                }
        }
    }

    /// With iPhone Duo half open like a laptop (the fold across the view),
    /// the part above the fold, where the VM's screen or console goes, the
    /// keyboard below. Nil otherwise, including half open like a book: then
    /// they span the fold, the smaller change. `folds` is read so this is
    /// asked again each time the hinge moves.
    private static func aboveFold(in proxy: GeometryProxy, after folds: Int) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        for fold in proxy.reservedRegions(kind: .division) where fold.isActive {
            let frame = fold.frame
            if frame.width > frame.height, frame.minY > proxy.size.height / 4 {
                // With the keyboard up the view may already end above it.
                return CGRect(x: 0, y: 0, width: proxy.size.width,
                              height: min(frame.minY, proxy.size.height))
            }
        }
        return nil
    }

    /// The fold, for the log: the simulator can't fold, so a fold on the
    /// device is checked from there.
    private static func log(_ open: CGRect?, in size: CGSize) {
        AppLog.write(open.map { "fold: \(Int($0.height)) of \(Int(size.height)) pt above it" }
                     ?? "fold: none across, \(Int(size.width))x\(Int(size.height)) pt")
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(24)
            .frame(maxWidth: 380)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var needsJIT: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
            Text("JIT Is Off")
                .font(.title2.bold())
            Text("crate needs JIT to run \(machine.name). Turn it on, then the VM starts.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Task { await jit.turnOn(JITMethod(rawValue: jitMethod) ?? .standard) }
            } label: {
                if jit.isTurningOn {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("Turn On JIT", systemImage: "bolt.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(jit.isTurningOn)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func ended(_ message: String, failed: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "power")
                .font(.system(size: 40))
                .foregroundStyle(failed ? .orange : .secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                boot()
            } label: {
                Label("Start Again", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }

    /// Debug builds pretending JIT is on: a pretend boot, over the screenshot
    /// the display then shows as the VM's screen.
    private var pretendBoot: some View {
        ZStack {
            MachineScreenshot(machine: machine)
                .aspectRatio(4 / 3, contentMode: .fit)
                .padding()
                .opacity(0.3)
                .blur(radius: 6)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Starting \(machine.name)…")
                    .font(.headline)
            }
        }
    }

    private func boot() {
        guard jit.isOn else { return }
        guard let region = jit.region else {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                #if DEBUG
                if let name = machine.screenshot, let image = UIImage(named: name)?.cgImage {
                    runner.display.pretend(image)
                }
                runner.console.pretend("\r\nDebian GNU/Linux 13 debian ttyAMA0\r\n\r\ndebian login: ")
                #endif
                withAnimation { pretendRunning = true }
            }
            return
        }
        // Already running this VM (the screen reopened), or another one.
        guard !runner.isRunning else { return }
        runner.start(machine, region: region)
        store.markStarted(machine)
    }

    /// The screen as it is goes to the VM's card first: what was showing
    /// when it stopped is its preview on Home.
    private func stop() {
        savePreview()
        if pretendRunning {
            pretendRunning = false
            dismiss()
            return
        }
        runner.stop()
    }

    private func savePreview() {
        guard let image = runner.display.snapshot() else { return }
        let machine = machine, store = store
        Task {
            if await MachinePreview.save(image, to: GuestFiles(for: machine).preview) {
                store.previewSaved(machine)
            }
        }
    }
}

/// Follows iPhone Duo's hinge: counts its changes, so what reads the reserved
/// regions is asked again as the fold comes and goes, and says whether it's
/// open.
private struct FollowsHinge: ViewModifier {
    @Binding var folds: Int
    @Binding var isOpen: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(HingeReader(folds: $folds, isOpen: $isOpen))
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct HingeReader: ViewModifier {
    @Binding var folds: Int
    @Binding var isOpen: Bool
    @State private var status: DeviceHinge.Status?

    func body(content: Content) -> some View {
        content.onHingeChange { _, new in
            // No hinge means this view stopped getting updates as it moves,
            // not that the hinge went: compared with the last one there was.
            guard let hinge = new.hinge, hinge.status != status else { return }
            status = hinge.status
            isOpen = hinge.status != .closed
            AppLog.write("hinge: \(hinge.status)")
            folds += 1
        }
    }
}

/// With iPhone Duo open and the bars down the side (its inner display in
/// landscape), the VM's screen runs on under them to the display's edge, the
/// bar's buttons over it: the guide allows the full width for a screen that
/// doesn't scroll. Not when it's closed: the outer display's camera is in
/// that column.
private struct UnderSideBar: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(UnderVerticalBar(isOn: isOn))
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct UnderVerticalBar: ViewModifier {
    let isOn: Bool
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: edges)
    }

    private var edges: Edge.Set {
        guard isOn, let verticalEdge else { return [] }
        return verticalEdge == .leading ? .leading : .trailing
    }
}

/// The VM's name as the title, except where iOS puts the bars down the side,
/// on iPhone Duo: a title there is a strip of its own across the top, height
/// the VM's screen and console need more.
private struct MachineTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(TitleUnlessBarsVertical(title: title))
        } else {
            content.navigationTitle(title)
        }
    }
}

@available(iOS 27.1, *)
private struct TitleUnlessBarsVertical: ViewModifier {
    let title: String
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbar(removing: verticalEdge == nil ? nil : .title)
    }
}
