# Local signing

To reduce repeated Keychain prompts after app updates, use an Apple-issued **Apple Development** identity for local development, or **Developer ID Application** where appropriate, and retain the same team and bundle identifier. This is the recommended signing path; access still depends on the item's permissions and macOS policy.

**A self-signed certificate is not a reliable fix.** Modern Keychain access checks include a partition identifier in addition to the app's designated requirement. Apple's published `securityd` implementation uses a team-based partition for recognized Apple-issued developer identities and falls back to a code hash for other signed code. A rebuilt self-signed app can therefore prompt again despite having an identical designated requirement. See [Apple's partition-identifier implementation](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp#L187-L286).

Do not add global trust to a self-signed certificate or weaken Keychain access controls to work around this behavior. The build script still accepts self-signed identities for local signing, but successful signing and verification do not prove prompt-free Keychain access. This script does not notarize the app or prepare a public distribution release.

## Configure an identity once

A free Apple Account can enable a **Personal Team** in Xcode, which manages its development certificates locally. Distribution services and certificate availability have separate account requirements; see Apple's [developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account) and [certificate types](https://developer.apple.com/help/account/certificates/certificates-overview). The signing private key stays in Keychain; this app and build script do not need it exported.

1. In Xcode's account settings, select your Apple account and team, open **Manage Certificates**, and create or select an **Apple Development** identity. Use **Developer ID Application** when that is the appropriate identity available to your developer team. Availability depends on your account and Apple's current requirements. Keep the certificate and its private key in your login keychain. See Apple's [signing-certificate management guide](https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html).

   If certificate creation is unavailable there, create a temporary local macOS app project in Xcode. In its **Signing & Capabilities** tab, select your **Personal Team** and enable **Automatically manage signing**; Xcode can create the development identity it needs. This temporary project is only for local setup and need not be published or added to this repository. Do not revoke another certificate to proceed; if Xcode requires revocation, stop and resolve the account's certificate availability first.

2. Find its full 40-character SHA-1 fingerprint:

   ```sh
   security find-identity -p codesigning
   ```

   Match the Apple-issued identity you chose. This lists certificates with their private keys. The generic builder does not filter the list with `-v`; it checks that the selected identity exists and lets signing and signature verification determine whether the build succeeds.
3. Save just that fingerprint in `.codesign-identity` at the repository root. Replace the placeholder below; do not include a certificate name, comments, or shell commands:

   ```sh
   printf '%s\n' 'YOUR_40_CHARACTER_CERTIFICATE_SHA1' > .codesign-identity
   ./build.sh
   ```

   The file is ignored by Git and read as plain text. Alternatively, override it for one build:

   ```sh
   CODE_SIGN_IDENTITY='YOUR_40_CHARACTER_CERTIFICATE_SHA1' ./build.sh
   ```

   An explicitly set environment variable takes precedence, including an invalid or empty value. Names, partial fingerprints, and `-` are rejected. Never commit private keys or certificate exports.

During signing, macOS may ask whether `codesign` can use the signing private key. This is a separate permission from Float Tasks reading its saved Google credentials.

## Migrate an existing installation

Quit Float Tasks, build with the chosen Apple-issued identity, and replace your installed copy with `dist/Float Tasks.app`. Open that copy. When macOS asks whether **Float Tasks** can access one of its existing Keychain items, choose **Always Allow** if you trust this build. Migration can require approval for each affected item. A single **Allow** applies only to that request; see Apple's [Keychain permission guide](https://support.apple.com/guide/keychain-access/kyca1243/mac).

Continue using the same identity and bundle identifier for later updates. Verify the result with a subsequent rebuild; do not assume that clicking Always Allow once proves future builds will be accepted. Certificate replacement, expiry or revocation, locked Keychains, and changed access policies can still require attention. Google token expiration and consent are separate from Keychain access.

For an isolated check before updating the app, use the [optional manual signing continuity test](../tests/README.md#optional-manual-signing-continuity-test). It takes an explicit certificate fingerprint, signs two changed probe executables with matching certificate-anchored requirements, and checks a single synthetic Keychain item's creation, read after replacement, and cleanup without item-access dialogs. It never reads Float Tasks credentials or changes Keychain trust or ACLs. This test is separate from the normal test suite and CI; successful signature verification alone is not a passing continuity result.

## Build safeguards

- Without signing configuration, first builds and CI can use ad-hoc signing with a warning.
- Invalid configuration, an unavailable identity, failed signing, or failed signature verification stops the build before the old app is replaced. There is no ad-hoc fallback.
- If the existing app in `dist` is certificate-signed, an unconfigured build stops. Restore its signing configuration. If you intentionally want to return to ad-hoc builds, first preserve or move that app out of `dist`, then remove the configuration and build again. The script checks only its `dist` output, not copies installed elsewhere.
- The script uses the designated requirement generated by `codesign`. It does not replace it with a weak identifier-only requirement or broaden access to Keychain items.
