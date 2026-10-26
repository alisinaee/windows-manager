# Sparkle updates: setup and release steps

Windows Manager checks for updates with [Sparkle](https://sparkle-project.org) 2.x (package pinned in
`Package.swift`). The update check is inert until the app bundle has a feed URL, so builds without a
real appcast never contact a server.

The Info.plist keys below are **placeholders**. The real appcast URL and public key are set when
P7.1 and P7.2 are done. Until then, the menu item and About tab show "Updates are not configured yet".

## Info.plist keys (Resources/App/Info.plist)

```xml
<!-- SUFeedURL: placeholder, replace with the real appcast URL (P7.1, hosting). -->
<!-- <key>SUFeedURL</key> <string>https://REPLACE-ME/appcast.xml</string> -->

<!-- SUPublicEDKey: placeholder, replace with the public key printed by generate_keys (P7.2). -->
<!-- <key>SUPublicEDKey</key> <string>REPLACE-WITH-PUBLIC-ED25519-KEY</string> -->
```

Until both keys are present, `UpdateController` does not start the updater.

## Generate the signing keys (once)

Sparkle's `generate_keys` tool ships in the Sparkle release archive
(`Sparkle-2.x.tar.xz`, `bin/generate_keys`). Run it once on the release machine:

```sh
./bin/generate_keys
```

- It stores the private EdDSA key in the login Keychain and prints the public key. Put the public key
  in `SUPublicEDKey`.
- Back up the private key (`./bin/generate_keys -x private-key.txt`) somewhere safe. Losing it means
  existing installs cannot receive signed updates.
- Never commit the private key.

## Host the appcast

1. Build and sign the release: `SIGN_IDENTITY="Developer ID Application: ..." scripts/bundle-app.sh`.
2. Zip `build/Windows Manager.app` and sign the archive with Sparkle's `sign_update`:
   ```sh
   ./bin/sign_update "Windows Manager-0.1.1.zip"
   ```
3. Generate or update `appcast.xml` with `./bin/generate_appcast <folder-with-zips>`, or write the
   `<item>` by hand with the `sparkle:edSignature` and `length` that `sign_update` printed.
4. Upload the zip and `appcast.xml` to the host that `SUFeedURL` points to (P7.1).
5. Bump `CFBundleShortVersionString` and `CFBundleVersion` in Info.plist. Sparkle compares
   `CFBundleVersion`, so it must increase on every release.

## Verify

- `scripts/bundle-app.sh` copies `Sparkle.framework` into `Contents/Frameworks`. The executable finds it
  through the `@executable_path/../Frameworks` rpath.
- After the real keys are in place, open the built app and choose Check for Updates from the menu bar.
  Use a build with an older `CFBundleVersion` than the appcast entry to see the update offer.
