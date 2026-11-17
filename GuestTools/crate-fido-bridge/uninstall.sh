#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -eu

purge_user=no
case "${1-}" in
    "") ;;
    --purge-user) purge_user=yes ;;
    *) echo "usage: sudo ./uninstall.sh [--purge-user]" >&2; exit 2 ;;
esac

[ "$(uname -s)" = Linux ] || { echo "crate-fido: Linux is required" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "crate-fido: run this uninstaller with sudo" >&2; exit 1; }

systemctl disable --now crate-fido-bridge.service 2>/dev/null || true
rm -f /usr/local/libexec/crate-fido-bridge
rm -rf /usr/local/share/doc/crate-fido-bridge
rm -f /etc/systemd/system/crate-fido-bridge.service
rm -f /etc/modules-load.d/crate-fido.conf
rm -f /etc/udev/rules.d/70-crate-fido-bridge.rules

# Configuration may name a nondefault console, so preserve it unless the caller
# explicitly asks to remove the service account and all local configuration.
if [ "$purge_user" = yes ]; then
    rm -f /etc/default/crate-fido-bridge
    if getent passwd crate-fido >/dev/null 2>&1; then userdel crate-fido; fi
    if getent group crate-fido >/dev/null 2>&1; then groupdel crate-fido; fi
fi

udevadm control --reload-rules
udevadm trigger --action=change --name-match=uhid 2>/dev/null || true
udevadm trigger --action=change --name-match=hvc0 2>/dev/null || true
systemctl daemon-reload
systemctl reset-failed crate-fido-bridge.service 2>/dev/null || true
echo "crate-fido: uninstalled"
