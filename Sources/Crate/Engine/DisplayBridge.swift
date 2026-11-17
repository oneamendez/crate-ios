// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import CrateEngine
import Foundation

/// The VM's screen, between crate's GPU thread and the display view, and the
/// view's input on its way back in.
///
/// crate hands over a frame with the part that changed marked: that part is
/// copied into a buffer of the whole screen, and the main thread is handed a
/// picture of it, a frame at a time however fast they come. Up to two viewers
/// are handed the same picture: the app's own view, and an external display
/// (ExternalDisplay). crate makes frames only while the display is active,
/// which it is while either viewer shows it.
final class DisplayBridge: @unchecked Sendable {
    /// Who's showing the screen.
    enum Viewer: Hashable {
        /// The display view, on the iPhone or iPad itself.
        case app
        /// A connected display, while it shows the VM's screen.
        case external
    }

    private let lock = NSLock()
    /// Clipboard text is a burst of virtual key presses. Keep bursts in order
    /// and off the main thread, with a small gap so a busy guest does not lose
    /// characters as it can when every event arrives in one run-loop turn.
    private let textInputQueue = DispatchQueue(label: "crate.display.text-input", qos: .userInitiated)
    private var machine: OpaquePointer?
    /// The machine's one display.
    private let index: UInt32 = 0

    private var pixels: UnsafeMutableRawPointer?
    private var width = 0
    private var height = 0
    private var flushScheduled = false
    /// Each viewer's, handed the screen as it is now, or nil once there's none.
    private var sinks: [Viewer: @MainActor (CGImage?) -> Void] = [:]
    private var wantsActive = false
    /// The VM's own size and a few common ones, offered after the preferred
    /// size.
    private var otherModes: [crate_display_mode] = []
    /// The size that fits the view, once it has one.
    private var fitted: crate_display_mode?
    /// The external display's size, while it shows the screen: offered
    /// instead of the view's, which is kept meanwhile for when it goes.
    private var external: crate_display_mode?
    /// What the guest is offered first.
    private var preferred: crate_display_mode? { external ?? fitted }
    /// What the guest was last offered, so the same offer isn't made twice.
    private var offered: crate_display_mode?
    /// See pointerPosition.
    private var lastPointer = CGPoint(x: 0.5, y: 0.5)

    /// For crate_config_add_display; `self` outlives the machine.
    var callbacks: crate_display_callbacks {
        crate_display_callbacks(
            size: MemoryLayout<crate_display_callbacks>.size,
            context: Unmanaged.passUnretained(self).toOpaque(),
            frame: { context, _, frame in
                guard let context, let frame else { return }
                Unmanaged<DisplayBridge>.fromOpaque(context).takeUnretainedValue().take(frame.pointee)
            })
    }

    deinit {
        pixels?.deallocate()
    }

    func attach(machine: OpaquePointer) {
        let active = lock.withLock { () -> Bool in
            self.machine = machine
            return wantsActive
        }
        if active { crate_display_set_active(machine, index, true) }
        offerModes()
    }

    // MARK: - The guest's size

    /// The sizes for a new machine: the external display's first, if one is
    /// showing the screen, or else the one that fits the view, if the view has
    /// been laid out; then `others`, which later offers keep.
    func modes(after others: [crate_display_mode]) -> [crate_display_mode] {
        lock.withLock {
            otherModes = others
            offered = preferred
            return list()
        }
    }

    /// The view is `points` big, in a window `window` big: the guest is offered
    /// a desktop of the view's shape, and switches to it if it follows its
    /// display's preferred mode, as a guest does by default.
    ///
    /// In portrait it normally gets the desktop it had in landscape in a window
    /// this size, remembered (or, before there's been one, the portrait view's
    /// sides swapped), so turning the iPhone changes nothing: the desktop sits
    /// letterboxed. The unfolded Duo passes `portrait` and gets a real portrait
    /// desktop instead. Folding it, a window of another size, offers a new one.
    ///
    /// Without a window, `points` is all there is to fill (iPhone Duo folded
    /// like a laptop, the desktop above the fold): it gets that shape, and
    /// nothing is remembered, so unfolding brings back the desktop it had.
    @MainActor
    func fit(_ points: CGSize, window: CGSize?, portrait: Bool = false) {
        let mode: crate_display_mode
        if portrait, points.height > points.width {
            guard let fitted = Self.mode(fitting: points, portrait: true) else { return }
            mode = fitted
        } else if let window {
            let key = "display.landscape.\(Int(max(window.width, window.height)))x\(Int(min(window.width, window.height)))"
            if points.width >= points.height {
                guard let fitted = Self.mode(fitting: points) else { return }
                UserDefaults.standard.set([Int(fitted.width), Int(fitted.height)], forKey: key)
                mode = fitted
            } else if let saved = UserDefaults.standard.array(forKey: key) as? [Int], saved.count == 2 {
                mode = crate_display_mode(width: UInt32(saved[0]), height: UInt32(saved[1]))
            } else {
                guard let swapped = Self.mode(fitting: points) else { return }
                mode = swapped
            }
        } else {
            guard let fitted = Self.mode(fitting: points) else { return }
            mode = fitted
        }
        // Rotating or folding lays the view out more than once on the way:
        // only the size it settles on is offered.
        pendingFit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let (changed, deferred) = lock.withLock { () -> (Bool, Bool) in
                guard self.fitted?.width != mode.width || self.fitted?.height != mode.height else { return (false, false) }
                self.fitted = mode
                return (true, self.external != nil)
            }
            guard changed else { return }
            AppLog.write("display: \(mode.width)x\(mode.height) fits \(Int(points.width))x\(Int(points.height)) pt"
                         + (deferred ? ", offered once the external display goes" : ""))
            offerModes()
        }
        pendingFit = work
        // The first size goes at once, so a booting machine starts at it.
        let first = lock.withLock { fitted == nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + (first ? 0 : 0.4), execute: work)
    }
    @MainActor private var pendingFit: DispatchWorkItem?

    /// While an external display shows the screen, the guest is offered a
    /// desktop of the display's shape and size (`pixels`, its own) instead of
    /// the view's: the iPhone or iPad is then only where the person points and
    /// types. The view's latest size is kept meanwhile, and offered again once
    /// the display goes (nil).
    @MainActor
    func fitExternal(_ pixels: CGSize?) {
        let mode = pixels.flatMap(Self.mode(forPixels:))
        let (changed, view) = lock.withLock { () -> (Bool, crate_display_mode?) in
            guard external?.width != mode?.width || external?.height != mode?.height else { return (false, nil) }
            external = mode
            return (true, fitted)
        }
        guard changed else { return }
        if let mode, let pixels {
            AppLog.write("display: \(mode.width)x\(mode.height) fits the external display's \(Int(pixels.width))x\(Int(pixels.height)) px")
        } else if let view {
            AppLog.write("display: \(view.width)x\(view.height) fits the view again")
        }
        // A display can connect, go and come back within a moment as it
        // settles (the Simulator's does): only where it ends up is offered.
        pendingExternal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.offerModes() }
        pendingExternal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    @MainActor private var pendingExternal: DispatchWorkItem?

    /// A guest pixel for each point, so the desktop's text is the size of the
    /// app's, but at least 600 pixels on the short side, where a desktop's
    /// windows start to fit, and at most 2560 on the long one. Multiples of 8.
    /// Normally landscape: a desktop is laid out for it, and in a portrait
    /// view it sits letterboxed, the same desktop as with the iPhone on its
    /// side. The unfolded Duo is large enough to be useful like a small iPad,
    /// so it can ask for a genuinely portrait desktop instead.
    nonisolated static func mode(fitting points: CGSize, portrait: Bool = false) -> crate_display_mode? {
        let short = min(points.width, points.height), long = max(points.width, points.height)
        guard short >= 100 else { return nil }
        let scale = min(max(1, 600 / short), 2560 / long)
        if portrait, points.height > points.width {
            return oriented(width: short, height: long, scale: scale)
        }
        return landscape(long: long, short: short, scale: scale)
    }

    /// An external display's own shape and, where practical, its pixels. Allow
    /// a 5120x1440 ultrawide at native resolution, while keeping other displays
    /// to roughly a 4K pixel budget so a 5K/6K 16:9 panel does not multiply the
    /// GPU readback cost. Multiples of 8, landscape.
    nonisolated static func mode(forPixels pixels: CGSize) -> crate_display_mode? {
        let short = min(pixels.width, pixels.height), long = max(pixels.width, pixels.height)
        guard short >= 100 else { return nil }
        let fourKPixelBudget = CGFloat(3840 * 2160)
        let areaScale = sqrt(fourKPixelBudget / (long * short))
        let scale = min(1, 5120 / long, areaScale)
        return landscape(long: long, short: short, scale: scale)
    }

    private nonisolated static func landscape(long: CGFloat, short: CGFloat, scale: CGFloat) -> crate_display_mode {
        oriented(width: long, height: short, scale: scale)
    }

    private nonisolated static func oriented(width: CGFloat, height: CGFloat, scale: CGFloat) -> crate_display_mode {
        let round8 = { (v: CGFloat) in UInt32(max(8, (v * scale / 8).rounded() * 8)) }
        return crate_display_mode(width: round8(width), height: round8(height))
    }

    /// The preferred size first, then the others.
    private func list() -> [crate_display_mode] {
        guard let preferred else { return otherModes }
        var modes = [preferred]
        // Native 5K ultrawide is the default. Its exact half-size remains an
        // integer-scaled, same-shape escape hatch if a workload needs less GPU
        // bandwidth without falling back to a stretched 16:10 desktop.
        if let external,
           max(external.width, external.height) >= 3_000,
           min(external.width, external.height) >= 1_200 {
            let performance = crate_display_mode(
                width: max(8, external.width / 16 * 8),
                height: max(8, external.height / 16 * 8)
            )
            if !modes.contains(where: {
                $0.width == performance.width && $0.height == performance.height
            }) {
                modes.append(performance)
            }
        }
        modes.append(contentsOf: otherModes.filter { candidate in
            !modes.contains(where: {
                $0.width == candidate.width && $0.height == candidate.height
            })
        })
        return modes
    }

    /// Tells a running machine about a new preferred size.
    private func offerModes() {
        let offer = lock.withLock { () -> (OpaquePointer, [crate_display_mode])? in
            guard let machine, let preferred, !otherModes.isEmpty,
                  offered?.width != preferred.width || offered?.height != preferred.height else { return nil }
            offered = preferred
            return (machine, list())
        }
        // Outside the lock, which crate's GPU thread takes to hand over frames.
        if let (machine, modes) = offer {
            crate_display_set_modes(machine, index, modes, modes.count)
        }
    }

    /// The VM stopped: its screen goes too, so an external display still
    /// showing it, or one connected later, doesn't show a VM that's gone.
    @MainActor
    func detach() {
        lock.withLock { machine = nil }
        forgetScreen()
    }

    /// A new boot: forget the last one's screen, so a VM that never shows its
    /// display isn't taken for one showing another's.
    @MainActor
    func reset() {
        forgetScreen()
    }

    @MainActor
    private func forgetScreen() {
        let sinks = lock.withLock { () -> [@MainActor (CGImage?) -> Void] in
            pixels?.deallocate()
            pixels = nil
            width = 0
            height = 0
            return Array(self.sinks.values)
        }
        for sink in sinks { sink(nil) }
    }

    // MARK: - The viewers' side, on the main thread

    /// Starts handing `viewer`'s `sink` pictures, and asks crate for frames if
    /// it's the first.
    @MainActor
    func connect(_ viewer: Viewer, _ sink: @escaping @MainActor (CGImage?) -> Void) {
        let machine = lock.withLock { () -> OpaquePointer? in
            let first = sinks.isEmpty
            sinks[viewer] = sink
            wantsActive = true
            return first ? self.machine : nil
        }
        if let machine { crate_display_set_active(machine, index, true) }
        if let image = picture() { sink(image) }
        if viewer == .external { onExternalChange?(true) }
    }

    /// Stops the frames once nothing shows them: they cost a copy each.
    @MainActor
    func disconnect(_ viewer: Viewer) {
        let (removed, machine) = lock.withLock { () -> (Bool, OpaquePointer?) in
            guard sinks.removeValue(forKey: viewer) != nil else { return (false, nil) }
            guard sinks.isEmpty else { return (true, nil) }
            wantsActive = false
            return (true, self.machine)
        }
        if let machine { crate_display_set_active(machine, index, false) }
        if removed, viewer == .external { onExternalChange?(false) }
    }

    /// Whether an external display shows the screen now.
    @MainActor
    var isShownExternally: Bool {
        lock.withLock { sinks[.external] != nil }
    }

    /// The app's view, told when an external display starts or stops showing
    /// the screen: meanwhile it's a trackpad for the pointer there.
    @MainActor var onExternalChange: ((Bool) -> Void)?

    /// The screen's size in pixels, once a frame has come.
    var size: CGSize {
        lock.withLock { CGSize(width: width, height: height) }
    }

    // Input, for the machine's virtio keyboard and tablet.

    func key(_ code: UInt16, down: Bool) {
        lock.withLock {
            guard let machine else { return }
            crate_input_key(machine, code, down)
        }
    }

    /// Types plain text from iOS into whatever has focus in the guest. This is
    /// deliberately keyboard input rather than a guest clipboard protocol, so
    /// it works in every catalog image, at a login prompt, and in a terminal
    /// without installing an agent. Characters outside the guest's US-ASCII
    /// keyboard map are skipped rather than changed into something surprising.
    func typeClipboardText(_ text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let strokes = normalized.compactMap(LinuxKeys.stroke(for:))
        guard !strokes.isEmpty else {
            AppLog.write("clipboard: no keyboard characters to paste")
            return
        }
        let skipped = normalized.count - strokes.count

        textInputQueue.async { [weak self] in
            guard let self else { return }
            for stroke in strokes {
                if stroke.shift { self.key(LinuxKeys.leftShift, down: true) }
                self.key(stroke.code, down: true)
                self.key(stroke.code, down: false)
                if stroke.shift { self.key(LinuxKeys.leftShift, down: false) }
                Thread.sleep(forTimeInterval: 0.003)
            }
            AppLog.write("clipboard: pasted \(strokes.count) keyboard characters"
                         + (skipped == 0 ? "" : ", skipped \(skipped) unsupported"))
        }
    }

    /// `x` and `y` from 0 to 1 across the screen.
    func pointer(x: Double, y: Double, buttons: UInt32) {
        let x = max(0, min(1, x)), y = max(0, min(1, y))
        let scale = 32767.0
        lock.withLock {
            lastPointer = CGPoint(x: x, y: y)
            guard let machine else { return }
            crate_input_pointer(machine, UInt32(x * scale), UInt32(y * scale), buttons)
        }
    }

    /// Where the guest's pointer was last put, 0 to 1 across the screen each
    /// way: kept here, which outlives the display view, so a trackpad carries
    /// on from where the pointer is after the view is made again.
    var pointerPosition: CGPoint {
        lock.withLock { lastPointer }
    }

    func scroll(dx: Int32, dy: Int32) {
        lock.withLock {
            guard let machine else { return }
            crate_input_scroll(machine, dx, dy)
        }
    }

    // MARK: - crate's side, on the GPU's thread

    private func take(_ frame: crate_frame) {
        guard let source = frame.pixels else { return }
        lock.withLock {
            let w = Int(frame.width), h = Int(frame.height)
            var dirtyX = Int(frame.dirty_x), dirtyY = Int(frame.dirty_y)
            var dirtyW = Int(frame.dirty_width), dirtyH = Int(frame.dirty_height)
            if w != width || h != height || pixels == nil {
                // A new size: take the whole frame.
                pixels?.deallocate()
                pixels = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 16)
                width = w
                height = h
                (dirtyX, dirtyY, dirtyW, dirtyH) = (0, 0, w, h)
                AppLog.write("display: \(w)x\(h)")
            }
            guard let pixels, dirtyW > 0, dirtyH > 0 else { return }
            let stride = Int(frame.stride)
            for row in dirtyY..<min(dirtyY + dirtyH, h) {
                let from = source.advanced(by: row * stride + dirtyX * 4)
                let to = pixels.advanced(by: (row * w + dirtyX) * 4)
                to.copyMemory(from: from, byteCount: min(dirtyW, w - dirtyX) * 4)
            }
            guard !sinks.isEmpty, !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.async { self.flush() }
        }
    }

    /// One picture for both viewers: it's the copy that costs.
    @MainActor
    private func flush() {
        let sinks = lock.withLock { () -> [@MainActor (CGImage?) -> Void] in
            flushScheduled = false
            return Array(self.sinks.values)
        }
        guard !sinks.isEmpty, let image = picture() else { return }
        for sink in sinks { sink(image) }
    }

    /// The screen so far, at the guest's own size: what a screenshot is of.
    func snapshot() -> CGImage? { picture() }

    #if DEBUG
    /// Debug builds pretending JIT is on: `image` as the screen, so the
    /// display can be tried without a VM. It goes to any viewer already
    /// showing the screen, as a frame would: an external display is.
    @MainActor
    func pretend(_ image: CGImage) {
        defer { flush() }
        lock.withLock {
            pixels?.deallocate()
            width = image.width
            height = image.height
            pixels = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 16)
            let context = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
    #endif

    /// The screen so far, as a picture: a copy, so crate can keep drawing.
    private func picture() -> CGImage? {
        lock.withLock {
            guard let pixels, width > 0, height > 0 else { return nil }
            let data = Data(bytes: pixels, count: width * height * 4) as CFData
            guard let provider = CGDataProvider(data: data) else { return nil }
            // Red, green, blue, unused: as crate lays a pixel out.
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }
}
