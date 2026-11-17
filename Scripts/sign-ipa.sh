#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Sign crate's unsigned IPA (a release's crate-unsigned.ipa, or
# Scripts/build-ipa.sh's) with your own Apple development certificate and
# provisioning profiles, and optionally install it on an iPhone. INSTALL.md
# walks through it. Needs nothing else from this repository.
#
#     BUNDLE_ID=com.you.crate ./sign-ipa.sh crate-unsigned.ipa                 # writes crate-signed.ipa beside it
#     BUNDLE_ID=com.you.crate ./sign-ipa.sh crate-unsigned.ipa --install UDID  # and installs it
#
# BUNDLE_ID is the app's bundle ID under your team (com.amendez.crate, this
# project's, if unset); the JIT helper inside it becomes BUNDLE_ID.jithelper.
# Each is signed with a development profile from ~/Library: one for its own
# bundle ID if there is one, otherwise your team's wildcard profile. The team
# is the app profile's. PROFILE and HELPER_PROFILE name .mobileprovision files
# to use instead, and IDENTITY a certificate (by default the keychain's
# development certificate that the app profile lists).
#
# Both get get-task-allow, which turning JIT on needs: the debugger attaches
# to crate. The app also gets the increased-memory-limit and
# extended-virtual-addressing entitlements when its profile grants them. They
# let a VM use more memory, but crate runs without them.
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.amendez.crate}"
HELPER_ID="$BUNDLE_ID.jithelper"
MEMORY_ENTITLEMENTS="com.apple.developer.kernel.increased-memory-limit com.apple.developer.kernel.extended-virtual-addressing"
NFC_ENTITLEMENT="com.apple.developer.nfc.readersession.formats"

IPA="$(cd "$(dirname "${1:?usage: BUNDLE_ID=com.you.crate $0 IPA [--install DEVICE]}")" && pwd)/$(basename "$1")"
DEVICE=""
[ "${2:-}" = --install ] && DEVICE="${3:?--install needs a device: xcrun devicectl list devices}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Reads KEY from the decoded profile PROFILE (plutil key path; escape dots).
profile_value() { security cms -D -i "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }

# Whether PROFILE grants Core NFC tag sessions. The order is not fixed; some
# profiles include NDEF before TAG.
profile_has_nfc() {
    local profile="$1" i=0 value
    while value="$(profile_value "$profile" "Entitlements.${NFC_ENTITLEMENT//./\\.}.$i")"; do
        [ "$value" = TAG ] && return 0
        i=$((i + 1))
    done
    return 1
}

# The newest unexpired development profile for bundle ID $1, in team $2 if
# given, or else the newest wildcard one (of that team, if given).
profile_for() {
    local id="$1" team="${2:-}" now path app date
    local exact="" exact_date="" wild="" wild_date=""
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for path in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision \
                "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
        [ -e "$path" ] || continue
        app="$(profile_value "$path" Entitlements.application-identifier)" || continue
        date="$(profile_value "$path" ExpirationDate)" || continue
        [[ "$date" > "$now" ]] || continue
        if [ -n "$team" ] && [ "${app%%.*}" != "$team" ]; then continue; fi
        if [ "${app#*.}" = "$id" ] && [[ "$date" > "$exact_date" ]]; then
            exact="$path" exact_date="$date"
        elif [ "${app#*.}" = "*" ] && [[ "$date" > "$wild_date" ]]; then
            wild="$path" wild_date="$date"
        fi
    done
    [ -n "$exact$wild" ] || {
        echo "no development profile for $id${team:+ in team $team}, nor a wildcard one: see INSTALL.md" >&2
        return 1
    }
    echo "${exact:-$wild}"
}

# The keychain's code signing identity whose certificate profile $1 lists.
identity_for() {
    local profile="$1" i=0 cert sha identities
    identities="$(security find-identity -v -p codesigning)"
    while cert="$(profile_value "$profile" "DeveloperCertificates.$i")"; do
        sha="$(echo "$cert" | base64 -D | shasum -a 1 | cut -d' ' -f1 | tr a-f A-F)"
        case "$identities" in *"$sha"*) echo "$sha"; return ;; esac
        i=$((i + 1))
    done
    echo "none of the certificates in $(profile_value "$profile" Name) is in this Mac's keychain" >&2
    return 1
}

# $WORK/ID.entitlements: the app ID and team, get-task-allow as the profile
# grants it, and (with "memory") each memory entitlement the profile grants.
# Called as a statement, not in $(...), so a failure stops the script:
# macOS's bash 3.2 doesn't carry -e into $(...).
entitlements_for() {
    local id="$1" profile="$2" memory="${3:-}" out="$WORK/$1.entitlements" allow key
    plutil -create xml1 "$out"
    allow="$(profile_value "$profile" Entitlements.get-task-allow || echo false)"
    [ "$allow" = true ] || echo "warning: $(basename "$profile") has no get-task-allow, so JIT can't be turned on" >&2
    # plutil splits key paths at dots unless they're escaped.
    plutil -replace application-identifier -string "$TEAM.$id" "$out"
    plutil -replace 'com\.apple\.developer\.team-identifier' -string "$TEAM" "$out"
    plutil -replace get-task-allow -bool "$allow" "$out"
    [ "$memory" = memory ] || return 0
    for key in $MEMORY_ENTITLEMENTS; do
        if [ "$(profile_value "$profile" "Entitlements.${key//./\\.}")" = true ]; then
            plutil -replace "${key//./\\.}" -bool true "$out"
            echo "        with $key"
        else
            echo "        without $key: the profile doesn't grant it"
        fi
    done
    if profile_has_nfc "$profile"; then
        plutil -insert "${NFC_ENTITLEMENT//./\\.}" -array "$out"
        plutil -insert "${NFC_ENTITLEMENT//./\\.}.0" -string TAG "$out"
        echo "        with $NFC_ENTITLEMENT (TAG)"
    else
        echo "        without $NFC_ENTITLEMENT: NFC YubiKey stays hidden"
    fi
}

ditto -x -k "$IPA" "$WORK/ipa"
APP="$(echo "$WORK"/ipa/Payload/*.app)"
HELPER="$APP/PlugIns/CrateJITHelper.appex"
[ -d "$HELPER" ] || { echo "no CrateJITHelper.appex in $IPA" >&2; exit 1; }

app_profile="${PROFILE:-$(profile_for "$BUNDLE_ID")}"
TEAM="$(profile_value "$app_profile" TeamIdentifier.0)"
helper_profile="${HELPER_PROFILE:-$(profile_for "$HELPER_ID" "$TEAM")}"
IDENTITY="${IDENTITY:-$(identity_for "$app_profile")}"
echo "app:    $BUNDLE_ID, $(profile_value "$app_profile" Name) (team $TEAM)"
echo "helper: $HELPER_ID, $(profile_value "$helper_profile" Name)"

# The bundle IDs the profiles are for, in place of the ones the IPA was built with.
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Info.plist"
plutil -replace CFBundleIdentifier -string "$HELPER_ID" "$HELPER/Info.plist"
if profile_has_nfc "$app_profile"; then
    plutil -replace CrateNFCYubiKeyEnabled -bool true "$APP/Info.plist" 2>/dev/null || \
        plutil -insert CrateNFCYubiKeyEnabled -bool true "$APP/Info.plist"
else
    plutil -replace CrateNFCYubiKeyEnabled -bool false "$APP/Info.plist" 2>/dev/null || \
        plutil -insert CrateNFCYubiKeyEnabled -bool false "$APP/Info.plist"
fi

# codesign, quiet unless it fails.
sign() {
    local out
    out="$(codesign --force --sign "$IDENTITY" --timestamp=none "$@" 2>&1)" || { echo "$out" >&2; return 1; }
}

# Inside out: every embedded framework, then the helper, then the app.
for framework in "$HELPER"/Frameworks/*.framework "$APP"/Frameworks/*.framework; do
    [ -e "$framework" ] && sign "$framework"
done
entitlements_for "$HELPER_ID" "$helper_profile"
cp "$helper_profile" "$HELPER/embedded.mobileprovision"
sign --entitlements "$WORK/$HELPER_ID.entitlements" "$HELPER"
entitlements_for "$BUNDLE_ID" "$app_profile" memory
cp "$app_profile" "$APP/embedded.mobileprovision"
sign --entitlements "$WORK/$BUNDLE_ID.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

OUT="${IPA%-unsigned.ipa}"
OUT="${OUT%.ipa}-signed.ipa"
rm -f "$OUT"
(cd "$WORK/ipa" && ditto -c -k --norsrc --noextattr --noacl --keepParent Payload "$OUT")
echo "signed: $OUT"

if [ -n "$DEVICE" ]; then
    xcrun devicectl device install app --device "$DEVICE" "$APP"
fi
