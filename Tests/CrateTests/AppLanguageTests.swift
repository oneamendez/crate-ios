// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import XCTest
@testable import Crate

final class AppLanguageTests: XCTestCase {
    func testSystemLanguageDetection() {
        XCTAssertEqual(AppLanguage.matching(["ar-SA"]), .arabic)
        XCTAssertEqual(AppLanguage.matching(["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.matching(["fr-FR"]), .french)
        XCTAssertEqual(AppLanguage.matching(["en-GB"]), .english)
        // A language crate doesn't ship falls back to English.
        XCTAssertEqual(AppLanguage.matching(["de-DE"]), .english)
    }

    func testResolutionUsesTheSystemOnlyForSystem() {
        XCTAssertEqual(AppLanguage.resolvedCode(selection: "en"), "en")
        XCTAssertEqual(AppLanguage.resolvedCode(selection: "ar"), "ar")
        XCTAssertEqual(AppLanguage.resolvedCode(selection: "zh-Hans"), "zh-Hans")
        XCTAssertEqual(AppLanguage.resolvedCode(selection: "fr"), "fr")
        XCTAssertTrue(["en", "ar", "zh-Hans", "fr"].contains(AppLanguage.resolvedCode(selection: "system")))
    }

    func testNativeNamesAreAsTheyShouldAppear() {
        XCTAssertEqual(AppLanguage.english.nativeName, "English")
        XCTAssertEqual(AppLanguage.arabic.nativeName, "العربية")
        XCTAssertEqual(AppLanguage.simplifiedChinese.nativeName, "简体中文")
        XCTAssertEqual(AppLanguage.french.nativeName, "Français")
    }

    func testLanguageSelectionPersistsWithoutTouchingMachineData() {
        let name = "CrateTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }

        let first = AppPreferences(defaults: suite)
        first.language = .arabic
        first.appearance = .dark
        first.animationsEnabled = false

        let second = AppPreferences(defaults: suite)
        XCTAssertEqual(second.language, .arabic)
        XCTAssertEqual(second.appearance, .dark)
        XCTAssertFalse(second.animationsEnabled)
        XCTAssertEqual(second.resolvedLanguageCode, "ar")
        XCTAssertEqual(second.layoutDirection, .rightToLeft)
    }

    func testReducesMotionOnlyWhenAsked() {
        let name = "CrateTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: suite)
        preferences.animationsEnabled = true
        XCTAssertFalse(preferences.reducesMotion(system: false))
        XCTAssertTrue(preferences.reducesMotion(system: true))
        preferences.animationsEnabled = false
        XCTAssertTrue(preferences.reducesMotion(system: false))
    }
}
