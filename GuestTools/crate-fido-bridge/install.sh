#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -eu

case "${1-}" in
    "") start=yes ;;
    --no-start) start=no ;;
    *) echo "usage: sudo ./install.sh [--no-start]" >&2; exit 2 ;;
esac

[ "$(uname -s)" = Linux ] || { echo "crate-fido: Linux is required" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "crate-fido: run this installer with sudo" >&2; exit 1; }

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
command -v make >/dev/null 2>&1 || { echo "crate-fido: install make and a C compiler first" >&2; exit 1; }
command -v cc >/dev/null 2>&1 || { echo "crate-fido: install a C compiler first" >&2; exit 1; }
command -v modprobe >/dev/null 2>&1 || { echo "crate-fido: install the kmod package first" >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "crate-fido: systemd is required" >&2; exit 1; }
command -v udevadm >/dev/null 2>&1 || { echo "crate-fido: udev is required" >&2; exit 1; }

make -C "$here" clean check

if ! getent group crate-fido >/dev/null 2>&1; then
    groupadd --system crate-fido
fi
if ! getent passwd crate-fido >/dev/null 2>&1; then
    useradd --system --gid crate-fido --home-dir /nonexistent \
        --shell /usr/sbin/nologin --no-create-home crate-fido
elif ! id -nG crate-fido | tr ' ' '\n' | grep -qx crate-fido; then
    usermod --append --groups crate-fido crate-fido
fi

install -d -m 0755 /usr/local/libexec /usr/local/share/doc/crate-fido-bridge
install -m 0755 "$here/crate-fido-bridge" /usr/local/libexec/crate-fido-bridge
install -m 0644 "$here/README.md" "$here/PROTOCOL.md" \
    /usr/local/share/doc/crate-fido-bridge/
install -m 0644 "$here/systemd/crate-fido-bridge.service" \
    /etc/systemd/system/crate-fido-bridge.service
install -m 0644 "$here/systemd/crate-fido.modules-load" \
    /etc/modules-load.d/crate-fido.conf
install -m 0644 "$here/udev/70-crate-fido-bridge.rules" \
    /etc/udev/rules.d/70-crate-fido-bridge.rules
if [ ! -e /etc/default/crate-fido-bridge ]; then
    install -m 0644 "$here/systemd/crate-fido-bridge.default" \
        /etc/default/crate-fido-bridge
fi

modprobe uhid
udevadm control --reload-rules
udevadm trigger --action=change --name-match=uhid 2>/dev/null || true
udevadm trigger --action=change --name-match=hvc0 2>/dev/null || true
systemctl daemon-reload

if [ "$start" = yes ]; then
    systemctl enable --now crate-fido-bridge.service
    echo "crate-fido: installed and enabled"
    echo "crate-fido: the service waits for Crate's host handshake before exposing UHID"
else
    systemctl enable crate-fido-bridge.service
    echo "crate-fido: installed and enabled for the next boot (not started now)"
fi
