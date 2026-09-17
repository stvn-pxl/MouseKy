# Release checklist

## Every release

1. Update `CHANGELOG.md` and remove “Unreleased” from the release date.
2. Set `MARKETING_VERSION` in the Xcode project to the intended semantic
   version.
3. Run:

   ```bash
   xcodebuild test \
     -project MouseKy.xcodeproj \
     -scheme MouseKy \
     -destination 'platform=macOS' \
     -derivedDataPath .build-tests
   ```

4. Perform the manual checks in `README.md` and `Docs/CoreHIDGate.md`.
5. For onboard-memory changes, verify the exact allowlisted G502 firmware and
   inspect read-back before disconnecting hardware.
6. Merge through a green CI run.
7. Create and push an annotated tag:

   ```bash
   git tag -a v1.0.0 -m "MouseKy 1.0.0"
   git push origin v1.0.0
   ```

8. Confirm the release workflow reports successful code-sign verification,
   notarization, stapling, Gatekeeper assessment, and both architectures.
9. Download the published DMG on a clean Mac, drag the app to Applications,
   launch it, grant permissions, and complete a smoke test.
10. Verify the published SHA-256 checksum.
