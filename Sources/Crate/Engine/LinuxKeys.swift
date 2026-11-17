// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import UIKit

/// Linux input event codes (linux/input-event-codes.h), which crate's virtio
/// keyboard takes: a hardware key's HID usage turned into one, and a typed
/// character turned into the key that types it on a US layout, with Shift
/// when it needs it.
enum LinuxKeys {
    static let leftShift: UInt16 = 42
    /// Ctrl, Shift, Alt and Super, left and right.
    static let modifiers: Set<UInt16> = [29, 42, 56, 125, 97, 54, 100, 126]

    /// A hardware key, by its HID usage (UIKey.keyCode).
    static func code(for usage: UIKeyboardHIDUsage) -> UInt16? {
        let value = usage.rawValue
        if (0x04...0x1D).contains(value) {
            return letterCodes[value - 0x04]
        }
        if (0x1E...0x26).contains(value) {
            return UInt16(value - 0x1E + 2)  // 1 to 9
        }
        return hidCodes[value]
    }

    /// The key and whether it needs Shift, for a character typed on the
    /// on-screen keyboard. Nil for what a US keyboard can't type.
    static func stroke(for character: Character) -> (code: UInt16, shift: Bool)? {
        switch character.asciiValue {
        case let ascii? where (97...122).contains(ascii):  // a to z
            return (letterCodes[Int(ascii - 97)], false)
        case let ascii? where (65...90).contains(ascii):   // A to Z
            return (letterCodes[Int(ascii - 65)], true)
        default:
            break
        }
        if let plain = plainCharacters[character] { return (plain, false) }
        if let shifted = shiftedCharacters[character] { return (shifted, true) }
        return nil
    }

    // a to z, in the order HID numbers them.
    private static let letterCodes: [UInt16] = [
        30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50,
        49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44,
    ]

    private static let hidCodes: [Int: UInt16] = [
        0x27: 11,                                   // 0
        0x28: 28, 0x29: 1, 0x2A: 14, 0x2B: 15, 0x2C: 57,   // Return, Esc, Backspace, Tab, Space
        0x2D: 12, 0x2E: 13, 0x2F: 26, 0x30: 27, 0x31: 43,  // - = [ ] \
        0x33: 39, 0x34: 40, 0x35: 41, 0x36: 51, 0x37: 52, 0x38: 53,  // ; ' ` , . /
        0x39: 58,                                   // Caps Lock
        0x3A: 59, 0x3B: 60, 0x3C: 61, 0x3D: 62, 0x3E: 63, 0x3F: 64,  // F1 to F6
        0x40: 65, 0x41: 66, 0x42: 67, 0x43: 68, 0x44: 87, 0x45: 88,  // F7 to F12
        0x49: 110, 0x4A: 102, 0x4B: 104, 0x4C: 111, 0x4D: 107, 0x4E: 109,  // Insert Home PgUp Delete End PgDn
        0x4F: 106, 0x50: 105, 0x51: 108, 0x52: 103,  // Right Left Down Up
        // Numeric keypad. Apple's full-size keyboards label HID Num Lock as Clear;
        // Linux expects KEY_NUMLOCK before the keypad digits produce numbers.
        0x53: 69,                                   // Keypad Num Lock / Clear
        0x54: 98, 0x55: 55, 0x56: 74, 0x57: 78,    // Keypad / * - +
        0x58: 96,                                   // Keypad Enter
        0x59: 79, 0x5A: 80, 0x5B: 81,              // Keypad 1 2 3
        0x5C: 75, 0x5D: 76, 0x5E: 77,              // Keypad 4 5 6
        0x5F: 71, 0x60: 72, 0x61: 73,              // Keypad 7 8 9
        0x62: 82, 0x63: 83,                         // Keypad 0 .
        0x67: 117, 0x85: 121,                       // Keypad = ,
        0xE0: 29, 0xE1: 42, 0xE2: 56, 0xE3: 125,    // left Ctrl Shift Alt Super
        0xE4: 97, 0xE5: 54, 0xE6: 100, 0xE7: 126,   // right Ctrl Shift Alt Super
    ]

    private static let plainCharacters: [Character: UInt16] = [
        "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
        "-": 12, "=": 13, "[": 26, "]": 27, "\\": 43, ";": 39, "'": 40, "`": 41,
        ",": 51, ".": 52, "/": 53, " ": 57, "\n": 28, "\t": 15,
    ]

    private static let shiftedCharacters: [Character: UInt16] = [
        "!": 2, "@": 3, "#": 4, "$": 5, "%": 6, "^": 7, "&": 8, "*": 9, "(": 10, ")": 11,
        "_": 12, "+": 13, "{": 26, "}": 27, "|": 43, ":": 39, "\"": 40, "~": 41,
        "<": 51, ">": 52, "?": 53,
    ]
}
