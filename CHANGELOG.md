# Changelog

All notable changes to MouseKy are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.1] - 2026-11-23

### Added

- Logitech G309 support over Bluetooth LE, including button names.
- Each button row shows the button's built-in function.

### Fixed

- Mice whose primary HID usage is Keyboard (such as the G309 over Bluetooth)
  are detected, and keyboards with mouse-key interfaces are no longer listed
  as mice.
- HID++ works with devices that only expose the long report.
- Development builds no longer check for updates.

## [1.0.0] - 2026-09-17

### Added

- App-specific mouse profiles and shortcut mappings.
- Generic mouse discovery and button scanning.
- Logitech HID++ runtime control with state restoration.
- Guarded G502 C08D onboard-memory inspection and assignment changes.
- Open-source project governance and contribution documentation.
- CI validation for builds and tests.
- Automated signed, notarized Universal DMG releases.
- Signed Sparkle updates with daily stable-release checks, manual checks, and
  user-confirmed installation.

[Unreleased]: https://github.com/stvn-pxl/MouseKy/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/stvn-pxl/MouseKy/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/stvn-pxl/MouseKy/releases/tag/v1.0.0
