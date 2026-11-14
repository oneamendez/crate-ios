// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import XCTest
@testable import Crate

final class LocalizationTests: XCTestCase {
    private let languages = ["en", "ar", "zh-Hans", "fr"]

    private func table(_ language: String) throws -> [String: String] {
        guard let folder = Bundle.main.path(forResource: language, ofType: "lproj") else {
            XCTFail("No \(language).lproj in the app bundle")
            return [:]
        }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        return Self.parse(text)
    }

    /// A small OpenStep .strings reader: quoted key, equals, quoted value,
    /// semicolon. The files are UTF-8 and contain no escaped newlines.
    private static func parse(_ text: String) -> [String: String] {
        let pattern = #""((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = text as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = unescape(ns.substring(with: match.range(at: 1)))
            let value = unescape(ns.substring(with: match.range(at: 2)))
            result[key] = value
        }
        return result
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    private func placeholders(_ text: String) -> Int {
        text.components(separatedBy: "%@").count - 1
    }

    func testAllLanguagesContainEveryKey() throws {
        let english = try table("en")
        XCTAssertGreaterThan(english.count, 300, "The English table looks truncated")

        for language in languages where language != "en" {
            let translated = try table(language)
            let missing = Set(english.keys).subtracting(translated.keys).sorted()
            let extra = Set(translated.keys).subtracting(english.keys).sorted()
            XCTAssertTrue(missing.isEmpty, "\(language) is missing: \(missing.joined(separator: ", "))")
            XCTAssertTrue(extra.isEmpty, "\(language) has unknown keys: \(extra.joined(separator: ", "))")
        }
    }

    func testNoEmptyTranslations() throws {
        for language in languages {
            let translated = try table(language)
            let empty = translated.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            XCTAssertTrue(empty.isEmpty, "\(language) has empty values: \(empty.keys.sorted())")
        }
    }

    func testFormatPlaceholdersMatchEnglish() throws {
        let english = try table("en")
        for language in languages where language != "en" {
            let translated = try table(language)
            for (key, value) in english {
                guard let translation = translated[key] else { continue }
                XCTAssertEqual(placeholders(translation), placeholders(value),
                               "\(language) changed the format placeholders in \(key)")
            }
        }
    }

    func testArabicIsTheOnlyRightToLeftLanguage() {
        XCTAssertTrue(L10n.isRightToLeft(languageCode: "ar"))
        XCTAssertTrue(L10n.isRightToLeft(languageCode: "ar-SA"))
        XCTAssertFalse(L10n.isRightToLeft(languageCode: "en"))
        XCTAssertFalse(L10n.isRightToLeft(languageCode: "fr"))
        XCTAssertFalse(L10n.isRightToLeft(languageCode: "zh-Hans"))
    }

    func testTranslationsResolveFromTheirBundle() {
        XCTAssertEqual(L10n.string("common.cancel", languageCode: "ar"), "إلغاء")
        XCTAssertEqual(L10n.string("common.cancel", languageCode: "zh-Hans"), "取消")
        XCTAssertEqual(L10n.string("common.cancel", languageCode: "fr"), "Annuler")
        XCTAssertEqual(L10n.string("common.cancel", languageCode: "en"), "Cancel")
    }

    func testInfoPlistPrivacyStringsExistInEveryLanguage() throws {
        for language in languages {
            guard let folder = Bundle.main.path(forResource: language, ofType: "lproj") else {
                XCTFail("No \(language).lproj")
                continue
            }
            let url = URL(fileURLWithPath: folder).appendingPathComponent("InfoPlist.strings")
            let text = try String(contentsOf: url, encoding: .utf8)
            let table = Self.parse(text)
            XCTAssertNotNil(table["NSLocalNetworkUsageDescription"], "\(language)")
            XCTAssertNotNil(table["NSPhotoLibraryAddUsageDescription"], "\(language)")
        }
    }
}
