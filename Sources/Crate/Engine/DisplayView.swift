// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

/// The VM's screen, scaled to fit, and the person's touches and keys as the
/// VM's tablet and keyboard. A tap clicks, a drag holds the button down, a long
/// press clicks the right button, and two fingers scroll. A mouse or trackpad
/// is the desktop's own: moving it moves the guest's pointer (iPadOS's hides
/// over the picture, where the guest draws one), its buttons click as
/// themselves, and its wheel or two-finger scroll scrolls what's under it.
/// Typing comes from iOS's keyboard (`showsKeyboard`), with a row of extra keys
/// above it (DisplayKeyBar), or a hardware one, as Linux key codes.
///
/// While an external display shows the screen (ExternalDisplay), this view is
/// a trackpad for the pointer there instead, as a laptop's is: one finger moves
/// it, a tap clicks, two fingers tapped click the right button or dragged
/// scroll, and holding a finger still, then moving it, drags. A mouse moves the
/// pointer across the display as it moves across the view.
struct DisplayView: UIViewRepresentable {
    let bridge: DisplayBridge
    @Binding var showsKeyboard: Bool
    /// Set once the first frame is on screen.
    @Binding var hasPicture: Bool
    /// Where in the view the picture goes, when not all of it is open: above
    /// the fold, with iPhone Duo half open like a laptop.
    var openRegion: CGRect?
    /// The Duo is unfolded and upright: use all of the inner display like a
    /// small iPad, including a guest desktop with a portrait resolution.
    var usesPortraitDesktop = false
    /// Immersive mode has no visible app chrome: three fingers on the guest
    /// bring it back without reserving a hot edge over Linux's own controls.
    var onShowControls: () -> Void = {}

    func makeUIView(context: Context) -> ScreenView {
        let view = ScreenView(bridge: bridge, usesPortraitDesktop: usesPortraitDesktop)
        view.onKeyboardHidden = { showsKeyboard = false }
        view.onShowControls = onShowControls
        let hasPicture = $hasPicture
        // No screen is the VM stopping, which MachineScreen shows in place
        // of this view.
        bridge.connect(.app) { [weak view] image in
            guard let image else { return }
            view?.show(image)
            if !hasPicture.wrappedValue { hasPicture.wrappedValue = true }
        }
        view.isTrackpad = bridge.isShownExternally
        bridge.onExternalChange = { [weak view] shown in view?.isTrackpad = shown }
        return view
    }

    func updateUIView(_ view: ScreenView, context: Context) {
        view.usesPortraitDesktop = usesPortraitDesktop
        view.onShowControls = onShowControls
        view.openRegion = openRegion
        if showsKeyboard, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !showsKeyboard {
            if view.isFirstResponder { _ = view.resignFirstResponder() }
            view.takeHardwareKeys()
        }
    }

    static func dismantleUIView(_ view: ScreenView, coordinator: ()) {
        view.bridge.disconnect(.app)
    }

    final class ScreenView: UIView, UIKeyInput, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
        let bridge: DisplayBridge
        var onKeyboardHidden: (() -> Void)?
        var onShowControls: (() -> Void)?
        private var imageSize = CGSize.zero
        private var scrollCarry = CGPoint.zero
        /// The buttons the guest last heard were down, which the pointer
        /// keeps as it moves: a wheel turned mid-drag doesn't let go.
        private var pressed: UInt32 = 0
        /// Where the mouse last hovered over the view.
        private var mouse: CGPoint?
        /// What only a mouse or trackpad drives, never a touch.
        private var pointerOnly: [UIGestureRecognizer] = []
        /// What a mouse's primary button drives as a finger does, but its
        /// others don't: they click as themselves (rightClicked).
        private var primaryOnly: [UIGestureRecognizer] = []
        /// Hides iPadOS's pointer over the picture.
        private lazy var pointerInteraction = UIPointerInteraction(delegate: self)
        /// The VM's screen, placed at screenRect.
        private let picture = CALayer()
        /// How much of the view's bottom the on-screen keyboard covers.
        private var keyboardOverlap: CGFloat = 0
        /// First responder while the on-screen keyboard is down, for a
        /// hardware keyboard's keys (takeHardwareKeys).
        private let keyCatcher = KeyCatcher()
        /// Whether this is a trackpad, while an external display shows the
        /// screen: the picture goes from here, the pointer is moved by how far
        /// a finger moves rather than to where it is, and a tap clicks where
        /// the pointer is.
        var isTrackpad = false {
            didSet {
                guard isTrackpad != oldValue else { return }
                AppLog.write("display: \(isTrackpad ? "a trackpad for the external display" : "the screen again")")
                // A drag the change cuts short lets go, and a finger already
                // down starts again: a trackpad move doesn't go on as a drag
                // across the picture, nor a drag as a trackpad move.
                if pressed != 0 { press(0) }
                for gesture in fingerGestures where gesture.state == .began || gesture.state == .changed {
                    gesture.isEnabled = false
                    gesture.isEnabled = true
                }
                twoFingerTap.isEnabled = isTrackpad
                // Where the mouse was is in the other way of mapping the view.
                mouse = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                placePicture()
                CATransaction.commit()
            }
        }
        /// What a finger drives, so a change of mode can stop what's going on.
        private var fingerGestures: [UIGestureRecognizer] = []
        /// Where a finger held for a drag last was, on the trackpad.
        private var dragFrom = CGPoint.zero
        /// The trackpad's right click; only on while this is one.
        private let twoFingerTap = UITapGestureRecognizer()
        /// What shows on the view while it's a trackpad.
        private let surface = TrackpadSurface()
        /// See DisplayView.openRegion. The picture moves as the iPhone folds,
        /// and the desktop takes the shape of where it now goes.
        var openRegion: CGRect? {
            didSet {
                guard openRegion != oldValue else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.3)
                placePicture()
                CATransaction.commit()
                fit()
            }
        }

        var usesPortraitDesktop: Bool {
            didSet {
                guard usesPortraitDesktop != oldValue else { return }
                fit()
            }
        }

        init(bridge: DisplayBridge, usesPortraitDesktop: Bool) {
            self.bridge = bridge
            self.usesPortraitDesktop = usesPortraitDesktop
            super.init(frame: .zero)
            // UIPasteControl reads the clipboard only after its explicit tap,
            // avoiding iOS's cross-app paste privacy prompt while accepting
            // the plain text Crate can type through the virtual keyboard.
            pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
            backgroundColor = .black
            picture.magnificationFilter = .linear
            layer.addSublayer(picture)
            surface.isHidden = true
            addSubview(surface)
            isMultipleTouchEnabled = true
            keyCatcher.owner = self
            addSubview(keyCatcher)

            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged))
            drag.maximumNumberOfTouches = 1
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
            scroll.minimumNumberOfTouches = 2
            scroll.maximumNumberOfTouches = 2
            tap.require(toFail: hold)

            // A mouse's or trackpad's scrolling comes as scroll events, which a
            // pan takes only when asked; allowing it no touches keeps it off
            // the fingers' gestures. Wheel clicks and a trackpad's glide are
            // told apart only by which pan iPadOS hands them to.
            let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheeled))
            wheel.allowedScrollTypesMask = .discrete
            let glide = UIPanGestureRecognizer(target: self, action: #selector(glided))
            glide.allowedScrollTypesMask = .continuous
            for pan in [wheel, glide] {
                pan.allowedTouchTypes = []
                pan.maximumNumberOfTouches = 0
            }
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered))
            // A mouse's click comes as a touch, its buttons in the event.
            // buttonMaskRequired is checked only for a mouse, so a finger's tap
            // would do for these too, but tap takes it first.
            let rightClick = UITapGestureRecognizer(target: self, action: #selector(rightClicked))
            rightClick.buttonMaskRequired = .secondary
            let middleClick = UITapGestureRecognizer(target: self, action: #selector(middleClicked))
            middleClick.buttonMaskRequired = .button(3)
            rightClick.require(toFail: tap)
            middleClick.require(toFail: tap)
            pointerOnly = [wheel, glide, hover]
            primaryOnly = [drag, hold]
            fingerGestures = [tap, drag, hold, scroll]
            twoFingerTap.addTarget(self, action: #selector(twoFingerTapped))
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.isEnabled = false
            let showControls = UITapGestureRecognizer(target: self, action: #selector(showControls))
            showControls.numberOfTouchesRequired = 3
            showControls.cancelsTouchesInView = false

            for recognizer in [tap, drag, hold, scroll, wheel, glide, hover, rightClick, middleClick,
                               twoFingerTap, showControls] {
                recognizer.delegate = self
                addGestureRecognizer(recognizer)
            }
            addInteraction(pointerInteraction)

            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(keyboardWillChange),
                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            center.addObserver(self, selector: #selector(keyboardWillHide),
                               name: UIResponder.keyboardWillHideNotification, object: nil)
            center.addObserver(self, selector: #selector(keyboardDidHide),
                               name: UIResponder.keyboardDidHideNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func show(_ image: CGImage) {
            let size = CGSize(width: image.width, height: image.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.contents = image
            if size != imageSize {
                imageSize = size
                placePicture()
            }
            CATransaction.commit()
        }

        /// The picture to screenRect, and iPadOS's pointer told where it now
        /// hides (pointerInteraction(_:regionFor:defaultRegion:)).
        private func placePicture() {
            picture.frame = screenRect
            picture.isHidden = isTrackpad
            surface.isHidden = !isTrackpad
            surface.frame = surfaceRect
            pointerInteraction.invalidate()
        }

        /// The trackpad's surface: the open region (all of the view, or above
        /// the fold), less what the keyboard covers, inside the safe area.
        private var surfaceRect: CGRect {
            var region = (openRegion.map { $0.intersection(bounds) } ?? bounds)
                .inset(by: safeAreaInsets)
            if keyboardOverlap > 0 {
                region.size.height = max(0, min(region.maxY, bounds.height - keyboardOverlap) - region.minY)
            }
            return region.insetBy(dx: 12, dy: 12)
        }

        /// The guest's desktop takes the view's shape (DisplayBridge.fit), but
        /// not while the keyboard shows: it covers the screen, and a size made
        /// around it would stay after it goes. Folding refits whatever the
        /// keyboard: it stays below the fold.
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            placePicture()
            CATransaction.commit()
            if keyboardOverlap == 0 { fit() }
        }

        /// The guest's desktop takes the shape of where the picture goes: the
        /// view, or above the fold, which is its own shape and not remembered.
        private func fit() {
            if let openRegion {
                bridge.fit(openRegion.intersection(bounds).size, window: nil)
            } else {
                bridge.fit(bounds.size, window: window?.bounds.size ?? bounds.size,
                           portrait: usesPortraitDesktop)
            }
        }

        /// The keyboard came up or changed size: the picture moves clear of it.
        @objc private func keyboardWillChange(_ note: Notification) {
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let screen = window?.windowScene?.screen else { return }
            let frame = convert(end, from: screen.coordinateSpace)
            moveClearOfKeyboard(max(0, bounds.maxY - frame.minY), note)
        }

        @objc private func keyboardWillHide(_ note: Notification) {
            moveClearOfKeyboard(0, note)
        }

        /// The size it's laid out at now, in case the iPhone turned meanwhile.
        @objc private func keyboardDidHide() {
            fit()
        }

        private func moveClearOfKeyboard(_ overlap: CGFloat, _ note: Notification) {
            guard overlap != keyboardOverlap else { return }
            keyboardOverlap = overlap
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            placePicture()
            CATransaction.commit()
        }

        // MARK: Touch as the tablet

        /// Where the screen sits in the view: scaled to fit the open region
        /// (all of the view, or the part above the fold) and centred in it, or
        /// with the keyboard up, centred in what the keyboard leaves showing
        /// (at the top, if it's taller than that), at the same size.
        private var screenRect: CGRect {
            let region = openRegion.map { $0.intersection(bounds) } ?? bounds
            guard imageSize.width > 0, imageSize.height > 0, !region.isEmpty else { return bounds }
            let scale = min(region.width / imageSize.width, region.height / imageSize.height)
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let bottom = keyboardOverlap > 0 ? min(region.maxY, bounds.height - keyboardOverlap) : region.maxY
            let open = bottom - region.minY
            let y = region.minY + max(0, (open - size.height) / 2)
            return CGRect(x: region.midX - size.width / 2, y: y, width: size.width, height: size.height)
        }

        private func point(_ recognizer: UIGestureRecognizer, buttons: UInt32) {
            // Back from something else that took the keys, such as a sheet.
            takeHardwareKeys()
            move(to: recognizer.location(in: self), buttons: buttons)
        }

        /// The guest's pointer to `location`, with `buttons` down, or those
        /// already down. It doesn't take the keys, as point does: a mouse
        /// passing over the picture, or scrolling it, isn't a click on it.
        private func move(to location: CGPoint, buttons: UInt32? = nil) {
            if let buttons { pressed = buttons }
            let area = pointerArea
            bridge.pointer(x: (location.x - area.minX) / area.width,
                           y: (location.y - area.minY) / area.height, buttons: pressed)
        }

        /// What a place in the view is taken across: the picture, or on a
        /// trackpad, where there's none, all of the view, so a mouse reaches
        /// every corner of the external display's screen.
        private var pointerArea: CGRect {
            isTrackpad ? bounds : screenRect
        }

        // MARK: Touch as a trackpad

        /// `buttons` down where the pointer is.
        private func press(_ buttons: UInt32) {
            pressed = buttons
            let at = bridge.pointerPosition
            bridge.pointer(x: at.x, y: at.y, buttons: buttons)
        }

        private func clickAtPointer(_ buttons: UInt32) {
            takeHardwareKeys()
            press(0)
            press(buttons)
            press(0)
        }

        /// The pointer moved by a finger's `moved` points, going `speed`
        /// points a second: a guest pixel and a half a point, up to three
        /// times that when the finger flicks, so a slow move is precise and a
        /// quick one crosses the screen.
        private func nudge(by moved: CGPoint, speed: CGFloat) {
            let screen = imageSize.width > 0 ? imageSize : CGSize(width: 1920, height: 1080)
            let gain = 1.5 * (1 + min(max((speed - 150) / 500, 0), 2))
            let at = bridge.pointerPosition
            bridge.pointer(x: at.x + moved.x * gain / screen.width,
                           y: at.y + moved.y * gain / screen.height, buttons: pressed)
        }

        @objc private func twoFingerTapped(_ recognizer: UITapGestureRecognizer) {
            clickAtPointer(2)
        }

        @objc private func showControls(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onShowControls?()
        }

        private func click(_ recognizer: UIGestureRecognizer, buttons: UInt32) {
            point(recognizer, buttons: 0)
            point(recognizer, buttons: buttons)
            point(recognizer, buttons: 0)
        }

        /// On a trackpad, where the pointer is, which is where a mouse
        /// clicking is too: it moved the pointer there on its way.
        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            if isTrackpad {
                clickAtPointer(1)
            } else {
                click(recognizer, buttons: 1)
            }
        }

        /// On a trackpad, the pointer moves with the finger, no button down.
        @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
            // Stopped by a change of mode: whatever was down lets go, where
            // the pointer is.
            if recognizer.state == .cancelled {
                if pressed != 0 { press(0) }
                return
            }
            if isTrackpad {
                if recognizer.state == .began { takeHardwareKeys() }
                let moved = recognizer.translation(in: self)
                recognizer.setTranslation(.zero, in: self)
                let velocity = recognizer.velocity(in: self)
                nudge(by: moved, speed: hypot(velocity.x, velocity.y))
                return
            }
            // A mouse dragging sends no hovers: its place is where it drags,
            // so a wheel turned mid-drag scrolls there, button still down.
            mouse = recognizer.location(in: self)
            switch recognizer.state {
            case .began, .changed: point(recognizer, buttons: 1)
            default: point(recognizer, buttons: 0)
            }
        }

        /// On a trackpad, a finger held still holds the button down, with a
        /// tap of the Taptic Engine to say so, and moving it drags; lifting it
        /// lets go. Otherwise it's the right button, clicked.
        @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
            if isTrackpad {
                let location = recognizer.location(in: self)
                switch recognizer.state {
                case .began:
                    takeHardwareKeys()
                    dragFrom = location
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    press(1)
                case .changed:
                    nudge(by: CGPoint(x: location.x - dragFrom.x, y: location.y - dragFrom.y), speed: 0)
                    dragFrom = location
                default:
                    press(0)
                }
                return
            }
            guard recognizer.state == .began else { return }
            click(recognizer, buttons: 2)
        }

        /// On a trackpad, what's under the pointer scrolls; otherwise what's
        /// under the fingers.
        @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began {
                scrollCarry = .zero
                if !isTrackpad { point(recognizer, buttons: 0) }
            }
            scrollByDistance(recognizer)
        }

        /// A trackpad's two-finger scroll, or a Magic Mouse's, as two fingers
        /// on the screen.
        @objc private func glided(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began {
                scrollCarry = .zero
                moveToMouse(recognizer)
            }
            scrollByDistance(recognizer)
        }

        /// A mouse's wheel: a notch a click, the content following the wheel as
        /// in iPadOS's own scroll views. Apple doesn't say how far a click
        /// moves the pan, so it's the scroll events that move it that count,
        /// taken to be one a click, not the distance.
        @objc private func wheeled(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { moveToMouse(recognizer) }
            let moved = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            let notch = { (distance: CGFloat) -> Int32 in distance < 0 ? 1 : distance > 0 ? -1 : 0 }
            let dx = notch(moved.x), dy = notch(moved.y)
            if dx != 0 || dy != 0 { bridge.scroll(dx: dx, dy: dy) }
        }

        /// The guest's pointer to the mouse, so its wheel or trackpad scrolls
        /// what's under it, though a finger may have moved the pointer since.
        /// That's where it last hovered: a scroll pan's own location runs on
        /// ahead with the scrolling. Only before any hover is it all there is.
        private func moveToMouse(_ scroll: UIPanGestureRecognizer) {
            move(to: mouse ?? scroll.location(in: self))
        }

        /// The mouse moving with no button down, when iPadOS sends no touches.
        /// Its going (leaving the view, say) isn't a move: the pointer stays
        /// where it last was, not where the end puts it, the view's corner.
        @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let location = recognizer.location(in: self)
                mouse = location
                move(to: location)
            default: break
            }
        }

        /// A mouse's right button, or a trackpad's two-finger click, as the
        /// long press.
        @objc private func rightClicked(_ recognizer: UITapGestureRecognizer) {
            click(recognizer, buttons: 2)
        }

        @objc private func middleClicked(_ recognizer: UITapGestureRecognizer) {
            click(recognizer, buttons: 4)
        }

        /// A mouse's other buttons pressed aren't the left one held down, or a
        /// long press: they click as themselves, and nothing else sees them.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            !primaryOnly.contains(recognizer) || event.buttonMask.isSubset(of: .primary)
        }

        /// The mouse moving or scrolling goes along with whatever else is
        /// going on, such as a drag the wheel turns in.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            pointerOnly.contains(recognizer) || pointerOnly.contains(other)
        }

        /// A wheel notch per 20 points, the content following the fingers.
        private func scrollByDistance(_ recognizer: UIPanGestureRecognizer) {
            let moved = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            scrollCarry.x += moved.x
            scrollCarry.y += moved.y
            let notch: CGFloat = 20
            let dx = Int32(-scrollCarry.x / notch), dy = Int32(-scrollCarry.y / notch)
            if dx != 0 || dy != 0 {
                bridge.scroll(dx: dx, dy: dy)
                scrollCarry.x += CGFloat(dx) * notch
                scrollCarry.y += CGFloat(dy) * notch
            }
        }

        // MARK: iPadOS's pointer

        /// Hidden over the picture, where the guest draws its own, so there's
        /// one; over the bars beside it, as anywhere else.
        func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                                defaultRegion: UIPointerRegion) -> UIPointerRegion? {
            let rect = pointerArea
            return rect.contains(request.location) ? UIPointerRegion(rect: rect) : nil
        }

        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            .hidden()
        }

        // MARK: Keys as the keyboard

        override var canBecomeFirstResponder: Bool { true }

        /// Only a first responder gets a hardware keyboard's presses, and this
        /// view as one brings up the on-screen keyboard too. So while that's
        /// down, keyCatcher is first responder instead.
        func takeHardwareKeys() {
            guard window != nil, !isFirstResponder, !keyCatcher.isFirstResponder else { return }
            keyCatcher.becomeFirstResponder()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            takeHardwareKeys()
        }

        /// Esc, Ctrl, Super, Tab, arrows and the rest, above the keyboard.
        private lazy var keyBar: DisplayKeyBar = {
            let bar = DisplayKeyBar()
            bar.onKey = { [weak self] code, down in self?.bridge.key(code, down: down) }
            bar.onDismiss = { [weak self] in _ = self?.resignFirstResponder() }
            bar.setPasteTarget(self)
            return bar
        }()

        override var inputAccessoryView: UIView? { keyBar }

        override func resignFirstResponder() -> Bool {
            keyBar.releaseAll()
            let resigned = super.resignFirstResponder()
            if resigned { onKeyboardHidden?() }
            return resigned
        }

        var hasText: Bool { true }

        func insertText(_ text: String) {
            withLatchedModifiers {
                for character in text {
                    guard let stroke = LinuxKeys.stroke(for: character) else { continue }
                    if stroke.shift { bridge.key(LinuxKeys.leftShift, down: true) }
                    bridge.key(stroke.code, down: true)
                    bridge.key(stroke.code, down: false)
                    if stroke.shift { bridge.key(LinuxKeys.leftShift, down: false) }
                }
            }
        }

        func deleteBackward() {
            withLatchedModifiers {
                bridge.key(14, down: true)
                bridge.key(14, down: false)
            }
        }

        /// Receives text from the system Paste control in DisplayKeyBar. The
        /// item provider is loaded without ever recording the clipboard text.
        override func paste(itemProviders: [NSItemProvider]) {
            guard let provider = itemProviders.first(where: {
                $0.canLoadObject(ofClass: NSString.self)
            }) else { return }
            provider.loadObject(ofClass: NSString.self) { [weak self] object, error in
                guard error == nil, let text = object as? NSString else {
                    AppLog.write("clipboard: could not load pasted text")
                    return
                }
                self?.bridge.typeClipboardText(text as String)
            }
        }

        /// The key bar's latched Ctrl and Super, held around a keystroke from
        /// the on-screen keyboard.
        private func withLatchedModifiers(_ keystroke: () -> Void) {
            let modifiers = keyBar.takeModifiers()
            for code in modifiers { bridge.key(code, down: true) }
            keystroke()
            for code in modifiers.reversed() { bridge.key(code, down: false) }
        }

        /// The key bar's latched Ctrl and Super, held while a hardware key is.
        private var latchedForPress: [UInt16] = []

        // What a terminal wants from the on-screen keyboard: nothing changed.
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
        var keyboardType: UIKeyboardType = .asciiCapable
        /// Lets iOS offer verification codes it detects in Messages and Mail
        /// above the keyboard. Selecting one calls insertText just like typing,
        /// so the focused field inside the VM receives it without Crate reading
        /// either app or learning what the code was.
        var textContentType: UITextContentType? = .oneTimeCode

        /// A hardware keyboard: each key down and up as itself, modifiers
        /// included, which iOS's text input would lose.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !forward(presses, down: true) { super.pressesBegan(presses, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !forward(presses, down: false) { super.pressesEnded(presses, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !forward(presses, down: false) { super.pressesCancelled(presses, with: event) }
        }

        private func forward(_ presses: Set<UIPress>, down: Bool) -> Bool {
            var handled = false
            for press in presses {
                guard let key = press.key, let code = LinuxKeys.code(for: key.keyCode) else { continue }
                let isModifier = LinuxKeys.modifiers.contains(code)
                if down, !isModifier {
                    latchedForPress = keyBar.takeModifiers()
                    for modifier in latchedForPress { bridge.key(modifier, down: true) }
                }
                bridge.key(code, down: down)
                if !down, !isModifier {
                    for modifier in latchedForPress.reversed() { bridge.key(modifier, down: false) }
                    latchedForPress = []
                }
                handled = true
            }
            return handled
        }
    }

    /// A first responder that isn't text input, so it brings up no keyboard,
    /// and hands its presses to ScreenView. It's left out of ScreenView's
    /// responder chain, or UIKit would show ScreenView's key bar for it.
    final class KeyCatcher: UIView {
        weak var owner: ScreenView?

        override var canBecomeFirstResponder: Bool { true }
        override var next: UIResponder? { owner?.next }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            owner?.pressesBegan(presses, with: event)
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            owner?.pressesEnded(presses, with: event)
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            owner?.pressesCancelled(presses, with: event)
        }
    }

    /// The trackpad, drawn: a panel saying the desktop is on the external
    /// display and how to point at it. Touches pass through to ScreenView,
    /// whose gestures it is. The how-to goes when there's too little room.
    final class TrackpadSurface: UIView {
        private let icon = UIImageView(image: UIImage(systemName: "display"))
        private let title = UILabel()
        private let hint = UILabel()
        private let stack: UIStackView

        override init(frame: CGRect) {
            stack = UIStackView(arrangedSubviews: [icon, title, hint])
            super.init(frame: frame)
            isUserInteractionEnabled = false
            overrideUserInterfaceStyle = .dark
            backgroundColor = UIColor(white: 1, alpha: 0.06)
            layer.cornerRadius = 22
            layer.cornerCurve = .continuous
            layer.borderWidth = 1
            layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor

            icon.tintColor = .tertiaryLabel
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title1)
            icon.contentMode = .scaleAspectFit
            title.text = "Trackpad"
            title.font = .preferredFont(forTextStyle: .headline)
            title.textColor = .secondaryLabel
            hint.text = "The desktop is on the external display.\n"
                + "One finger moves the pointer, and a tap clicks.\n"
                + "Two fingers tap to right-click, or move to scroll.\n"
                + "Hold a finger still, then move it, to drag."
            hint.font = .preferredFont(forTextStyle: .footnote)
            hint.textColor = .tertiaryLabel
            hint.numberOfLines = 0
            hint.textAlignment = .center
            for label in [title, hint] { label.adjustsFontForContentSizeCategory = true }

            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
                stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            hint.isHidden = bounds.height < 200
            icon.isHidden = bounds.height < 110
            title.isHidden = bounds.height < 40
            super.layoutSubviews()
        }
    }
}
