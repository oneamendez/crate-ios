// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

enum ExternalDisplayLayoutMode: String, CaseIterable, Identifiable {
    case sharpCentered
    case fullUltrawide

    var id: Self { self }

    var title: String {
        switch self {
        case .sharpCentered: "Sharp Centered"
        case .fullUltrawide: "Full 32:9"
        }
    }

    var icon: String {
        switch self {
        case .sharpCentered: "rectangle"
        case .fullUltrawide: "arrow.left.and.right"
        }
    }

    static let standard = Self.sharpCentered
}

/// Chooses an external display's mode before UIKit associates the screen with
/// its scene. Once the external window exists, iOS ignores currentMode writes
/// on some devices even though the requested mode appears in availableModes.
@MainActor
final class CrateApplicationDelegate: NSObject, UIApplicationDelegate {
    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConnected(_:)),
            name: UIScreen.didConnectNotification,
            object: nil
        )
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // A monitor already attached when Crate launches doesn't send us a new
        // connection notification. The array's order is not stable on recent
        // iOS versions, so inspect each screen; prepare returns immediately
        // when its current/preferred mode is already the right one.
        for screen in UIScreen.screens {
            ExternalDisplay.prepare(screen)
        }
        return true
    }

    @objc private func screenConnected(_ notification: Notification) {
        guard let screen = notification.object as? UIScreen else { return }
        ExternalDisplay.prepare(screen)
    }
}

/// A connected display, by cable or AirPlay, as the VM's own screen rather
/// than a mirror of the iPhone's.
///
/// iOS mirrors an app onto a connected display until the app puts a window of
/// its own in the display's scene, one of the external display's role
/// (UISceneSession.Role.windowExternalDisplayNonInteractive). Up to iOS 26 iOS
/// offers that scene to every app, which takes it with a configuration for the
/// role in Info.plist (project.yml); crate's one scene at a time
/// (UIApplicationSupportsMultipleScenes off) doesn't stop it. From iOS 27, to
/// an app built with its SDK, iOS offers it only while one of the app's view
/// controllers has registered a scene accessory for it, which
/// ExternalDisplayRegistration does while MachineScreen is up. Either way the
/// scene comes to ExternalDisplaySceneDelegate, and the rest is the same.
///
/// crate's window goes on the display while MachineScreen is up, and comes off
/// once it's gone, when iOS mirrors again: crate's other screens are the
/// iPhone's. While it's on, the display shows the VM's screen, as big as fits
/// with its shape kept, and the guest's desktop takes the display's shape and
/// size instead of the view's (DisplayBridge.fitExternal). It's a picture only:
/// the iPhone or iPad stays where the person touches and types, over its own
/// copy of the picture.
///
/// An iPad using the display as a second desktop (Stage Manager) can have
/// crate's own window there instead, and the VM's screen takes that window's
/// shape as it would anywhere else.
@MainActor
final class ExternalDisplay {
    static let shared = ExternalDisplay()

    /// The VM's screen, while MachineScreen is up.
    private var bridge: DisplayBridge?
    /// The display's scene, while one is connected.
    private var scene: UIWindowScene?
    /// crate's window on it, while there are both.
    private var window: UIWindow?

    func setLayoutMode(_ mode: ExternalDisplayLayoutMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: SettingsKey.externalDisplayLayout)
        AppLog.write("external display: layout set to \(mode.rawValue)")
        fitBridgeToScreen()
    }

    /// MachineScreen is up, its VM's screen in `bridge`, or gone (nil).
    func show(_ bridge: DisplayBridge?) {
        guard bridge !== self.bridge else { return }
        takeWindowOff()
        self.bridge = bridge
        putWindowOn()
    }

    fileprivate func connected(_ scene: UIWindowScene) {
        takeWindowOff()
        self.scene = scene
        let screen = scene.screen
        let before = screen.currentMode?.size
        let pixels = Self.pixels(of: screen)
        let preferred = screen.preferredMode?.size
        let native = screen.nativeBounds.size
        let available = screen.availableModes
            .map { "\(Int($0.size.width))x\(Int($0.size.height))/pa\($0.pixelAspectRatio)" }
            .joined(separator: ", ")
        AppLog.write("external display: connected, \(Int(pixels.width))x\(Int(pixels.height)) px"
                     + "; before \(before.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown")"
                     + "; preferred \(preferred.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown")"
                     + "; native \(Int(native.width))x\(Int(native.height)); available [\(available)]")
        putWindowOn()
    }

    fileprivate func disconnected(_ scene: UIWindowScene) {
        guard scene === self.scene else { return }
        AppLog.write("external display: disconnected")
        takeWindowOff()
        self.scene = nil
    }

    private func putWindowOn() {
        guard let scene, let bridge, window == nil else { return }
        let screen = ExternalScreenController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = screen
        window.overrideUserInterfaceStyle = .dark
        // Shown, not made key: the keys stay with the iPhone's window.
        window.isHidden = false
        self.window = window
        bridge.connect(.external) { [weak screen] image in screen?.show(image) }
        fitBridgeToScreen()
        // On some iOS builds a screen that was mirroring rejects currentMode
        // until Crate's external window is visible, despite UIKit's documented
        // preference for selecting it beforehand. Retry briefly after taking
        // ownership and update the guest as soon as the mode sticks.
        settleMode()
    }

    private func takeWindowOff() {
        guard let window else { return }
        window.isHidden = true
        self.window = nil
        bridge?.disconnect(.external)
        bridge?.fitExternal(nil)
    }

    private func settleMode() {
        guard let scene, window != nil,
              let requested = Self.bestMode(for: scene.screen) else { return }
        let screen = scene.screen
        let before = screen.currentMode?.size
        guard before?.width != requested.size.width || before?.height != requested.size.height else { return }
        screen.currentMode = requested
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak screen] in
            guard let self, let screen, self.scene?.screen === screen, self.window != nil else { return }
            let now = screen.currentMode?.size
            let accepted = now?.width == requested.size.width && now?.height == requested.size.height
            AppLog.write("external display: post-window mode requested "
                         + "\(Int(requested.size.width))x\(Int(requested.size.height)); now "
                         + "\(now.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown")")
            if accepted {
                self.fitBridgeToScreen()
            } else {
                self.settleHighResolutionMode()
            }
        }
    }

    /// If iOS refuses the panel's 32:9 timing, try its largest conventional
    /// timing. The LG can accept a 4K 16:9 signal and expand it to the panel;
    /// fitBridgeToScreen keeps the guest at 32:9 and compensates for that
    /// expansion, yielding much sharper text than a 1080p signal.
    private func settleHighResolutionMode() {
        guard let scene, window != nil,
              let requested = Self.highResolutionMode(for: scene.screen) else { return }
        let screen = scene.screen
        let before = screen.currentMode?.size
        guard before?.width != requested.size.width || before?.height != requested.size.height else { return }
        screen.currentMode = requested
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak screen] in
            guard let self, let screen, self.scene?.screen === screen, self.window != nil else { return }
            let now = screen.currentMode?.size
            let accepted = now?.width == requested.size.width && now?.height == requested.size.height
            AppLog.write("external display: high-resolution fallback requested "
                         + "\(Int(requested.size.width))x\(Int(requested.size.height)); now "
                         + "\(now.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown")")
            if accepted { self.fitBridgeToScreen() }
        }
    }

    /// Fit the guest to the signal. When iOS exposes an ultrawide mode but
    /// refuses to select it, the connected LG still expands its 16:9 input to
    /// fill the 32:9 panel. Give the guest the advertised 32:9 canvas and
    /// squeeze it into that signal; the monitor's expansion reverses the
    /// squeeze, restoring square pixels and filling the panel.
    private func fitBridgeToScreen() {
        guard let scene, let bridge else { return }
        let rawMode = UserDefaults.standard.string(forKey: SettingsKey.externalDisplayLayout)
        let mode = ExternalDisplayLayoutMode(rawValue: rawMode ?? "") ?? .standard
        let layout = Self.layout(for: scene.screen, mode: mode)
        (window?.rootViewController as? ExternalScreenController)?
            .setAnamorphic(layout.anamorphic)
        bridge.fitExternal(layout.pixels)
        if layout.anamorphic {
            AppLog.write("external display: full 32:9 canvas "
                         + "\(Int(layout.pixels.width))x\(Int(layout.pixels.height)) over "
                         + "\(Int(Self.pixels(of: scene.screen).width))x\(Int(Self.pixels(of: scene.screen).height))")
        }
    }

    /// The display's size in pixels, in the mode it's in.
    private static func pixels(of screen: UIScreen) -> CGSize {
        screen.currentMode?.size ?? screen.nativeBounds.size
    }

    private static func layout(
        for screen: UIScreen,
        mode: ExternalDisplayLayoutMode
    ) -> (pixels: CGSize, anamorphic: Bool) {
        let current = pixels(of: screen)
        let currentLong = max(current.width, current.height)
        let currentShort = min(current.width, current.height)
        guard currentShort > 0 else { return (current, false) }

        // A real ultrawide timing needs no compensation. When iOS exposes
        // only a conventional signal, Full 32:9 renders a 32:9 guest canvas
        // and squeezes it into that signal. The monitor's Full Wide setting
        // performs the inverse expansion, restoring square windows and text.
        if currentLong / currentShort >= 3 {
            return (current, false)
        }
        if mode == .fullUltrawide {
            return (
                CGSize(width: currentShort * (32.0 / 9.0), height: currentShort),
                true
            )
        }
        return (current, false)
    }

    /// Apply the selected mode while the screen is not yet associated with an
    /// external window, as required by UIKit.
    fileprivate static func prepare(_ screen: UIScreen) {
        let before = screen.currentMode?.size
        guard let best = bestMode(for: screen) else { return }
        guard before?.width != best.size.width || before?.height != best.size.height else { return }
        screen.currentMode = best
        var after = screen.currentMode?.size
        AppLog.write("external display: prepared "
                     + "\(Int(best.size.width))x\(Int(best.size.height)); before "
                     + "\(before.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown"); now "
                     + "\(after.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown")")
        if (after?.width != best.size.width || after?.height != best.size.height),
           let highResolution = highResolutionMode(for: screen) {
            screen.currentMode = highResolution
            after = screen.currentMode?.size
            AppLog.write("external display: prepared high-resolution fallback "
                         + "\(Int(highResolution.size.width))x\(Int(highResolution.size.height)); now "
                         + "\(after.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown")")
        }
    }

    /// UIKit can mislabel 1920x1080 as an ultrawide panel's preferred/native
    /// mode while still advertising a better mode in availableModes. Prefer
    /// an explicit 3:1-or-wider timing first, then the largest conventional
    /// timing within a 4K budget (for HDMI adapters that expose 4K but mark
    /// 1080p as preferred), and use UIKit's preferred mode only as the final
    /// compatibility fallback.
    private static func bestMode(for screen: UIScreen) -> UIScreenMode? {
        ultrawideMode(for: screen)
            ?? highResolutionMode(for: screen)
            ?? screen.preferredMode
    }

    private static func ultrawideMode(for screen: UIScreen) -> UIScreenMode? {
        let fourKPixelBudget = CGFloat(3840 * 2160)
        return screen.availableModes.filter { mode in
            let width = max(mode.size.width, mode.size.height)
            let height = min(mode.size.width, mode.size.height)
            return height > 0 && width / height >= 3 && width * height <= fourKPixelBudget
        }.max { lhs, rhs in
            lhs.size.width * lhs.size.height < rhs.size.width * rhs.size.height
        }
    }

    private static func highResolutionMode(for screen: UIScreen) -> UIScreenMode? {
        let fourKPixelBudget = CGFloat(4096 * 2160)
        return screen.availableModes.filter { mode in
            let width = max(mode.size.width, mode.size.height)
            let height = min(mode.size.width, mode.size.height)
            let aspect = height > 0 ? width / height : 0
            return aspect >= 1.7 && aspect < 3 && width * height <= fourKPixelBudget
        }.max { lhs, rhs in
            lhs.size.width * lhs.size.height < rhs.size.width * rhs.size.height
        }
    }
}

/// The external display's scene, from Info.plist up to iOS 26 and from
/// ExternalDisplayRegistration's scene accessory after, handed to
/// ExternalDisplay.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        ExternalDisplay.shared.connected(scene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let scene = scene as? UIWindowScene else { return }
        ExternalDisplay.shared.disconnected(scene)
    }
}

/// What the external display shows: the VM's screen on black, as big as fits
/// with its shape kept. Before there's one, or once the VM has stopped, the
/// app's name, small.
final class ExternalScreenController: UIViewController {
    private let picture = CALayer()
    private let name = UILabel()
    private var anamorphic = false

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        picture.contentsGravity = anamorphic ? .resize : .resizeAspect
        updateSamplingFilter()
        view.layer.addSublayer(picture)
        name.text = "crate"
        name.font = .preferredFont(forTextStyle: .headline)
        name.textColor = .secondaryLabel
        name.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(name)
        NSLayoutConstraint.activate([
            name.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            name.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        self.view = view
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = view.bounds
        CATransaction.commit()
    }

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
        name.isHidden = image != nil
    }

    func setAnamorphic(_ enabled: Bool) {
        anamorphic = enabled
        guard isViewLoaded else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contentsGravity = enabled ? .resize : .resizeAspect
        updateSamplingFilter()
        CATransaction.commit()
    }

    /// Even the exact 3840 -> 1920 horizontal squeeze needs filtering: nearest
    /// sampling drops alternating one-pixel font strokes and makes text look
    /// broken. Smooth both the anamorphic fallback and normal display scaling;
    /// the negotiated output timing, not this layer, is the sharpness ceiling.
    private func updateSamplingFilter() {
        picture.minificationFilter = .linear
        picture.magnificationFilter = .linear
    }
}

/// MachineScreen's part: while it's up, a connected display shows its VM's
/// screen. From iOS 27 it's also what has iOS offer the display's scene at
/// all, which takes a scene accessory registered on one of the app's view
/// controllers (UIViewController.registerSceneAccessory): this one. SwiftUI's
/// own sceneAccessory would make a scene of its own, where UIKit's brings it
/// to the same delegate as Info.plist does up to iOS 26.
struct ExternalDisplayRegistration: UIViewControllerRepresentable {
    let bridge: DisplayBridge

    func makeUIViewController(context: Context) -> Registrar {
        ExternalDisplay.shared.show(bridge)
        return Registrar()
    }

    func updateUIViewController(_ registrar: Registrar, context: Context) {}

    static func dismantleUIViewController(_ registrar: Registrar, coordinator: ()) {
        ExternalDisplay.shared.show(nil)
        registrar.unregister()
    }

    final class Registrar: UIViewController {
        /// The UISceneAccessoryRegistration, from iOS 27.
        private var registration: AnyObject?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            guard #available(iOS 27.0, *) else { return }
            // Info.plist's configuration for the role, with its delegate named
            // here too, so it doesn't depend on the name being found there.
            let configuration = UISceneConfiguration(name: "External Display",
                                                     sessionRole: .windowExternalDisplayNonInteractive)
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
            registration = registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration))
        }

        func unregister() {
            if #available(iOS 27.0, *), let registration = registration as? UISceneAccessoryRegistration {
                unregisterSceneAccessory(registration)
            }
            registration = nil
        }
    }
}
