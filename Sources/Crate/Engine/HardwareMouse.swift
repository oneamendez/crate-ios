// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GameController

/// A physical mouse or trackpad exposed by iOS through GameController.
///
/// UIKit hover events on iPhone normally require AssistiveTouch. GameController
/// supplies the device's raw motion, buttons and scroll axes directly, so Crate
/// can drive the guest's existing absolute tablet without enabling it.
@MainActor
final class HardwareMouse {
    static let shared = HardwareMouse()

    private weak var bridge: DisplayBridge?
    private var observers: [NSObjectProtocol] = []
    private var mice: [GCMouse] = []
    private var buttons: UInt32 = 0
    private var restX: Float = 0
    private var restY: Float = 0
    private var lastScrollFirst: Float = 0
    private var lastScrollSecond: Float = 0

    func start(bridge: DisplayBridge) {
        stop()
        self.bridge = bridge
        GCMouse.mice().forEach(attach)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let mouse = note.object as? GCMouse else { return }
            Task { @MainActor in self?.attach(mouse) }
        })
        observers.append(center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let mouse = note.object as? GCMouse else { return }
            Task { @MainActor in self?.detach(mouse) }
        })
        AppLog.write("input: direct mouse capture started; \(mice.count) connected")
    }

    func stop() {
        releaseButtons()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for mouse in mice { clear(mouse) }
        mice.removeAll()
        bridge = nil
        restX = 0
        restY = 0
        lastScrollFirst = 0
        lastScrollSecond = 0
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput, !mice.contains(where: { $0 === mouse }) else { return }
        mouse.handlerQueue = .main
        mice.append(mouse)
        AppLog.write("input: mouse connected: \(mouse.vendorName ?? "unknown"), right \(input.rightButton != nil), middle \(input.middleButton != nil)")

        input.mouseMovedHandler = { [weak self] _, dx, dy in
            MainActor.assumeIsolated { self?.moved(dx, dy) }
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, down in
            MainActor.assumeIsolated { self?.button(1, down: down) }
        }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, down in
            MainActor.assumeIsolated { self?.button(2, down: down) }
        }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, down in
            MainActor.assumeIsolated { self?.button(4, down: down) }
        }
        input.scroll.valueChangedHandler = { [weak self] _, first, second in
            MainActor.assumeIsolated { self?.scrolled(first, second) }
        }
    }

    private func detach(_ mouse: GCMouse) {
        clear(mouse)
        mice.removeAll { $0 === mouse }
        releaseButtons()
        AppLog.write("input: mouse disconnected; \(mice.count) connected")
    }

    private func clear(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = nil
        input.leftButton.pressedChangedHandler = nil
        input.rightButton?.pressedChangedHandler = nil
        input.middleButton?.pressedChangedHandler = nil
        input.scroll.valueChangedHandler = nil
    }

    /// GameController's Y axis points upward. Preserve sub-pixel motion until
    /// it becomes a whole guest pixel, then map the delta onto Crate's tablet.
    private func moved(_ dx: Float, _ dy: Float) {
        guard let bridge else { return }
        restX += dx
        restY -= dy
        let x = restX.rounded(.towardZero)
        let y = restY.rounded(.towardZero)
        guard x != 0 || y != 0 else { return }
        restX -= x
        restY -= y

        let size = bridge.size
        let width = max(Double(size.width), 1920)
        let height = max(Double(size.height), 1080)
        let at = bridge.pointerPosition
        bridge.pointer(x: at.x + Double(x) * 1.5 / width,
                       y: at.y + Double(y) * 1.5 / height,
                       buttons: buttons)
    }

    private func button(_ bit: UInt32, down: Bool) {
        if down { buttons |= bit } else { buttons &= ~bit }
        guard let bridge else { return }
        let at = bridge.pointerPosition
        bridge.pointer(x: at.x, y: at.y, buttons: buttons)
    }

    private func releaseButtons() {
        guard buttons != 0 else { return }
        buttons = 0
        guard let bridge else { return }
        let at = bridge.pointerPosition
        bridge.pointer(x: at.x, y: at.y, buttons: 0)
    }

    /// GameController reports vertical motion on its first axis and horizontal
    /// on its second. It repeats both axis states when either changes, so send
    /// only the axis that actually moved to avoid doubled trackpad scrolling.
    private func scrolled(_ first: Float, _ second: Float) {
        let verticalChanged = first != lastScrollFirst
        let horizontalChanged = second != lastScrollSecond
        lastScrollFirst = first
        lastScrollSecond = second
        let mostlyVertical = abs(first) > 2 * abs(second)
        let mostlyHorizontal = abs(second) > 2 * abs(first)
        let verticalRaw = verticalChanged && !mostlyHorizontal ? -first : 0
        let horizontalRaw = horizontalChanged && !mostlyVertical ? second : 0
        let horizontal = Self.wheelUnits(horizontalRaw)
        let vertical = Self.wheelUnits(verticalRaw)
        if horizontal != 0 || vertical != 0 {
            bridge?.scroll(dx: horizontal, dy: vertical)
        }
    }

    private static func wheelUnits(_ value: Float) -> Int32 {
        guard value.isFinite else { return 0 }
        let units = Int32(min(24, (7 * abs(value).squareRoot()).rounded()))
        return value < 0 ? -units : units
    }
}
