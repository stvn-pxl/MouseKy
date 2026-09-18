# MouseKy

[![CI](https://github.com/stvn-pxl/MouseKy/actions/workflows/ci.yml/badge.svg)](https://github.com/stvn-pxl/MouseKy/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

MouseKy is a native macOS 15+ menu-bar app for app-specific mouse profiles.
`IOHIDManager` discovers connected pointing devices, while `CGEventTap` is
limited to keyboard shortcut recording.

## Download

Download the latest signed and notarized DMG from
[GitHub Releases](https://github.com/stvn-pxl/MouseKy/releases/latest).

1. Open the DMG.
2. Drag MouseKy into the **Applications** folder.
3. Launch MouseKy from Applications.
4. Grant **Accessibility** and **Input Monitoring** in **System Settings →
   Privacy & Security**, then relaunch MouseKy.

MouseKy has no Dock icon. Use the mouse icon in the menu bar. Releases are
universal binaries for Apple silicon and Intel Macs that support macOS 15.

## Build from source

1. Install the full Xcode app, select it with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, then open `MouseKy.xcodeproj`.
2. Select the `MouseKy` scheme and run it locally. The app has no Dock icon; use the menu-bar mouse icon.
3. On the first launch, allow MouseKy in **System Settings → Privacy & Security → Accessibility** and **Input Monitoring**. Relaunch the app after granting permissions if the event tap does not start.

The project deliberately disables the App Sandbox because it needs direct HID
access. Local development builds use ad hoc signing; public releases use Apple
Developer ID signing, Hardened Runtime, and notarization.

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

## Using the app

1. Choose **Scan Mice**, select a mouse for editing, then explicitly choose
   **Als aktives Gerät verwenden**.
2. Choose **Scan Buttons**, then click every button once.
3. Click **Record Shortcut** beside a discovered extra button and press the desired combination.

Left and right click are displayed but intentionally protected from remapping.
Profiles can be assigned to running apps or application bundles; exactly one
default profile handles macOS and all unassigned apps.

## Logitech HID++ support

- Logitech G-Series devices are probed for HID++ `0x8110`; compatible MX
  devices use temporary `0x1B04` control diversion.
- MouseKy does not create a virtual mouse. Pointer movement, scrolling and
  primary clicks remain on the device's native path.
- Runtime button state is restored when MouseKy stops. App changes never write
  onboard flash.
- The hardware acceptance gates are documented in
  [Docs/CoreHIDGate.md](Docs/CoreHIDGate.md).
- The **G502 onboard controls** support the directly connected `046D:C08D` G502 LIGHTSPEED. They use macOS IOKit directly; no Logitech package or third-party driver is required. Quit G HUB before using them so the two applications do not compete for HID++ responses.
- Onboard inspection dynamically discovers HID++ features `0x8100`/`0x1802`; Device Reset is never invoked.
- Writes are allowlisted only for `046D:C08D`, firmware `MPM 17.00.B0008`, feature version `0`, and the exact known 11-button/255-byte layout. Other firmware and ROM profiles remain read-only.
- Reset changes only documented button fields in both banks. DPI, polling, LEDs, macros and unknown bytes remain unchanged. It writes the active profile, verifies it, commits the unchanged control sector last, then verifies through a fresh HID++ session. Errors stop immediately without retries.

## Manual verification

- Connect/disconnect a mouse and run **Scan Mice** again.
- Scan each physical button; ensure only emitted macOS button numbers appear.
- Confirm unmapped buttons retain their original behavior.
- Map an extra button and confirm its native event is blocked while the chosen shortcut is emitted.
- Record shortcuts with Command, Control, Option, and Shift modifiers.
- Revoke/regrant both permissions and confirm the permission state is reported accurately.
- For a G502 C08D, quit G HUB, select the mouse, and confirm that the reported onboard-shortcut count is correct.
- Change one non-primary onboard assignment, verify the reported sector read-back, then physically test that button. Do not disconnect the mouse during a flash write.

## Tests

The `MouseKyTests` target covers shortcut policy plus HID++ framing, error correlation, real C08D descriptor fixtures, 255-byte sector chunking, CRC handling, button-bank offsets, and preservation of unrelated profile bytes.

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
- Generic button scanning and shortcut mapping depend on the events exposed by
  macOS and the device.
- HID++ support varies by Logitech model, connection, and firmware.
- Onboard writes are restricted to the exact G502 hardware, firmware, feature,
  and profile layout documented above. Unsupported combinations are read-only.
- MouseKy is not distributed through the Mac App Store.

## Privacy and security

MouseKy processes mouse events, application changes, and shortcuts locally. It
does not include analytics, advertising, accounts, or network telemetry.
Configuration is stored on the Mac. The requested Accessibility and Input
Monitoring permissions are required for remapping behavior.

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

MouseKy is available under the [MIT License](LICENSE).

Logitech, G, G502, MX, and G HUB are trademarks of Logitech. MouseKy is an
independent project and is not affiliated with, endorsed by, or sponsored by
Logitech.
