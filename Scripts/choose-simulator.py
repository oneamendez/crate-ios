#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Print the UDID of the first available iPhone simulator.

Reads `xcrun simctl list devices available -j` on standard input. CI uses the
result as xcodebuild's destination instead of hard-coding a simulator name that
a future Xcode may not ship.
"""

import json
import sys


def main() -> int:
    data = json.load(sys.stdin)
    for runtime, devices in data.get("devices", {}).items():
        if "iOS" not in runtime:
            continue
        for device in devices:
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
                print(device["udid"])
                return 0
    print("No available iPhone simulator", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
