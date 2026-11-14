#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Checks Aurora Edition's four localisations before a build.

- every language has the same keys as English
- no value is empty
- format placeholders match English
- every localisation key found in the Swift sources exists
- every language has the two privacy strings iOS shows

Run from the repository root: `python3 Scripts/check-localizations.py`.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources"
LANGUAGES = ["en", "ar", "zh-Hans", "fr"]
SOURCE_PREFIXES = (
    "a11y.", "about.", "account.", "appearance.", "catalog.", "common.",
    "home.", "install.", "jit.", "keyboard.", "language.", "licenses.",
    "logs.", "machine.", "memory.", "motion.", "os.", "pair.", "pairing.",
    "progress.", "settings.", "splash.", "status.", "tab.", "vm.",
)

# These strings look like keys but are UserDefaults keys, accessibility
# identifiers or symbols, not localisation.
NOT_LOCALISATION = {
    "install.cpuCount",
    "install.diskGB",
    "install.memoryGB",
    "jit.claiming",
    "jit.codeRegionMB",
    "jit.turnOnAtLaunch",
    "keyboard.chevron.compact.down",
    "settings.language",
}

STRING_LINE = re.compile(r'^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;\s*$')
PLACEHOLDER = re.compile(r"%@")


def parse(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("/*"):
            continue
        match = STRING_LINE.match(line)
        if not match:
            raise SystemExit(f"{path}:{number}: not a key/value .strings line: {line!r}")
        key = json.loads('"' + match.group(1) + '"')
        value = json.loads('"' + match.group(2) + '"')
        if key in values:
            raise SystemExit(f"{path}:{number}: duplicate key {key}")
        values[key] = value
    return values


def source_keys() -> set[str]:
    keys: set[str] = set()
    for path in (ROOT / "Sources" / "Crate").rglob("*.swift"):
        text = path.read_text(encoding="utf-8-sig")
        for literal in re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', text):
            if literal.startswith(SOURCE_PREFIXES) and literal not in NOT_LOCALISATION:
                keys.add(literal)
    return keys


def main() -> int:
    tables = {}
    for language in LANGUAGES:
        path = RESOURCES / f"{language}.lproj" / "Localizable.strings"
        if not path.exists():
            print(f"error: missing {path}", file=sys.stderr)
            return 1
        tables[language] = parse(path)

    english = tables["en"]
    if len(english) < 300:
        print(f"error: English has only {len(english)} keys", file=sys.stderr)
        return 1

    problems = 0
    for language in LANGUAGES:
        table = tables[language]
        missing = sorted(set(english) - set(table))
        extra = sorted(set(table) - set(english))
        if missing:
            print(f"error: {language} is missing: {', '.join(missing)}", file=sys.stderr)
            problems += 1
        if extra:
            print(f"error: {language} has unknown keys: {', '.join(extra)}", file=sys.stderr)
            problems += 1

        for key, value in table.items():
            if not value.strip():
                print(f"error: {language} has an empty value for {key}", file=sys.stderr)
                problems += 1
            if language != "en" and key in english:
                expected = len(PLACEHOLDER.findall(english[key]))
                got = len(PLACEHOLDER.findall(value))
                if expected != got:
                    print(f"error: {language} changed the placeholders in {key} "
                          f"({got} instead of {expected})", file=sys.stderr)
                    problems += 1

    used = source_keys()
    missing_in_english = sorted(used - set(english))
    if missing_in_english:
        print("error: keys used in Swift but missing from English: "
              + ", ".join(missing_in_english), file=sys.stderr)
        problems += 1

    for language in LANGUAGES:
        path = RESOURCES / f"{language}.lproj" / "InfoPlist.strings"
        if not path.exists():
            print(f"error: missing {path}", file=sys.stderr)
            problems += 1
            continue
        privacy = parse(path)
        for key in ("NSLocalNetworkUsageDescription", "NSPhotoLibraryAddUsageDescription"):
            if key not in privacy or not privacy[key].strip():
                print(f"error: {language} is missing {key}", file=sys.stderr)
                problems += 1

    if problems:
        print(f"\n{problems} localisation problem(s).", file=sys.stderr)
        return 1

    print(f"localisations: {len(english)} keys x {len(LANGUAGES)} languages, "
          f"{len(used)} used in Swift, all complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
