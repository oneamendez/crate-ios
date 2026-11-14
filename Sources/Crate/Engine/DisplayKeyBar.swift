// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import UIKit

/// The row of extra keys above the keyboard while typing into the VM's screen:
/// Esc, Ctrl, Super, Tab, a few symbols, function keys and arrows, which an
/// iPhone keyboard doesn't have. The console gets the same row from SwiftTerm;
/// this one looks the same and sends Linux key codes to the virtio keyboard.
///
/// A key goes down when touched and up when released, as a physical key does,
/// so the guest repeats a held key and a game sees it held.
final class DisplayKeyBar: UIInputView, UIInputViewAudioFeedback {
    /// A key went down or came up.
    var onKey: ((UInt16, Bool) -> Void)?
    /// The keyboard should go away.
    var onDismiss: (() -> Void)?

    /// Ctrl and Super, each latched by its key until the next key press uses
    /// it, from this row or the keyboard: Ctrl then "c" is Ctrl-C either way.
    /// Super is what the desktops' shortcuts are built on, and an iPhone
    /// keyboard has nothing that sends it.
    private var latched: [UInt16] = [] {
        didSet {
            controlButton.isSelected = latched.contains(Self.control)
            superButton.isSelected = latched.contains(Self.superKey)
        }
    }

    private static let control: UInt16 = 29
    private static let superKey: UInt16 = 125

    private struct Key {
        let button: UIButton
        /// Key codes pressed in order and released in reverse; nil for a key
        /// that isn't a keystroke (Ctrl, Super, dismiss).
        let codes: [UInt16]?
    }

    private var leading: [Key] = []
    private var symbols: [Key] = []
    private var functionKeys: [Key] = []
    private var trailing: [Key] = []
    private var controlButton: UIButton!
    private var superButton: UIButton!
    /// What each held button pressed, so its release undoes exactly that.
    private var held: [ObjectIdentifier: [UInt16]] = [:]
    private var labelsAreNarrow = false

    var enableInputClicksWhenVisible: Bool { true }

    init() {
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: phone ? 36 : 48), inputViewStyle: .keyboard)
        // The keys are Linux key codes laid out physically, not translated
        // text: keep the bar left-to-right under an Arabic interface too.
        semanticContentAttribute = .forceLeftToRight
        allowsSelfSizing = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Keys

    private func build() {
        controlButton = makeButton(title: "ctrl", icon: nil, dark: true)
        controlButton.addTarget(self, action: #selector(toggleLatch(_:)), for: .touchDown)
        // ⌘, because Command is what a hardware keyboard's Super arrives as.
        superButton = makeButton(title: nil, icon: "command", dark: true)
        superButton.addTarget(self, action: #selector(toggleLatch(_:)), for: .touchDown)
        leading = [
            key(title: "esc", dark: true, codes: [1]),
            Key(button: controlButton, codes: nil),
            Key(button: superButton, codes: nil),
            key(icon: "arrow.right.to.line.compact", dark: true, codes: [15]),
        ]
        symbols = ["~", "|", "/", "-"].compactMap { text in
            guard let stroke = LinuxKeys.stroke(for: Character(text)) else { return nil }
            return key(title: text, dark: false, codes: stroke.shift ? [LinuxKeys.leftShift, stroke.code] : [stroke.code])
        }
        // F1 to F10 are 59 to 68.
        functionKeys = (0..<10).map { index in
            key(title: "F\(index + 1)", dark: false, codes: [59 + UInt16(index)])
        }
        let dismiss = makeButton(title: nil, icon: "keyboard.chevron.compact.down", dark: true)
        dismiss.addTarget(self, action: #selector(dismissKeyboard), for: .touchUpInside)
        dismiss.accessibilityLabel = L10n.string("keyboard.hide")
        trailing = [
            key(icon: "arrow.left", dark: false, codes: [105]),
            key(icon: "arrow.down", dark: false, codes: [108]),
            key(icon: "arrow.up", dark: false, codes: [103]),
            key(icon: "arrow.right", dark: false, codes: [106]),
            Key(button: dismiss, codes: nil),
        ]
        leading[0].button.accessibilityLabel = L10n.string("keyboard.escape")
        controlButton.accessibilityLabel = L10n.string("keyboard.control")
        superButton.accessibilityLabel = L10n.string("keyboard.super")
        leading[3].button.accessibilityLabel = L10n.string("keyboard.tab")
        for (key, name) in zip(trailing, [
            L10n.string("keyboard.left"), L10n.string("keyboard.down"),
            L10n.string("keyboard.up"), L10n.string("keyboard.right"),
        ]) {
            key.button.accessibilityLabel = name
        }
        for key in leading + symbols + functionKeys + trailing {
            addSubview(key.button)
        }
    }

    private func key(title: String? = nil, icon: String? = nil, dark: Bool, codes: [UInt16]) -> Key {
        let button = makeButton(title: title, icon: icon, dark: dark)
        button.addTarget(self, action: #selector(press(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(release(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return Key(button: button, codes: codes)
    }

    @objc private func press(_ sender: UIButton) {
        guard let codes = (leading + symbols + functionKeys + trailing)
            .first(where: { $0.button === sender })?.codes else { return }
        UIDevice.current.playInputClick()
        let pressed = takeModifiers() + codes
        held[ObjectIdentifier(sender)] = pressed
        for code in pressed { onKey?(code, true) }
    }

    @objc private func release(_ sender: UIButton) {
        guard let pressed = held.removeValue(forKey: ObjectIdentifier(sender)) else { return }
        for code in pressed.reversed() { onKey?(code, false) }
    }

    @objc private func toggleLatch(_ sender: UIButton) {
        UIDevice.current.playInputClick()
        let code = sender === superButton ? Self.superKey : Self.control
        if let index = latched.firstIndex(of: code) {
            latched.remove(at: index)
        } else {
            latched.append(code)
        }
    }

    @objc private func dismissKeyboard() {
        latched = []
        onDismiss?()
    }

    /// The latched modifiers, unlatching them: the key asking is the one they
    /// modify.
    func takeModifiers() -> [UInt16] {
        defer { latched = [] }
        return latched
    }

    /// Lets go of anything still held, as when the keyboard goes away
    /// mid-press.
    func releaseAll() {
        for (_, pressed) in held {
            for code in pressed.reversed() { onKey?(code, false) }
        }
        held.removeAll()
        latched = []
    }

    // MARK: - Layout

    /// SwiftTerm's arrangement, plus Super: Esc, Ctrl, Super and Tab at the
    /// leading edge, arrows and the dismiss key at the trailing edge, the
    /// symbols after the leading group, then as many function keys as the
    /// width leaves room for. What remains widens the keys that are always
    /// there rather than leaving a gap.
    override func layoutSubviews() {
        super.layoutSubviews()
        let pad: CGFloat = 4
        let height = bounds.height - 8
        let narrow = bounds.width < 380
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        let minimum: CGFloat = narrow ? 24 : (phone ? 28 : 36)

        // Narrow screens swap the Esc and Ctrl labels for symbols, as SwiftTerm does.
        if narrow != labelsAreNarrow {
            labelsAreNarrow = narrow
            setLabel(leading[0].button, title: narrow ? nil : "esc", icon: narrow ? "escape" : nil)
            setLabel(controlButton, title: narrow ? nil : "ctrl", icon: narrow ? "control" : nil)
        }

        let fixed = leading + symbols + trailing
        let fixedWidth = CGFloat(fixed.count) * (minimum + pad) + pad
        let spare = max(0, bounds.width - fixedWidth)
        let fitting = min(functionKeys.count, Int(spare / (minimum + pad)))
        let leftover = spare - CGFloat(fitting) * (minimum + pad)
        let wide = minimum + leftover / CGFloat(fixed.count)

        var x = pad
        for key in leading + symbols {
            key.button.frame = CGRect(x: x, y: 4, width: wide, height: height)
            x += wide + pad
        }
        for (index, key) in functionKeys.enumerated() {
            key.button.isHidden = index >= fitting
            guard index < fitting else { continue }
            key.button.frame = CGRect(x: x, y: 4, width: minimum, height: height)
            x += minimum + pad
        }
        var right = bounds.width - pad
        for key in trailing.reversed() {
            key.button.frame = CGRect(x: right - wide, y: 4, width: wide, height: height)
            right -= wide + pad
        }
    }

    // MARK: - Appearance

    /// SwiftTerm's colours, so the two rows look like one: light keys for
    /// characters, darker ones for keys that do something.
    private static let keyColor = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 150 / 255, alpha: 1) : .white }
    private static let darkKeyColor = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 117 / 255, alpha: 1)
        : UIColor(red: 180 / 255, green: 184 / 255, blue: 193 / 255, alpha: 1) }
    private static let labelColor = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }

    private func makeButton(title: String?, icon: String?, dark: Bool) -> UIButton {
        let button = KeyButton(type: .custom)
        button.restingColor = dark ? Self.darkKeyColor : Self.keyColor
        button.layer.cornerRadius = 5
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowRadius = 0
        button.layer.shadowOpacity = 0.35
        button.setTitleColor(Self.labelColor, for: .normal)
        button.setTitleColor(Self.labelColor, for: .selected)
        button.titleLabel?.font = .systemFont(ofSize: UIDevice.current.userInterfaceIdiom == .phone ? 14 : 17)
        button.tintColor = Self.labelColor
        setLabel(button, title: title, icon: icon)
        return button
    }

    private func setLabel(_ button: UIButton, title: String?, icon: String?) {
        button.setTitle(title, for: .normal)
        button.setImage(icon.flatMap {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14))
        }, for: .normal)
    }
}

/// A key cap: its own colour at rest, the app's accent while latched, paler
/// while held. The accent is the window's: the button's own tint is its
/// label's colour.
private final class KeyButton: UIButton {
    var restingColor: UIColor = .white {
        didSet { refresh() }
    }

    override var isSelected: Bool {
        didSet { refresh() }
    }

    override var isHighlighted: Bool {
        didSet { refresh() }
    }

    private func refresh() {
        if isSelected {
            backgroundColor = window?.tintColor ?? .systemBlue
        } else {
            backgroundColor = isHighlighted ? restingColor.withAlphaComponent(0.6) : restingColor
        }
    }
}
