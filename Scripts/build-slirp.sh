#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Build libslirp (BSD-3-Clause) and the GLib it needs (LGPL-2.1-or-later) from
# their releases' sources, as Frameworks/Slirp.xcframework and
# Frameworks/GLib.xcframework: the VM's user-mode networking. crate calls
# libslirp and leaves linking it to the app.
#
#     ./Scripts/build-slirp.sh
#
# Each is a dynamic framework the app embeds: GLib's license asks that it stay
# replaceable, so it isn't linked into the app. GLib's own dependencies (pcre2,
# libffi, intl) come from its meson subprojects, linked into it, and only GLib
# itself ships; its GIO and GObject libraries get built but aren't needed.
# Needs meson, ninja and pkg-config (Homebrew).
set -euo pipefail

GLIB_VERSION=2.90.1
GLIB_SHA256=93c941aa17d5eb1d53fe838365f29a8b4e539c222a256d974ec8f30fc413e396
SLIRP_VERSION=4.9.7
SLIRP_SHA256=d2567fa06a6357c7755d61c67293b2c0bf069b3f2173bde6b76cf768529a1938
MIN_IOS=18.0

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$REPO/.deps"
SRC="$DEPS/src"
WORK="$DEPS/slirp-build"
STAMP="glib $GLIB_VERSION, libslirp $SLIRP_VERSION + crate soread full-buffer guard"

if [ "$(cat "$REPO/Frameworks/Slirp.version" 2>/dev/null)" = "$STAMP" ] \
    && [ -d "$REPO/Frameworks/Slirp.xcframework" ] && [ -d "$REPO/Frameworks/GLib.xcframework" ]; then
    echo "$STAMP already in Frameworks/"
    exit 0
fi

fetch() {  # url file sha256
    [ -f "$SRC/$2" ] || curl --fail --location --silent --show-error --output "$SRC/$2" "$1"
    echo "$3  $SRC/$2" | shasum -a 256 --check --quiet
}
mkdir -p "$SRC"
fetch "https://download.gnome.org/sources/glib/${GLIB_VERSION%.*}/glib-$GLIB_VERSION.tar.xz" \
      "glib-$GLIB_VERSION.tar.xz" "$GLIB_SHA256"
fetch "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v$SLIRP_VERSION/libslirp-v$SLIRP_VERSION.tar.gz" \
      "libslirp-v$SLIRP_VERSION.tar.gz" "$SLIRP_SHA256"
rm -rf "$WORK"
mkdir -p "$WORK"
tar -xf "$SRC/glib-$GLIB_VERSION.tar.xz" -C "$WORK"
tar -xf "$SRC/libslirp-v$SLIRP_VERSION.tar.gz" -C "$WORK"
patch -d "$WORK/libslirp-v$SLIRP_VERSION" -p1 \
    < "$REPO/Scripts/patches/libslirp-soread-full-buffer.patch"

# The meson cross file for one platform: iphoneos or iphonesimulator.
cross_file() {
    local sdk="$1" subsystem target sysroot clang
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    clang="$(xcrun --sdk "$sdk" -f clang)"
    if [ "$sdk" = iphoneos ]; then
        subsystem=ios; target="arm64-apple-ios$MIN_IOS"
    else
        subsystem=ios-simulator; target="arm64-apple-ios$MIN_IOS-simulator"
    fi
    cat <<CROSS
[binaries]
c = ['$clang']
objc = ['$clang']
cpp = ['$(xcrun --sdk "$sdk" -f clang++)']
ar = '$(xcrun --sdk "$sdk" -f ar)'
strip = '$(xcrun --sdk "$sdk" -f strip)'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-target', '$target', '-isysroot', '$sysroot']
objc_args = ['-target', '$target', '-isysroot', '$sysroot']
cpp_args = ['-target', '$target', '-isysroot', '$sysroot']
c_link_args = ['-target', '$target', '-isysroot', '$sysroot']
objc_link_args = ['-target', '$target', '-isysroot', '$sysroot']
cpp_link_args = ['-target', '$target', '-isysroot', '$sysroot']

[properties]
# What GLib would run a program to find out, which it can't on an iPhone.
growing_stack = false
have_c99_vsnprintf = true
have_c99_snprintf = true
have_unix98_printf = true

[host_machine]
system = 'darwin'
subsystem = '$subsystem'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
CROSS
}

for sdk in iphoneos iphonesimulator; do
    prefix="$WORK/$sdk/prefix"
    cross="$WORK/$sdk/cross.ini"
    mkdir -p "$prefix/lib/pkgconfig"
    cross_file "$sdk" > "$cross"
    # Only what this build installs: never Homebrew's macOS GLib or pcre2.
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
    export PKG_CONFIG_PATH=""

    echo "==> GLib $GLIB_VERSION for $sdk"
    meson setup "$WORK/$sdk/glib" "$WORK/glib-$GLIB_VERSION" --cross-file "$cross" \
        --prefix "$prefix" --buildtype release --default-library shared --wrap-mode default \
        -Dtests=false -Dinstalled_tests=false -Dintrospection=disabled -Dnls=disabled \
        -Dlibmount=disabled -Dselinux=disabled -Dxattr=false -Dman-pages=disabled \
        -Ddocumentation=false -Dsysprof=disabled -Ddtrace=disabled -Dsystemtap=disabled \
        -Dglib_debug=disabled -Dlibelf=disabled \
        -Dpcre2:default_library=static -Dlibffi:default_library=static \
        -Dproxy-libintl:default_library=static >/dev/null
    meson compile -C "$WORK/$sdk/glib" >/dev/null
    meson install -C "$WORK/$sdk/glib" >/dev/null

    echo "==> libslirp $SLIRP_VERSION for $sdk"
    meson setup "$WORK/$sdk/slirp" "$WORK/libslirp-v$SLIRP_VERSION" --cross-file "$cross" \
        --prefix "$prefix" --buildtype release --default-library shared >/dev/null
    meson compile -C "$WORK/$sdk/slirp" >/dev/null
    meson install -C "$WORK/$sdk/slirp" >/dev/null
done

# A dylib as a framework: the binary under the framework's name, an @rpath
# install name, and an Info.plist.
framework() {  # dylib dir name platform
    local dylib="$1" dir="$2" name="$3" platform="$4"
    mkdir -p "$dir/$name.framework"
    cp "$dylib" "$dir/$name.framework/$name"
    install_name_tool -id "@rpath/$name.framework/$name" "$dir/$name.framework/$name"
    cat > "$dir/$name.framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.amendez.crate.$name</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
  <key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict></plist>
PLIST
}

GLIB_ARGS=()
SLIRP_ARGS=()
for sdk in iphoneos iphonesimulator; do
    prefix="$WORK/$sdk/prefix"
    out="$WORK/$sdk/frameworks"
    platform=$([ "$sdk" = iphoneos ] && echo iPhoneOS || echo iPhoneSimulator)
    glib="$(ls "$prefix"/lib/libglib-2.0.*.dylib | grep -v -E '\.dylib\..*' | head -1)"
    slirp="$(ls "$prefix"/lib/libslirp.*.dylib | head -1)"
    framework "$glib" "$out" glib "$platform"
    framework "$slirp" "$out" slirp "$platform"
    # libslirp names GLib by its install name; point it at the framework.
    old="$(otool -L "$out/slirp.framework/slirp" | awk '/libglib-2.0/ {print $1}')"
    install_name_tool -change "$old" "@rpath/glib.framework/glib" "$out/slirp.framework/slirp"
    for f in glib slirp; do codesign --force --sign - "$out/$f.framework/$f" 2>/dev/null; done
    GLIB_ARGS+=(-framework "$out/glib.framework")
    SLIRP_ARGS+=(-framework "$out/slirp.framework")
done

rm -rf "$REPO/Frameworks/GLib.xcframework" "$REPO/Frameworks/Slirp.xcframework"
mkdir -p "$REPO/Frameworks"
xcodebuild -create-xcframework "${GLIB_ARGS[@]}" -output "$REPO/Frameworks/GLib.xcframework" >/dev/null
xcodebuild -create-xcframework "${SLIRP_ARGS[@]}" -output "$REPO/Frameworks/Slirp.xcframework" >/dev/null
echo "$STAMP" > "$REPO/Frameworks/Slirp.version"
echo "$STAMP in Frameworks/"
