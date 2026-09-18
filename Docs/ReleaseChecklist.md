# Release checklist

## One-time Sparkle setup

Sparkle uses the Keychain account `io.github.stvn-pxl.MouseKy`. Export its
private key with Sparkle's matching `generate_keys` tool:

```bash
generate_keys --account io.github.stvn-pxl.MouseKy -x MouseKy-Sparkle.key
gh secret set SPARKLE_PRIVATE_KEY_BASE64 --repo stvn-pxl/MouseKy \
  < MouseKy-Sparkle.key
```

Store an encrypted copy in the project's credential backup, then securely
remove the plaintext export. Never commit it. The public key is intentionally
committed in `MouseKy/Info.plist`.

## Every release

1. Confirm the Sparkle private key is available as the
   `SPARKLE_PRIVATE_KEY_BASE64` GitHub Actions secret. Keep an encrypted backup
   outside GitHub; losing both the backup and Keychain copy prevents existing
   installations from trusting future updates.
2. Update `CHANGELOG.md` and remove “Unreleased” from the release date.
3. Set `MARKETING_VERSION` in the Xcode project to the intended semantic
   version.
4. Run:

   ```bash
   xcodebuild test \
     -project MouseKy.xcodeproj \
     -scheme MouseKy \
     -destination 'platform=macOS' \
     -derivedDataPath .build-tests
   ```

5. Perform the manual checks in `README.md` and `Docs/CoreHIDGate.md`.
6. For onboard-memory changes, verify the exact allowlisted G502 firmware and
   inspect read-back before disconnecting hardware.
7. Merge through a green CI run.
8. Create and push an annotated tag:

   ```bash
   git tag -a v1.0.0 -m "MouseKy 1.0.0"
   git push origin v1.0.0
   ```

9. Confirm the release workflow reports successful code-sign verification,
   notarization, stapling, Gatekeeper assessment, both architectures, and a
   valid EdDSA signature in `appcast.xml`.
10. Confirm the release contains the DMG, Sparkle ZIP, `appcast.xml`, and both
    SHA-256 checksum files. Verify that the appcast version, build number, and
    ZIP URL match the release.
11. Download the published DMG on a clean Mac, drag the app to Applications,
   launch it, grant permissions, and complete a smoke test.
12. Verify the published SHA-256 checksums.
13. On a Mac with the previous release installed, choose **Check for
    Updates…** and confirm the new release is detected. Exercise **Later** and
    **Skip This Version**, then clear the skipped version with
    `defaults delete io.github.stvn-pxl.MouseKy SUSkippedVersion` and install
    the update. Confirm MouseKy restarts with its configuration and
    Accessibility and Input Monitoring permissions intact.
