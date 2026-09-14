# MouseKy

Native macOS 15+ menu-bar app for app-specific mouse profiles. `IOHIDManager`
discovers connected pointing devices, while `CGEventTap` is limited to keyboard
shortcut recording.

## Build and run

1. Install the full Xcode app, select it with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, then open `MouseKy.xcodeproj`.
2. Select the `MouseKy` scheme and run it locally. The app has no Dock icon; use the menu-bar mouse icon.
3. On the first launch, allow MouseKy in **System Settings → Privacy & Security → Accessibility** and **Input Monitoring**. Relaunch the app after granting permissions if the event tap does not start.

The project deliberately disables the App Sandbox. A locally signed build is sufficient; it is not intended for App Store distribution.

### Terminal commands

Run these commands from the repository root:

```bash
make build
make run
make reinstall
```

- `make build` builds `MouseKy.app` in `.build/Build/Products/Debug/`.
- `make run` builds, quits an already running MouseKy process, then launches the build artifact.
- `make reinstall` builds, quits MouseKy, replaces `~/Applications/MouseKy.app`, and launches that installed copy. It uses `~/Applications`, so it does not need an administrator password.
- `make uninstall` quits MouseKy, removes its installed copy, configuration, caches, logs, saved state, preferences, and its Accessibility/Input-Monitoring grants. Source files and `.build` remain untouched.

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
- The **G502 Onboard Profile** panel supports the directly connected `046D:C08D` G502 LIGHTSPEED. It uses macOS IOKit directly; no Logitech package or third-party driver is required. Quit G HUB before using it so the two applications do not compete for HID++ responses.
- **Reload is read-only.** It dynamically discovers HID++ features `0x8100`/`0x1802`; Device Reset is never invoked. Backups (`.json`, `.bin`, manifest and SHA-256) are stored under `~/Library/Application Support/MouseKy/Backups/`.
- Writes are allowlisted only for `046D:C08D`, firmware `MPM 17.00.B0008`, feature version `0`, and the exact known 11-button/255-byte layout. Other firmware and ROM profiles remain read-only.
- Reset changes only documented button fields in both banks. DPI, polling, LEDs, macros and unknown bytes remain unchanged. It writes the active profile, verifies it, commits the unchanged control sector last, then verifies through a fresh HID++ session. Errors stop immediately without retries.

### Backup and recovery

Keep each `.json`, `.bin`, and `.manifest.json` set together and never unplug while resetting. If verification fails, do not retry: preserve the backup and restore with G HUB's onboard-memory workflow or a separately reviewed HID++ recovery tool. MouseKy intentionally does not blindly restore raw bytes.

## Manual verification

- Connect/disconnect a mouse and run **Scan Mice** again.
- Scan each physical button; ensure only emitted macOS button numbers appear.
- Confirm unmapped buttons retain their original behavior.
- Map an extra button and confirm its native event is blocked while the chosen shortcut is emitted.
- Record shortcuts with Command, Control, Option, and Shift modifiers.
- Revoke/regrant both permissions and confirm the permission state is reported accurately.
- For a G502 C08D, quit G HUB, select the mouse, open **G502 Onboard Profile**, and choose **Reload**. Confirm that firmware, mode, active sector, both button banks, and the backup path appear.
- Before editing, retain the `.json`, `.bin`, and `.manifest.json` files. Change one non-primary assignment, verify the reported sector read-back, then physically test that button. Do not disconnect the mouse during a flash write.

## Tests

The `MouseKyTests` target covers shortcut policy plus HID++ framing, error correlation, real C08D descriptor fixtures, 255-byte sector chunking, CRC handling, button-bank offsets, and preservation of unrelated profile bytes.
