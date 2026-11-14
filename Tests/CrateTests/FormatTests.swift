// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import XCTest
@testable import Crate

final class FormatTests: XCTestCase {
    private var previousLanguage: String?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.string(forKey: SettingsKey.appLanguage)
    }

    override func tearDown() {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: SettingsKey.appLanguage)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.appLanguage)
        }
        super.tearDown()
    }

    private func use(_ language: String) {
        UserDefaults.standard.set(language, forKey: SettingsKey.appLanguage)
    }

    func testMemoryAndBytesUseReadableUnits() {
        use("en")
        XCTAssertEqual(Format.bytes(5_800_000_000), "5.8 GB")
        XCTAssertEqual(Format.bytes(107_000_000_000), "107 GB")
        XCTAssertEqual(Format.bytes(384_000_000), "384 MB")
        XCTAssertEqual(Format.memory(UInt64(6) << 30), "6 GB")
        XCTAssertEqual(Format.memory(UInt64(2) << 30), "2 GB")
    }

    func testDecimalSeparatorFollowsTheSelectedLanguage() {
        use("fr")
        XCTAssertEqual(Format.bytes(5_800_000_000), "5,8 GB")

        use("en")
        XCTAssertEqual(Format.bytes(5_800_000_000), "5.8 GB")
    }

    func testNeverIsTranslated() {
        use("en")
        XCTAssertEqual(Format.relative(nil), "Never")
        use("fr")
        XCTAssertEqual(Format.relative(nil), "Jamais")
        use("ar")
        XCTAssertEqual(Format.relative(nil), "أبدًا")
        use("zh-Hans")
        XCTAssertEqual(Format.relative(nil), "从未")
    }

    func testALocalizedRelativeDateUsesTheLanguage() {
        use("en")
        let twoHoursAgo = Date(timeIntervalSinceNow: -2 * 3600)
        let english = Format.relative(twoHoursAgo)
        XCTAssertFalse(english.isEmpty)

        use("fr")
        let french = Format.relative(twoHoursAgo)
        XCTAssertFalse(french.isEmpty)
        XCTAssertNotEqual(french, english)
    }
}
