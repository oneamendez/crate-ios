# Crate FIDO bridge for Linux guests

`crate-fido-bridge` makes the iPhone-side Crate authenticator appear inside a
Linux VM as a standard 64-byte FIDO HID device. Linux creates the device through
`/dev/uhid`; browsers and `libfido2` then find it through the normal HID path.
The FIDO report descriptor uses the assigned FIDO usage page `0xf1d0` and
CTAPHID usage `0x01`.

This helper is deliberately a dumb transport:

- it forwards exact CTAPHID reports over Crate's dedicated virtio console;
- it never parses CTAP CBOR, stores a credential, sees a private key, invokes a
  biometric API, or decides whether an operation is allowed;
- it does not log report contents;
- it creates UHID only after a nonce-bound host handshake succeeds, and removes
  it if that transport session becomes invalid.

The iPhone host implementation is a separate component. Until it is present,
the service safely waits and no FIDO device appears in the guest.

## Build and test

On Debian:

```sh
sudo apt update
sudo apt install build-essential kmod
make check
```

`make check` compiles the Linux UHID executable with warnings as errors and
runs portable framing tests. The tests cover all two-chunk split points,
coalesced messages, garbage resynchronization, checksum corruption, oversized
length rejection, the nonce handshake, and byte-exact 64-byte reports.

On macOS, `make test` runs the portable protocol tests; only the UHID executable
requires Linux headers.

## Install in an existing Debian VM

First make this directory available in the guest (for example, clone/copy the
Crate source tree or transfer a release archive). Then:

```sh
cd GuestTools/crate-fido-bridge
sudo apt update
sudo apt install build-essential kmod
sudo ./install.sh
systemctl status crate-fido-bridge.service
```

The installer:

1. builds with warnings as errors and runs the tests;
2. creates a locked `crate-fido` system account;
3. installs the helper in `/usr/local/libexec`;
4. loads Linux's `uhid` module;
5. gives only that account access to `/dev/uhid` and `/dev/hvc0`;
6. enables a hardened systemd service.

Use `sudo ./install.sh --no-start` to install and enable it without starting it
in the current boot. The default console is `/dev/hvc0`, the first virtio
console after Crate's existing PL011 serial console. To use another device, edit
`/etc/default/crate-fido-bridge` **and** add matching `DeviceAllow` and udev
permissions in a systemd override; changing only the command line is expected to
fail closed.

The console is dedicated binary transport. Do not run a getty or shell on it.
The service conflicts with the standard `getty@hvc0` and
`serial-getty@hvc0` units while it is active.

## Verify in the guest

After the iPhone host has acknowledged the bridge:

```sh
journalctl -u crate-fido-bridge.service -b
ls -l /dev/hidraw*
sudo apt install libfido2-tools
fido2-token -L
```

The journal says `host transport ready` and `virtual authenticator connected`.
It never prints CTAPHID payloads. `fido2-token -L` should list the UHID-backed
device. Actual registration/assertion tests require the iPhone-side CTAP2
authenticator; this guest helper does not fake a response.

## Uninstall

```sh
sudo ./uninstall.sh
```

This stops the service and removes the executable, unit, documentation, module
and udev rule. It preserves `/etc/default/crate-fido-bridge` and the locked
service account in case the local configuration is still useful. To remove
those too:

```sh
sudo ./uninstall.sh --purge-user
```

## Catalog images

For new Crate images, publish this helper as a signed distribution package and
install/enable it from the image's cloud-init vendor data. Do not put a mutable
binary or a password into the seed image. Existing VMs keep the explicit install
path above because their NoCloud seed has already run.

The byte-stream contract the iPhone adapter must implement is in
[`PROTOCOL.md`](PROTOCOL.md).
