# Releasing Windows Manager

There are two ways to release. Today only the first one is possible, because there is no Apple
Developer account yet.

## 1. Unsigned zip (no Apple account)

Build the zip:

```sh
scripts/package-zip.sh
```

This runs `scripts/bundle-app.sh` and writes `build/WindowsManager-<version>.zip`. It prints the
sha256 and size. Share the zip and the sha256 together so people can check the download.

The zip is signed with the local dev certificate (`scripts/make-dev-cert.sh`) if it exists, otherwise
ad-hoc. It is not notarized, so macOS blocks it on first launch.

### What users must do

1. Unzip and drag `Windows Manager.app` to `/Applications`.
2. Open it once with **right-click > Open**, then click **Open** in the dialog.
   Or, in Terminal:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Windows Manager.app"
   ```
3. Grant **Accessibility** in System Settings > Privacy & Security > Accessibility. Every user
   has to do this for their own Mac. It is never shared between machines.

### Why the Accessibility grant may not survive

macOS (TCC) ties the Accessibility grant to the app's code signature. The grant survives updates
only when the signature is stable:

- On the builder's Mac, the dev certificate from `scripts/make-dev-cert.sh` gives a stable identity,
  so rebuilds keep the grant.
- Ad-hoc builds change their signature on every build, so the grant can disappear after each rebuild.
- A user's copy of the app has a different identity from the builder's Mac, so users always grant
  Accessibility themselves. When a new version is installed, the grant may need to be given again.

## 2. Notarized release (Apple Developer account)

Cost: the Apple Developer Program, $99 per year.

Setup, once:

1. Join the Apple Developer Program and create a **Developer ID Application** certificate in
   Xcode or the developer portal. Confirm it is in the keychain:
   ```sh
   security find-identity -v -p codesigning
   ```
2. Store notarization credentials in a keychain profile. Use an app-specific password from
   appleid.apple.com:
   ```sh
   xcrun notarytool store-credentials windows-manager
   ```

Each release:

```sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
NOTARY_PROFILE="windows-manager" \
    scripts/release-notarized.sh
```

The script builds the app, signs it with the hardened runtime (including Sparkle's helpers), submits it
to Apple with `notarytool --wait`, staples the ticket, checks it with `spctl`, and writes the final
`build/WindowsManager-<version>.zip`. If `SIGN_IDENTITY` or `NOTARY_PROFILE` is missing, the script
stops and lists what is missing. Nothing is sent to Apple until both are set.

With a notarized build, users no longer need the right-click step or the `xattr` command.
They still grant Accessibility once.

## Updates with Sparkle (no Apple account needed)

The app updates through Sparkle. Updates need an EdDSA key pair, which you can create without an Apple
account. Update checks stay inactive until the appcast URL and public key are set in Info.plist.
The steps are in [RELEASE-NOTES-SPARKLE.md](RELEASE-NOTES-SPARKLE.md): generate the keys, host the
appcast, sign each zip with `sign_update`, and bump `CFBundleVersion` for every release.
