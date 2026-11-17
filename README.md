<p align="center">
  <img src="docs/media/icon.png" width="128" height="128" alt="crate's icon: an open wooden crate holding three app windows">
</p>

<h1 align="center">crate</h1>

<p align="center"><b>C</b>ompact <b>R</b>untime for <b>A</b>rm64 <b>T</b>ranslation and <b>E</b>mulation</p>

<p align="center">Full Linux distributions, desktop and all, running in virtual machines on your iPhone and iPad, entirely on the device.</p>

<p align="center">
  <img src="docs/media/desktop.png" width="80%" alt="Ubuntu's GNOME desktop with a terminal open, landscape on an iPhone Duo">
</p>

<p align="center"><i>Ubuntu with GNOME, landscape on an iPhone Duo.</i></p>

## Why crate

- **A real computer in your pocket.** Not a remote desktop or a cloud VM:
  the whole operating system runs on the iPhone, works offline, and your files
  stay on it.
- **Real distributions.** Stock arm64 Linux with its own package manager, so
  the software you'd run on an Arm laptop or server installs as it is: a
  browser, developer tools, coding agents like Claude Code, CAD apps.
- **Built for speed.** We built crate to be fast, from the engine up. The
  [crate engine](https://github.com/oneamendez/crate) is written from scratch
  in Rust: an arm64-to-arm64 translator that copies most guest instructions
  into host code as they are and rewrites only what touches the machine. On a
  Mac, a benchmark pass that takes QEMU's TCG 130.5 s takes crate 24.5 s; the
  rest of the timings, the iPhone's included, are in the engine's
  [benchmarks](https://github.com/oneamendez/crate#benchmarks).
- **GPU-accelerated.** The guest's OpenGL runs on the iPhone's GPU, through
  virglrenderer, ANGLE and MoltenVK: desktops composite in hardware, and 3D
  apps render on it.
- **Made for the phone.** Touch is a tablet, a key row above the keyboard adds
  Esc, Ctrl, Super, Tab, function keys and arrows, the desktop follows the
  phone as it turns or folds, and iPhone Duo gets layouts of its own.

## What it runs

Linux comes first. From the Install tab, each with an account of your own:

| Distribution | Desktop |
|---|---|
| Ubuntu 26.04 LTS | GNOME, the heaviest of them, and it runs |
| Debian 13 | KDE Plasma or Xfce |
| Arch Linux ARM | KDE Plasma or Xfce |

Coming soon: Omarchy with Hyprland (it runs, with bugs left to fix), custom
Linux images of your own, and other operating systems.

## Features

- Ubuntu, Debian and Arch Linux ARM from a catalog, each with an account of your own
- A disk size of your choice at install, and a memory limit you can change later
- GPU-accelerated desktops: the guest's OpenGL runs on the iPhone's GPU
- Linux audio through the current iOS output, including the phone speaker,
  USB-C displays and AirPlay
- Touch as a tablet, a hardware keyboard, or the on-screen one with a key row
  for Esc, Ctrl, Super, Tab, function keys and arrows
- Paste text from the iPhone or iPad clipboard straight into the VM
- One-time codes from Messages and Mail appear in the iOS keyboard suggestions
- Device-only passkeys protected by Face ID, Touch ID or the device passcode,
  with non-exportable keys in the Secure Enclave; an assertion-only USB-C
  YubiKey can be selected instead
- Supports a mouse or trackpad on iPad: wheel scrolling, right and middle click
- An external monitor as the VM's screen, matching its aspect ratio at up to a
  3840-pixel long edge (including ultrawide modes), with the
  iPhone or iPad as its trackpad (GNOME may need its resolution set by hand; see
  [Known issues](#known-issues))
- iPhone Duo layouts that follow the fold
- The VM's serial console, a tab away from its desktop
- JIT from crate's built-in StikJIT, or from StikDebug
- Logs to share for bug reports, kept across a crash, with memory tracking

## Install

crate needs JIT, which iOS gives only to an app a debugger has attached to, so
it can't come from the App Store. Each
[release](https://github.com/oneamendez/crate-ios/releases) has an unsigned
IPA instead, which you sign with your own Apple account and install from a Mac;
JIT is then turned on by crate's built-in StikJIT or by StikDebug (see
[JIT](#jit)). [INSTALL.md](INSTALL.md) has the steps, and a request to paste
into Claude Code, which does them for you. crate is developed on an iPhone Duo
with iOS 27.1.

## Gallery

<table>
  <tr>
    <td align="center" width="33%">
      <img src="docs/media/solidcraft.png" alt="SolidCraft, a 3D CAD app, with a chair model, beside a terminal where Claude Code describes the chair, in Ubuntu's GNOME desktop on an iPhone Duo"><br>
      <sub>Claude Code, running in the VM, builds a chair in SolidCraft, a 3D CAD app, on Ubuntu with GNOME.</sub>
    </td>
    <td align="center" width="33%">
      <img src="docs/media/chrome-gpu.png" alt="Chrome's chrome://gpu page listing canvas, compositing, rasterization, video decode, WebGL and WebGPU as hardware accelerated"><br>
      <sub>Chrome with GPU acceleration: chrome://gpu shows canvas, compositing, WebGL and WebGPU on the iPhone's GPU.</sub>
    </td>
    <td align="center" width="33%">
      <img src="docs/media/display-settings.png" alt="GNOME's Displays settings in the VM, with the resolution set to 1280 by 800"><br>
      <sub>The VM sets its own resolution: 1280 × 800 fits more on screen than the default.</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="33%">
      <img src="docs/media/kde.png" alt="KDE Plasma's desktop with its application menu open, showing Firefox, System Settings and Dolphin, on an iPhone Duo"><br>
      <sub>Arch Linux ARM with KDE Plasma, its application menu open.</sub>
    </td>
    <td align="center" width="33%">
      <img src="docs/media/monitor.png" alt="Ubuntu's GNOME desktop filling an external monitor, with an iPhone Duo below it showing crate's trackpad"><br>
      <sub>An external monitor as the VM's screen: Ubuntu fills the monitor, and the iPhone Duo becomes its trackpad.</sub>
    </td>
  </tr>
</table>

## Roadmap

Speed comes first. Every VM runs on the
[crate engine](https://github.com/oneamendez/crate), so the engine's speed is
the whole app's speed, and that's where help counts most: contributions to the
engine go to its repository.

1. **Speed.** Faster translation, startup and graphics in the engine, measured
   by real benchmarks: timings of what people actually do, such as booting to a
   desktop, opening apps and building code, on the iPhone itself, so every
   change shows what it gains. Today's numbers are in the engine's
   [benchmarks](https://github.com/oneamendez/crate#benchmarks).
2. **Monitors and devices.** An external monitor already works as the VM's
   screen. Next, the keyboards, mice, game controllers, cameras, microphones,
   USB storage and other devices iOS lets an app reach, passed through to the
   VM; the other way, the VM's sound, clipboard and files reaching iOS.
3. **More systems.** Omarchy back in the catalog once its bugs are fixed,
   custom Linux images of your own, then other operating systems.

## The app

An iOS app that runs Linux VMs on the crate engine: JIT, installing a VM,
and booting it to its desktop. A few UI stand-ins remain (search the code for
`STUB`, `SAMPLE DATA` and `PLACEHOLDER`).

Three tabs:

- **Home**: the installed VMs, one large card each, with the screen each was
  showing when last stopped (`preview.jpg` in its folder) and Start. A card's
  menu has the VM's settings (on iPhone Duo) and Delete.
- **Install Vms**: the images the catalog lists, a memory limit, and Install,
  which asks for the account to make in the VM.
- **Settings**: JIT, memory, logs, and Acknowledgements: the licenses of
  crate and of everything it carries.

## JIT

crate claims its code region at launch, or once a debugger arrives: mapped
executable, authorized by the debugger on `brk #0x69` (StikDebug's legacy.js
convention), then mapped again for writing, and test-run. Two ways to get the
debugger, picked in Settings:

- **StikDebug**: crate opens `stikdebug://enable-jit` with its pid and
  legacy.js; StikDebug attaches and comes back.
- **Built-in StikJIT**: a helper extension (`Sources/JITHelper`) runs
  [StikJIT](https://github.com/StikDebug/StikJIT) (MPL-2.0) through
  LocalDevVPN's tunnel. Set Up JIT pairs the iPhone with crate itself on iOS 27
  (or takes a pairing file), with [idevice](https://github.com/jkcoxson/idevice)
  (MIT), built from source with one patch (`Scripts/patches`).

Each launch logs its JIT steps to `Library/Caches/crate.log`, and pairing's
messages to `Library/Caches/idevice.log`.

## The engine

[crate](https://github.com/oneamendez/crate) runs the VM in this process, on the
code region JIT claimed. The VM screen switches between its display (a virtio
GPU, frames handed straight to the app, touch and keys as a virtio tablet and
keyboard) and its serial console in a terminal
([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), MIT). On an iPhone the
GPU does 3D: the guest's OpenGL runs on the iPhone's GPU through virglrenderer,
ANGLE and MoltenVK, each built from upstream source (see
[docs/PROVENANCE.md](docs/PROVENANCE.md)); in the Simulator the guest draws in
software. The network is
user-mode, through [libslirp](https://gitlab.freedesktop.org/slirp/libslirp)
(BSD-3-Clause) and [GLib](https://gitlab.gnome.org/GNOME/glib) (LGPL-2.1-or-later),
built from source as dynamic frameworks the app embeds.

## VM images

The images come from
[arm64-desktop-images](https://github.com/oneamendez/arm64-desktop-images),
whose GitHub workflow builds and attests them: Ubuntu with GNOME, Debian with
KDE Plasma or Xfce, and Arch Linux ARM with KDE Plasma or Xfce. Each release has a `catalog.json`
listing every image's kernel, initrd and disk (xz, in parts under 2 GiB) with
their SHA-256s, its kernel command line, and its cloud-init vendor-data.

Install reads the latest catalog, downloads an image (crate must stay open
meanwhile), checks every file, unpacks the disk through Apple's xz decoder as
its parts arrive (sparsely: empty space takes no room) and grows it to 32 GB.
The account comes from a seed disk crate writes beside it (`seed.img`, FAT,
labelled CIDATA): cloud-init's NoCloud user-data with the user, a SHA-512
crypt of the password, the hostname and time zone, plus the image's
vendor-data (its desktop's autologin). The seed stays attached read-only, so
cloud-init sets the VM up once. A VM's files are in
`Library/Application Support/VMs/<its ID>/`.

A VM can still be put on the iPhone by hand: copy `vmlinuz`, `initrd.img` and
`disk.img` into its folder with `devicectl device copy to ... --user mobile`
(without it crate can't write to the disk; never add
`--remove-existing-content`, which empties the app's whole container). It
boots with aTerm's command line.

Debug builds can be driven from a Mac the same way: while a VM runs, an empty
`Library/Caches/debug/screen` gets its display saved as `screen.png` there,
`debug/command.txt` is typed into its console, and `debug/size.txt` ("WxH" in
points) resizes its desktop as rotating or folding the iPhone would. Launched with
`CRATE_GL_DEBUG=1` (`devicectl device process launch -e`), crate logs ANGLE's
own GL messages; with `CRATE_LOG=debug`, its debug lines.

## Build

The libraries go into `Frameworks/`, which isn't committed. Fetch them, each
pinned to a release and checked against its SHA-256:

    ./Scripts/fetch-frameworks.sh  # idevice, libslirp and GLib, the GPU stack
    ./Scripts/fetch-stikjit.sh     # StikJIT 2.0.1
    ./Scripts/fetch-crate.sh       # crate v0.1.1
    xcodegen generate
    open Crate.xcodeproj

or for the Simulator:

    xcodebuild -project Crate.xcodeproj -scheme Crate \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath build build

Launch arguments show one state without tapping to it:

    xcrun simctl launch booted com.amendez.crate --tab=install --jit=on
    # --tab=home|install|settings  --jit=on|off  --empty  --samples
    # --rail: the open Duo's tab column, on any device

With `--jit=on` the Simulator has no code region, so starting a VM pretends: its
screenshot becomes the display, and the console shows a login prompt that
echoes typing.

`VERIFY_ATTESTATION=1` makes the crate and frameworks fetches also check, with
gh, that each release's own workflow built it. To change crate and the app at
once, build crate from a checkout instead of fetching it:

    ./Scripts/build-crate.sh       # crate from ~/Repos/crate (CRATE_DIR); needs Rust

The frameworks release is these scripts' output; build them to change one, and
publish a new release with `./Scripts/release-frameworks.sh TAG`, then pin the
`VERSION` and `SHA256` it prints in `fetch-frameworks.sh`:

    ./Scripts/build-idevice.sh     # idevice v0.1.68 from source; needs Rust
    ./Scripts/build-slirp.sh       # libslirp 4.9.7 and GLib 2.90.1; needs meson
    ./Scripts/build-moltenvk.sh    # MoltenVK 1.4.2; about 15 minutes
    ./Scripts/build-angle.sh       # ANGLE; a 4 GB checkout, ANGLE_SRC reuses one
    ./Scripts/build-virgl.sh       # libepoxy 1.5.10 and virglrenderer 1.3.0; needs PyYAML

Once this repository is public, the `frameworks` workflow, run by hand, does
the same on GitHub: it builds them all, publishes the release with an
attestation, and shows the lines to pin. While the repository is private it
skips itself.

### IPA

The `ipa` workflow builds an unsigned IPA from the same pinned libraries: run
by hand it's a workflow artifact, and a version tag (`vX.Y`) makes it a release.
`./Scripts/build-ipa.sh` builds the same IPA on a Mac. `Scripts/sign-ipa.sh`
signs it with your own certificate and profiles under your bundle ID, as
[INSTALL.md](INSTALL.md) describes, and can install it:

    BUNDLE_ID=com.you.crate ./Scripts/sign-ipa.sh crate-unsigned.ipa                # crate-signed.ipa beside it
    BUNDLE_ID=com.you.crate ./Scripts/sign-ipa.sh crate-unsigned.ipa --install UDID

Both bundles get `get-task-allow`, which turning JIT on needs, and the app the
two memory entitlements when its profile grants them. Unset, `BUNDLE_ID` is
this project's own, `com.amendez.crate`.

## Known issues

- **A guest can't update its own kernel.** crate boots a VM's kernel and
  initrd from outside its disk, so the images hold their kernel packages at
  the version they shipped with. A kernel the guest installs anyway is never
  booted, and an upgrade can remove the modules the booted kernel needs.
- **Xfce's wallpaper doesn't follow a new screen size.** When the desktop
  changes size, on an external monitor for one, Xfce's panel, icons and windows
  follow it, but the wallpaper keeps its old size.
- **GNOME may not resize to fit a monitor.** If Ubuntu's desktop doesn't fill
  an external monitor, open Settings → Displays inside the VM and pick a
  resolution with the monitor's aspect ratio, such as 1920 × 1080 for a 16:9
  monitor.
- **Crate Passkeys are not Apple Passwords.** Their private keys stay on the
  iPhone or iPad which created them and do not sync through iCloud. Accessing
  Apple Passwords for arbitrary websites requires Apple's browser-only managed
  entitlement, which a VM app does not receive automatically.

## License

crate's own code is [MPL-2.0](LICENSE), like the
[crate engine](https://github.com/oneamendez/crate): changes to crate's files
stay open, and it can be combined with code under other licenses. What the app
carries from other projects keeps its own license:
[StikJIT](https://github.com/StikDebug/StikJIT) (MPL-2.0),
[idevice](https://github.com/jkcoxson/idevice) and
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT),
[libslirp](https://gitlab.freedesktop.org/slirp/libslirp) (BSD-3-Clause),
[GLib](https://gitlab.gnome.org/GNOME/glib) (LGPL-2.1-or-later, kept as its own
replaceable framework), [MoltenVK](https://github.com/KhronosGroup/MoltenVK)
(Apache-2.0), [ANGLE](https://chromium.googlesource.com/angle/angle)
(BSD-3-Clause), [libepoxy](https://github.com/anholt/libepoxy) and
[virglrenderer](https://gitlab.freedesktop.org/virgl/virglrenderer) (MIT), and
what they in turn are built from. [docs/PROVENANCE.md](docs/PROVENANCE.md) says
where each comes from and how it's built, and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) has every license's text
(`Scripts/third-party-notices.py` writes it). JIT is turned on with
[StikDebug](https://github.com/StikDebug/StikDebug)'s convention, and the VM
images are each distribution's own, under their licenses.
