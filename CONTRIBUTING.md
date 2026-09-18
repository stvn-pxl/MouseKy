# Contributing to MouseKy

Thanks for helping improve MouseKy.

## Before you start

- Search existing issues before opening a new one.
- Use an issue to discuss substantial behavior or architecture changes first.
- Keep pull requests focused and avoid unrelated formatting changes.
- Never test onboard-memory writes on an unsupported device or firmware.

## Development setup

MouseKy requires macOS 15 or newer and the full Xcode application.

```bash
git clone https://github.com/stvn-pxl/MouseKy.git
cd MouseKy
make build
```

Run the test suite with:

```bash
xcodebuild test \
  -project MouseKy.xcodeproj \
  -scheme MouseKy \
  -destination 'platform=macOS' \
  -derivedDataPath .build-tests
```

Hardware behavior must also be verified manually. Follow
[`Docs/CoreHIDGate.md`](Docs/CoreHIDGate.md) and never disconnect a device while
an onboard-memory write is active.

## Pull requests

1. Branch from `main`.
2. Add or update tests for behavior changes.
3. Run the complete test suite.
4. Update documentation when behavior, compatibility, or permissions change.
5. Explain hardware and firmware used for manual testing.

By contributing, you agree that your contribution is licensed under the MIT
License.
