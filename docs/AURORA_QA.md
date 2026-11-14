# Aurora Edition QA

This file records what can be checked automatically and what still needs a
Simulator or device. It is deliberately explicit: a check is not marked as
passed unless it was actually run on a Mac with Xcode.

## Automated in this branch

- `python3 Scripts/check-localizations.py`
  - English, Arabic, Simplified Chinese, and French contain exactly the same
    364 keys.
  - No translation is empty.
  - `%@` placeholders match English.
  - Every localisation key used in the Swift sources exists in English.
  - Both privacy strings exist in every `.lproj`.
- `swiftc -parse` on all Swift sources (syntax only; run on the Linux review
  machine, not a substitute for Xcode).
- `xcodegen generate` against `project.yml` with XcodeGen 2.46, verifying that
  the project, the `Crate` scheme, the `CrateTests` target, the shared scheme's
  test action, and the four localization variant groups are generated.
- GitHub Actions expression/YAML validation with `actionlint`.
- `CrateTests` (compiled and run by `ci.yml` on a macOS runner):
  - every language has every key and no empty values;
  - format placeholder parity;
  - language resolution, native names, right-to-left detection;
  - language, appearance and animation preference persistence;
  - Reduce Motion calculation;
  - locale-aware byte, memory and relative-date formatting.
- `ci.yml` builds the real `Crate` scheme for an iPhone Simulator, runs the
  tests, keeps logs and `.xcresult` bundles, and uploads the simulator app.

## Still requires a Mac / Simulator / device

The following are the manual checks to run from the branch, ideally on both an
iPhone and an iPad. Launch arguments make each state quick to open.

### Opening experience

1. Launch with no arguments. Confirm the native launch screen is midnight, then
   the aurora, mark, particles, wordmark, and dashboard appear without a white
   flash.
2. Tap during the opening. It should end immediately.
3. Enable Settings > Accessibility > Motion > Reduce Motion and relaunch.
   The opening should be a short fade with no moving waves or particles.
4. In crate Settings, turn App animations off and repeat. Motion should stay
   reduced even with the system setting on.
5. Launch with `--skip-intro` and confirm the dashboard is immediately usable.

### Languages and RTL

For each of `--language=en`, `--language=ar`, `--language=zh-Hans`, and
`--language=fr` (or via Settings > Language):

- Check the dashboard, Install, Settings, language picker, account sheet,
  acknowledgement screens, confirmation dialogs, and error cards.
- Check no text is clipped at the largest Dynamic Type sizes.
- In Arabic, check:
  - the tab bar/sidebar is mirrored;
  - navigation back chevrons and disclosure chevrons point correctly;
  - labels and body copy align to the right;
  - the terminal, commands, paths, IP addresses, hostnames, version numbers,
    display sizes, and code stay left-to-right;
  - Arabic letters remain joined (no custom tracking on Arabic labels);
  - mixed Arabic/English strings read in the correct order.
- Switch language while a destination is open, then return to Home and Install,
  and confirm the choice updated without losing installed VM data.
- Relaunch and confirm the chosen language persisted.
- Switch back to System and confirm it follows the device language after a
  relaunch.

### VMs and the engine

1. Install a catalog image with a non-default CPU, memory, and storage choice;
   verify the account sheet and the real download/unpack progress.
2. Confirm the VM appears on Home with its distribution, desktop, CPUs, memory,
   disk, display, and last-used information.
3. Start it, open the terminal, switch between desktop and console, use the
   Linux key row and a hardware keyboard.
4. Stop it from the VM screen and from its Home card; both should keep a new
   preview and preserve the last-screen image.
5. Start a second VM while the first runs and confirm the busy state is shown
   instead of a second engine starting.
6. Edit a stopped VM's CPUs and memory, relaunch it, and verify the new values
   are used. Try the same while it runs and confirm the controls explain that
   the change waits for the next start.
7. Produce a real failure (for example, temporarily rename a kernel in a test
   VM's folder) and confirm the error is readable and the logs can be exported.
8. Delete a stopped VM and confirm its files are removed.

### Installation and failure states

- Empty VM list and empty catalog.
- Installing, unpacking, finishing, installed, and failed.
- No network / HTTP failure.
- Insufficient storage.
- Cancelling an install and keeping it.
- Account validation for user name and hostname.

### Accessibility

- VoiceOver labels for the tab bar, VM cards, Start/Stop, terminal, language
  rows, JIT badge, and progress.
- Reduce Motion, Reduce Transparency, Increase Contrast, Bold Text, and the
  largest Dynamic Type size.
- Light, Dark, and System appearance on iPhone and iPad.

## Capturing screenshots

Use a stable iPhone simulator, remove app state first if needed, and launch with
`--skip-intro --samples --empty` as appropriate:

    xcrun simctl launch booted com.amendez.crate --skip-intro --tab=home --samples
    xcrun simctl io booted screenshot docs/media/aurora-home-en.png

Repeat for Home, Install, Settings, Language, and the Arabic dashboard. Add the
images to `docs/media/` only after checking they are real devices or simulator
renders; do not fabricate screenshots.
