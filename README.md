<p align="center">
  <img src="docs/media/icon.png" width="128" height="128" alt="crate's icon: an open wooden crate holding three app windows">
</p>

<h1 align="center">crate</h1>

<p align="center"><b>C</b>ompact <b>R</b>untime for <b>A</b>rm64 <b>T</b>ranslation and <b>E</b>mulation</p>

<p align="center"><b>Aurora Edition</b> · full Linux desktops, running entirely on your iPhone and iPad.</p>

<p align="center">
  <img src="docs/media/desktop.png" width="80%" alt="Ubuntu's GNOME desktop with a terminal open, landscape on an iPhone Duo">
</p>

<p align="center"><i>Ubuntu with GNOME, landscape on an iPhone Duo. Aurora Edition keeps the same engine and VM path.</i></p>

## Aurora Edition

Aurora Edition is a complete interface redesign of crate, built on the existing
crate virtualization engine rather than a mock-up or a replacement engine. It
adds:

- a midnight, aurora-lit visual system with translucent glass surfaces,
  adaptive light and dark palettes, and native typography;
- a short animated opening after the static iOS launch screen, with aurora
  waves, particles, the crate mark, and a wordmark; a tap skips it, and Reduce
  Motion turns it into a calm fade;
- a redesigned dashboard with live VM states, real start/stop/terminal actions,
  hardware details, install progress, errors, and an installation shortcut;
- a redesigned Linux installer with distribution selection and CPU, memory,
  and storage configuration;
- a single, easy-to-find language picker for English, Arabic, Simplified
  Chinese, and French, with full right-to-left Arabic;
- appearance, language, animation, accessibility, memory, JIT, logs, About,
  repository, documentation, and open-source license settings;
- an unsigned simulator build, unit tests, and optional IPA jobs in GitHub
  Actions.

The VM engine, JIT paths, SPICE-free local display, console, networking,
pairing, image downloads, SHA-256 verification, cloud-init seed, and GPU stack
are the repository's existing implementation. The redesign does not claim
capabilities the engine or iOS does not provide.

## Screenshots

<p align="center"><i>Aurora Edition UI screenshots are not included in this branch yet. No placeholder image is presented as a real screenshot.</i></p>

The gallery below shows the Linux desktops crate runs, not the Aurora interface:

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
  </tr>
</table>

## Languages

| Language | Code | Layout | Native name |
|---|---|---|---|
| English | `en` | Left to right | English |
| Arabic | `ar` | Right to left | العربية |
| Chinese (Simplified) | `zh-Hans` | Left to right | 简体中文 |
| French | `fr` | Left to right | Français |

- The app follows the system language on first launch.
- Settings → Language shows every language in its own writing system and
  changes the interface immediately, without restarting and without touching
  VM files.
- Arabic flips the whole layout, navigation direction, alignment, and
  directional controls. Terminal output, commands, paths, hostnames, IP
  addresses, and code stay left-to-right.
- The language choice is stored in `UserDefaults` and survives relaunches.
- The build checks key parity and format placeholders across all four
  languages: `python3 Scripts/check-localizations.py`.

## Why crate

- **A real computer in your pocket.** Not a remote desktop or a cloud VM: the
  whole operating system runs on the iPhone, works offline, and your files stay
  on it.
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
  apps render on it. This is the existing engine path and is not changed by the
  Aurora interface.
- **Made for the phone.** Touch is a tablet, a key row above the keyboard adds
  Esc, Ctrl, Super, Tab, function keys and arrows, the desktop follows the phone
  as it turns or folds, and iPhone Duo gets layouts of its own.

## What it runs

Linux comes first. From the Install tab, each with an account of your own:

| Distribution | Desktop |
|---|---|
| Ubuntu 26.04 LTS | GNOME, the heaviest of them, and it runs |
| Debian 13 | KDE Plasma or Xfce |
| Arch Linux ARM | KDE Plasma or Xfce |

Coming soon: Omarchy with Hyprland (it runs, with bugs left to fix), custom
Linux images of your own, and other operating systems.

## Install

crate needs JIT, which iOS gives only to an app a debugger has attached to, so
it can't come from the App Store. Each
[release](https://github.com/oneamendez/crate-ios/releases) has an unsigned
IPA instead, which you sign with your own Apple account and install from a Mac;
JIT is then turned on by crate's built-in StikJIT or by StikDebug (see
[JIT](#jit)). [INSTALL.md](INSTALL.md) has the steps, and a request to paste
into Claude Code, which does them for you. crate is developed on an iPhone Duo
with iOS 27.1.

## The app

Three destinations, on a floating glass bar on iPhone and a side column on
regular-width iPad and iPhone Duo:

- **Home**: a local dashboard with a welcome, real VM status (Running,
  Starting, Stopped, Error, or another VM running), Start/Open, Stop, terminal
  access, VM settings, Delete, last-screen previews, CPUs, memory, storage,
  desktop, display, last use, live install progress, and a visible
  empty-install state.
- **Install**: the images from the real `arm64-desktop-images` catalog, with
  current version and download size, installed markers, and CPU, memory, and
  storage choices. Installing shows the engine's actual download and unpack
  progress, byte counts, and errors. The account sheet writes the same
  cloud-init seed as before.
- **Settings**: language first, then appearance (System/Light/Dark), JIT,
  memory, app animations, system Reduce Motion status, Crate in iOS Settings,
  logs, About, GitHub, documentation, and Acknowledgements.

The Aurora design system lives under `Sources/Crate/Aurora`: palette, type,
spacing, cards, buttons, status pills, progress bars, logo, animated background,
opening experience, and adaptive navigation. It uses system fonts and Dynamic
Type so Arabic, Chinese, French, and accessibility text sizes fall back
correctly.

## Virtual machines

The existing VM path is preserved:

- create a VM from a catalog image, with CPU count, RAM, and storage;
- download kernel, initrd, and disk parts, verify every SHA-256, unpack the
  sparse disk, and grow it;
- create the cloud-init seed with the account, password hash, hostname, time
  zone, and vendor data;
- start and stop one VM at a time with the crate engine;
- show the guest desktop through the virtio GPU path, or its serial console;
- send touch, a hardware keyboard, and the on-screen Linux key row;
- screenshot the guest, save it to Photos, and keep a preview of the last
  screen on the VM card;
- report real engine failures and offer the launch log for export.

A VM's CPU and memory settings apply the next time it starts. The disk size is
chosen at install time and is not resized from the app. The dashboard shows the
VM's allocated hardware and crate's own live memory footprint; iOS does not
provide per-VM CPU or guest memory usage, so the interface does not invent them.

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
messages to `Library/Caches/idevice.log`. The Aurora Setup JIT screen walks
through the same steps with localized status and errors.

## The engine

[crate](https://github.com/oneamendez/crate) runs the VM in this process, on the
code region JIT claimed. The VM screen switches between its display (a virtio
GPU, frames handed straight to the app, touch and keys as a virtio tablet and
keyboard) and its serial console in a terminal
([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), MIT). On an iPhone the
GPU does 3D: the guest's OpenGL runs on the iPhone's GPU through virglrenderer,
ANGLE and MoltenVK, each built from upstream source (see
[docs/PROVENANCE.md](docs/PROVENANCE.md)); in the Simulator the guest draws in
software. The network is user-mode, through [libslirp](https://gitlab.freedesktop.org/slirp/libslirp)
(BSD-3-Clause) and [GLib](https://gitlab.gnome.org/GNOME/glib) (LGPL-2.1-or-later),
built from source as dynamic frameworks the app embeds.

## VM images

The images come from
[arm64-desktop-images](https://github.com/oneamendez/arm64-desktop-images),
whose GitHub workflow builds and attests them: Ubuntu with GNOME, Debian with
KDE Plasma or Xfce, and Arch Linux ARM with KDE Plasma or Xfce. Each release has
a `catalog.json` listing every image's kernel, initrd and disk (xz, in parts
under 2 GiB) with their SHA-256s, its kernel command line, and its cloud-init
vendor-data.

Install reads the latest catalog, downloads an image (crate must stay open
meanwhile), checks every file, unpacks the disk through Apple's xz decoder as
its parts arrive (sparsely: empty space takes no room) and grows it to the
chosen size. The account comes from a seed disk crate writes beside it
(`seed.img`, FAT, labelled CIDATA): cloud-init's NoCloud user-data with the
user, a SHA-512 crypt of the password, the hostname and time zone, plus the
image's vendor-data (its desktop's autologin). The seed stays attached
read-only, so cloud-init sets the VM up once. A VM's files are in
`Library/Application Support/VMs/<its ID>/`.

A VM can still be put on the iPhone by hand: copy `vmlinuz`, `initrd.img` and
`disk.img` into its folder with `devicectl device copy to ... --user mobile`
(without it crate can't write to the disk; never add
`--remove-existing-content`, which empties the app's whole container). It
boots with aTerm's command line.

Debug builds can be driven from a Mac the same way: while a VM runs, an empty
`Library/Caches/debug/screen` gets its display saved as `screen.png` there,
`debug/command.txt` is typed into its console, and `debug/size.txt` ("WxH" in
points) resizes its desktop as rotating or folding the iPhone would. Launched
with `CRATE_GL_DEBUG=1` (`devicectl device process launch -e`), crate logs ANGLE's
own GL messages; with `CRATE_LOG=debug`, its debug lines.

## Build

The libraries go into `Frameworks/`, which isn't committed. Fetch them, each
pinned to a release and checked against its SHA-256:

    ./Scripts/fetch-frameworks.sh  # idevice, libslirp and GLib, the GPU stack
    ./Scripts/fetch-stikjit.sh     # StikJIT 2.0.1
    ./Scripts/fetch-crate.sh       # crate v0.1.1
    xcodegen generate
    open Crate.xcodeproj

The project uses the iOS 27 SDK and builds with Xcode 27.1. The Simulator build
needs an Apple silicon Mac because idevice's Simulator slice is arm64 only.

    xcodebuild -project Crate.xcodeproj -scheme Crate \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath build build

Run the Aurora tests on a simulator:

    xcrun simctl list devices available
    xcodebuild -project Crate.xcodeproj -scheme Crate \
        -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
        -derivedDataPath build test

`Scripts/choose-simulator.py` prints the first available iPhone simulator's
UDID, which is how CI avoids hard-coding a device name.

Validate localisations without Xcode:

    python3 Scripts/check-localizations.py

The automated checks and the manual device checklist (including each Arabic
screen, Dynamic Type, Reduce Motion, and a real VM lifecycle) are in
[docs/AURORA_QA.md](docs/AURORA_QA.md). A check is not marked as passed until it
has actually been run on a Mac or device.

Launch arguments show one state without tapping to it:

    xcrun simctl launch booted com.amendez.crate --tab=install --jit=on
    # --tab=home|install|settings  --jit=on|off  --empty  --samples
    # --rail: the open Duo's tab column, on any device
    # --skip-intro / --no-splash: open straight to the dashboard
    # --language=system|en|ar|zh-Hans|fr
    # --appearance=system|light|dark  --animations=on|off

With `--jit=on` the Simulator has no code region, so starting a VM pretends: its
screenshot becomes the display, and the console shows a login prompt that
echoes typing. Those switches persist with the other preferences.

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

## GitHub Actions

`.github/workflows/ci.yml` runs on pushes to `main` and
`feature/aurora-redesign`, on pull requests, and by hand:

- **build-and-test** fetches the pinned frameworks, generates the actual
  `Crate.xcodeproj`, builds the real `Crate` scheme for an iPhone Simulator,
  runs `CrateTests`, uploads the build and test logs, the `.xcresult` bundles,
  and the simulator `.app` as artifacts. Logs are kept even when a step fails.
- **unsigned-ipa** (manual run, on by default) builds `crate-unsigned.ipa` with
  `Scripts/build-ipa.sh` and uploads it for 14 days. It is unsigned.
- **signed-ipa** (manual run, off by default) runs only when signing secrets are
  configured. It signs with `Scripts/sign-ipa.sh`, verifies the result with
  `codesign --verify --deep --strict`, and uploads the signed IPA. If the
  secrets are absent the job fails clearly; no signed IPA is ever claimed
  unless that job actually completes.

The workflows use the repository's existing `xcode-27` runner label (Xcode
27.1). The project deliberately uses iOS 27.1 APIs behind availability checks,
so a stock older Xcode image is not enough. An Apple silicon runner is required
for the Simulator test job.

The existing tag-driven `.github/workflows/ipa.yml` still builds the release
IPA and creates a GitHub release on a `vX.Y` tag.

### Signing secrets (optional)

Set these in the repository's Actions secrets before enabling `signed-ipa`:

| Secret | Purpose |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Base64 of a `.p12` Apple development certificate |
| `P12_PASSWORD` | Password for that `.p12` |
| `PROVISIONING_PROFILE_BASE64` | Base64 of the app's development provisioning profile |
| `HELPER_PROVISIONING_PROFILE_BASE64` | Base64 of `CrateJITHelper`'s provisioning profile |
| `SIGNING_BUNDLE_ID` | Optional bundle ID to re-sign as (`com.amendez.crate` by default) |
| `SIGNING_IDENTITY` | Optional signing identity SHA-1; the profile's matching identity is used by default |

Never commit certificates, profiles, tokens, or Apple credentials. A signed
artifact from this workflow is a development build: the device must be in the
profile and JIT still has to be turned on as [INSTALL.md](INSTALL.md) describes.

## Known limitations

- **JIT is mandatory.** Without a debugger and an authorized code region, crate
  cannot run a VM. The Simulator's pretend-JIT mode is for UI inspection only.
- **One VM at a time.** The engine runs one machine per process; the dashboard
  shows the other VMs as busy rather than pretending they run.
- **No invented metrics.** iOS does not expose guest CPU use or guest memory
  use. The dashboard shows the configured CPUs and memory, disk use from the
  image, and crate's own live footprint.
- **Disk size is fixed at install.** It cannot be shrunk or grown from the
  current UI.
- **A guest can't update its own kernel.** crate boots a VM's kernel and initrd
  from outside its disk, so the images hold their kernel packages at the version
  they shipped with. A kernel the guest installs anyway is never booted, and an
  upgrade can remove the modules the booted kernel needs.
- **Xfce doesn't follow a new screen size.** On rotate or fold, labwc takes the
  new size but the Xfce panel and desktop don't (see crate's docs/PLAN.md).
- **CI execution.** The workflows are configured in this branch, but success
  can only be reported by an actual run on the `xcode-27` runner with the pinned
  frameworks available. This branch does not claim a signed IPA or a passing
  build without that run.
- **Screenshots.** Aurora UI screenshots are intentionally not fabricated in
  this branch; capture them from a Simulator or device when available.

## Contributing

Speed comes first. Every VM runs on the
[crate engine](https://github.com/oneamendez/crate), so the engine's speed is
the whole app's speed, and that's where help counts most: contributions to the
engine go to its repository.

For the app:

1. Fork the repository and create a topic branch.
2. Keep the engine, JIT, networking, and VM-image paths working; do not replace
   them with mock implementations.
3. Add every user-facing string to all four `.lproj` tables. Arabic, Chinese,
   and French should read naturally, not as literal word-for-word copies.
4. Keep technical text left-to-right in Arabic.
5. Run `python3 Scripts/check-localizations.py` and the `CrateTests` suite.
6. Open a pull request with a clear description and, for UI work, screenshots
   from both iPhone and iPad.

## Roadmap

1. **Speed.** Faster translation, startup and graphics in the engine, measured
   by real benchmarks: timings of what people actually do, such as booting to a
   desktop, opening apps and building code, on the iPhone itself.
2. **Monitors and devices.** An external monitor as the VM's screen, and the
   keyboards, mice, game controllers, cameras, microphones, USB storage and
   other devices iOS lets an app reach, passed through to the VM.
3. **More systems.** Omarchy back in the catalog once its bugs are fixed,
   custom Linux images of your own, then other operating systems.

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
