# MouseKy

[![CI](https://github.com/stvn-pxl/MouseKy/actions/workflows/ci.yml/badge.svg)](https://github.com/stvn-pxl/MouseKy/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

MouseKy is a native macOS 15+ menu-bar app for per-device, app-specific mouse
profiles. `IOHIDManager` discovers connected pointing devices; runtime
remapping currently requires a compatible Logitech HID++ device. MouseKy uses
`CGEventTap` only for recording keyboard shortcuts.

## Download

Download the latest signed and notarized DMG from
[GitHub Releases](https://github.com/stvn-pxl/MouseKy/releases/latest).

1. Open the DMG.
2. Drag MouseKy into the **Applications** folder.
3. Launch MouseKy from Applications.
4. Use MouseKy's permission overlay to request **Accessibility** (for emitting
   shortcuts) and **Input Monitoring** (for detecting input), then return to
   MouseKy and choose **Check Again**. Restart only if macOS still denies the
   HID interface.

MouseKy normally runs from the mouse icon in the menu bar. A Dock icon appears
while the main window is open. Releases are universal binaries for Apple
silicon and Intel Macs that support macOS 15.
MouseKy checks the stable GitHub release feed at most once per day by default.
The check can be disabled, or started manually, in **Settings → Updates**.
Updates are signed and always require confirmation before installation and
restart; individual versions can be skipped.

On first launch, MouseKy enables **Open MouseKy at Login**. This can be disabled
under **Settings → Startup**.

## Build from source

1. Install the full Xcode app, select it with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, then open `MouseKy.xcodeproj`.
2. Select the `MouseKy` scheme and run it locally. Use the menu-bar mouse icon
   to reopen the main window.
3. Request Accessibility and Input Monitoring from MouseKy's permission
   overlay, then choose **Check Again**.

The project deliberately disables the App Sandbox because it needs direct HID
access. The Makefile uses an available Apple Development identity so macOS
permissions survive rebuilds, with ad hoc signing as a fallback. Public
releases use Apple Developer ID signing, Hardened Runtime, and notarization.

### Terminal commands

Run these commands from the repository root:

```bash
make build
make run
make reinstall
make clean
make uninstall
```

- `make build` builds the development app `MouseKy Dev.app` in `.build/Build/Products/Debug/`.
- `make run` builds, quits an already running MouseKy Dev process, then launches the development build artifact.
- `make reinstall` builds, quits MouseKy Dev, replaces `~/Applications/MouseKy Dev.app`, and launches that installed copy. It uses `~/Applications`, so it does not need an administrator password.
- `make clean` removes Xcode build products from `.build`.
- `make uninstall` quits MouseKy Dev and removes only its installed copy, configuration, caches, logs, saved state, preferences, and Accessibility/Input-Monitoring grants. It also removes all MouseKy build artifacts (project-local `.build*`/`DerivedData` plus Xcode’s `~/Library/Developer/Xcode/DerivedData/MouseKy-*`). The release app, source files, and Derived Data from other projects remain untouched.

Development builds use the app name `MouseKy Dev`, bundle identifier
`io.github.stvn-pxl.MouseKy.Dev`, and a separate configuration directory.
They can therefore be installed beside the signed GitHub release, which remains
`MouseKy` with bundle identifier `io.github.stvn-pxl.MouseKy`. Avoid running
both at the same time because they access the same mouse hardware.
Development builds do not start the automatic updater.

## Using the app

1. Select a detected mouse in the sidebar. Use **Scan Mice** after connecting
   or disconnecting hardware if the list has not refreshed.
2. Compatible Logitech HID++ controls appear automatically. Use **Scan
   Buttons** only when MouseKy offers it as a fallback diagnostic.
3. Choose or create a profile, click **Record Shortcut** beside an extra
   control, and press the desired keyboard combination.
4. Assign running apps or application bundles to profiles as needed.

Left and right click are hidden from the mapping list and cannot be remapped.
Each configured device has exactly one default profile for macOS and apps
without an explicit assignment. All configured, connected compatible Logitech
mice can run their own effective profile simultaneously; sidebar selection only
chooses which device is being edited.

## Logitech HID++ support

- Compatible Logitech devices are probed for HID++ `0x8110` first, then for
  temporary `0x1B04` control diversion.
- MouseKy does not create a virtual mouse. Pointer movement, scrolling and
  primary clicks remain on the device's native path.
- Runtime button state is restored when MouseKy stops. App changes never write
  onboard flash.
- The hardware acceptance gates are documented in
  [Docs/CoreHIDGate.md](Docs/CoreHIDGate.md).
- The **G502 onboard controls** support the directly connected `046D:C08D` G502 LIGHTSPEED. They use macOS IOKit directly; no Logitech package or third-party driver is required. Quit G HUB before using them so the two applications do not compete for HID++ responses.
- Onboard inspection dynamically discovers HID++ features `0x8100`/`0x1802`; Device Reset is never invoked.
- Writes are allowlisted only for `046D:C08D`, firmware `MPM 17.00.B0008`, feature version `0`, and the exact known 11-button/255-byte layout. Other firmware and ROM profiles remain read-only.
- **Clear Onboard Shortcuts** removes keyboard and media assignments from both
  button banks while preserving mouse, DPI, polling, LED, device-function,
  macro, and unknown data. MouseKy verifies the active profile by read-back,
  commits the unchanged directory sector last, and attempts to restore the
  original snapshot if verification fails.

## Manual verification

- Connect/disconnect a mouse and run **Scan Mice** again.
- When the fallback scanner is offered, scan each physical button and ensure
  only emitted macOS button numbers appear.
- Confirm unmapped buttons retain their original behavior.
- Map an extra button and confirm its native event is blocked while the chosen shortcut is emitted.
- Record shortcuts with Command, Control, Option, and Shift modifiers.
- Revoke/regrant both permissions and confirm the permission state is reported accurately.
- For a G502 C08D, quit G HUB, select the mouse, and confirm that the reported onboard-shortcut count is correct.
- Use **Clear Onboard Shortcuts**, verify the reported read-back, and confirm
  mouse, DPI, and device-function assignments remain unchanged. Do not
  disconnect the mouse during a flash write.

## Tests

The `MouseKyTests` target covers configuration migration, profile resolution,
shortcut and update-manager policy, HID++ framing, error correlation, real C08D
descriptor fixtures, 255-byte sector chunking, CRC handling, button-bank
offsets, rollback, and preservation of unrelated profile bytes.

Run them with:

```bash
xcodebuild test \
  -project MouseKy.xcodeproj \
  -scheme MouseKy \
  -destination 'platform=macOS' \
  -derivedDataPath .build-tests
```

## Compatibility and limitations

- macOS 15 or newer is required.
- Generic mice may be discovered and scanned, but runtime remapping currently
  requires supported Logitech HID++ hardware.
- HID++ support varies by Logitech model, connection, and firmware.
- Onboard writes are restricted to the exact G502 hardware, firmware, feature,
  and profile layout documented above. Unsupported combinations are read-only.
- MouseKy is not distributed through the Mac App Store.

## Privacy and security

MouseKy processes mouse events, application changes, and shortcuts locally. It
does not include analytics, advertising, accounts, or network telemetry.
Configuration is stored on the Mac. The only routine network request is the
optional update check against the public GitHub release feed. The requested
Accessibility and Input Monitoring permissions are required for remapping
behavior. MouseKy may write local HID diagnostic information to Apple's unified
log; MouseKy does not transmit these logs.

Report vulnerabilities privately as described in
[`SECURITY.md`](SECURITY.md), especially issues involving event capture or
onboard-memory writes.

## Contributing

Contributions are welcome. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) and the
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) before opening a pull request.
Hardware-sensitive changes must include tests and manual verification details.

## Support the project

MouseKy remains fully functional without payment. If GitHub displays a
**Sponsor** button for this repository, you can use it to support continued
development.

## License and trademarks

MouseKy is available under the [MIT License](LICENSE). Copyright in the
original project remains with Steven Leu; contributors retain copyright in
their contributions. The MIT License allows others to use, study, modify,
redistribute, sublicense, and sell copies, provided the copyright and license
notice remain included. Contributions are accepted under the same MIT terms.

Logitech, G, G502, MX, and G HUB are trademarks of Logitech. MouseKy is an
independent project and is not affiliated with, endorsed by, or sponsored by
Logitech.
