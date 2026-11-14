// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The two views a running VM has: its desktop, and its serial console.
enum MachinePane: Hashable {
    case display
    case console
}

/// A VM, full screen. With JIT on it boots in crate and shows either its screen
/// or its console, a terminal on the serial port, with a switch between them
/// in the toolbar. Without JIT it offers to turn it on.
struct MachineScreen: View {
    let machine: Machine

    @Environment(MachineStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(JITSession.self) private var jit
    @Environment(MachineRunner.self) private var runner
    @AppStorage(SettingsKey.jitMethod) private var jitMethod = JITMethod.standard.rawValue

    @State private var confirmingStop = false
    @State private var showing: MachinePane
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
    @State private var logURL: URL?

    /// Debug builds pretending JIT is on have no code region to run in: they
    /// walk through a pretend boot instead.
    @State private var pretendRunning = false

    init(machine: Machine, initialPane: MachinePane = .display) {
        self.machine = machine
        _showing = State(initialValue: initialPane)
    }

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
                .background(Color.black.ignoresSafeArea())
                .modifier(MachineTitle(title: "\(machine.name) \(machine.version)"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .confirmationDialog(
                    L10n.format("machine.stop.title", machine.name),
                    isPresented: $confirmingStop,
                    titleVisibility: .visible
                ) {
                    Button(role: .destructive) {
                        stop()
                    } label: {
                        Text(l10n: "machine.stop.confirm")
                    }
                    Button(role: .cancel) {} label: {
                        Text(l10n: "common.cancel")
                    }
                } message: {
                    Text(verbatim: L10n.format("machine.stop.message", machine.name))
                }
                .sheet(item: $sharing) { shot in
                    ShareSheet(items: [shot.file])
                        .presentationDetents([.medium, .large])
                        .ignoresSafeArea()
                }
                .sensoryFeedback(.impact(weight: .light), trigger: screenshot?.id)
        }
        .preferredColorScheme(.dark)
        .tint(AuroraPalette.accent)
        .modifier(FollowsHinge(folds: $folds, isOpen: $isOpen))
        .task(id: jit.isOn) { boot() }
        .onAppear {
            if logURL == nil { logURL = LogExport.prepare() }
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
                Button {
                    confirmingStop = true
                } label: {
                    Label {
                        Text(l10n: "machine.stop")
                    } icon: {
                        Image(systemName: "stop.fill")
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: shows(.display)) {
                    Label {
                        Text(l10n: "machine.display")
                    } icon: {
                        Image(systemName: "display")
                    }
                }
                Toggle(isOn: shows(.console)) {
                    Label {
                        Text(l10n: "machine.terminal")
                    } icon: {
                        Image(systemName: "apple.terminal")
                    }
                }
            }
            if showing == .display {
                if #available(iOS 27.0, *) {
                    keyboardItem.visibilityPriority(.high)
                    ToolbarOverflowMenu { screenshotButton }
                } else {
                    keyboardItem
                    ToolbarItem(placement: .secondaryAction) { screenshotButton }
                }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Label {
                        Text(l10n: "machine.close")
                    } icon: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    private var keyboardItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $showsKeyboard) {
                Label {
                    Text(l10n: "machine.keyboard")
                } icon: {
                    Image(systemName: "keyboard")
                }
            }
        }
    }

    private var screenshotButton: some View {
        Button(action: takeScreenshot) {
            Label {
                Text(l10n: "machine.screenshot")
            } icon: {
                Image(systemName: "camera.viewfinder")
            }
        }
        .disabled(!hasPicture)
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
                Text(l10n: shot.saved ? "machine.savedToPhotos" : "machine.tapToShare")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AuroraPalette.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .padding(16)
        .transition(.move(edge: .leading).combined(with: .opacity))
        .accessibilityLabel(Text(l10n: shot.saved ? "machine.screenshot.savedA11y" : "machine.screenshot.shareA11y"))
    }

    /// On while `view` shows; turning it on shows it.
    private func shows(_ view: MachinePane) -> Binding<Bool> {
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
                AuroraCard(tint: AuroraPalette.amber) {
                    VStack(spacing: 10) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 34))
                            .foregroundStyle(AuroraPalette.warning)
                        Text(l10n: "machine.anotherRunning")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(AuroraPalette.textSecondary)
                    }
                }
            }
        } else {
            centered { ProgressView().controlSize(.large).tint(AuroraPalette.accent) }
        }
    }

    /// The VM's screen. With iPhone Duo folded like a laptop it sits above the
    /// fold, as wide as the display, and the keyboard, when it's up, below.
    private var display: some View {
        GeometryReader { proxy in
            let open = Self.aboveFold(in: proxy, after: folds)
            DisplayView(bridge: runner.display, showsKeyboard: $showsKeyboard,
                        hasPicture: $hasPicture, openRegion: open)
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
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(AuroraPalette.accent)
                    Text(l10n: "machine.startingDesktop")
                        .font(AuroraType.headline)
                        .foregroundStyle(.white)
                    Text(l10n: "machine.bootInTerminal")
                        .font(AuroraType.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(22)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
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
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var needsJIT: some View {
        AuroraCard(tint: AuroraPalette.amber) {
            VStack(spacing: 14) {
                Image(systemName: "bolt.slash.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(AuroraPalette.warning)
                Text(l10n: "machine.jitOff.title")
                    .font(AuroraType.section)
                    .foregroundStyle(AuroraPalette.textPrimary)
                Text(verbatim: L10n.format("machine.jitOff.message", machine.name))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AuroraPalette.textSecondary)
                Button {
                    Task { await jit.turnOn(JITMethod(rawValue: jitMethod) ?? .standard) }
                } label: {
                    if jit.isTurningOn {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label {
                            Text(l10n: "jit.turnOn")
                        } icon: {
                            Image(systemName: "bolt.fill")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(AuroraPrimaryButtonStyle(fullWidth: true))
                .disabled(jit.isTurningOn)
            }
        }
    }

    private func ended(_ message: String, failed: Bool) -> some View {
        AuroraCard(tint: failed ? AuroraPalette.coral : AuroraPalette.cyan) {
            VStack(spacing: 14) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "power")
                    .font(.system(size: 38))
                    .foregroundStyle(failed ? AuroraPalette.danger : AuroraPalette.textSecondary)
                Text(verbatim: message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AuroraPalette.textSecondary)
                    .textSelection(.enabled)
                Button {
                    boot()
                } label: {
                    Label {
                        Text(l10n: "machine.startAgain")
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuroraPrimaryButtonStyle(fullWidth: true))

                if failed, let logURL {
                    ShareLink(item: logURL) {
                        Label {
                            Text(l10n: "logs.export")
                        } icon: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AuroraSecondaryButtonStyle(fullWidth: true))
                }
            }
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
                    .tint(AuroraPalette.accent)
                Text(verbatim: L10n.format("machine.starting", machine.name))
                    .font(AuroraType.headline)
                    .foregroundStyle(.white)
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
