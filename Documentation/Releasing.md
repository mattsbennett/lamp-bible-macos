# Releasing Lamp Bible for Mac

Lamp Bible for Mac runs without the App Sandbox, so it can't ship through the Mac App Store.
It's distributed as a signed, notarized disk image from GitHub Releases, and installed copies
update themselves with [Sparkle](https://sparkle-project.org).

A release touches three places:

| Where | What |
| --- | --- |
| This repository | Version numbers, third-party notices, the archive and the disk image |
| GitHub Releases on `mattsbennett/lamp-bible-macos` | Hosts the `.dmg` |
| `lamp-bible-web` → `lib/site.ts` → `macRelease` | Drives the download pages *and* the Sparkle feed at `https://lampbible.com/appcast.xml` |

Installed copies learn about a release only when the website deploys with the new `macRelease`.
Until then, uploading to GitHub publishes nothing to existing users.

## One-time setup

1. **Developer ID Application certificate.** Only the Apple Developer account holder can create
   one: Xcode → Settings → Accounts → the team → Manage Certificates → + → Developer ID
   Application. `security find-identity -v -p codesigning` should then list a
   `Developer ID Application: … (BM8474Q7J2)` identity. The Apple Development certificates are
   not enough — Gatekeeper rejects apps signed only with them.

2. **Notarization credentials.** Create an app-specific password at
   [account.apple.com](https://account.apple.com) → Sign-In and Security, then store it in the
   Keychain under a profile name the commands below use:

   ```sh
   xcrun notarytool store-credentials lamp-notary --apple-id <your Apple ID> --team-id BM8474Q7J2
   ```

3. **Sparkle signing key.** Already generated; its public half is `SUPublicEDKey` in
   `Resources/Info.plist`. The private half lives only in the login Keychain. Keep an offline
   backup (`generate_keys -x <file>`, stored in a password manager). If it is lost, every installed
   copy rejects all future updates and users must reinstall by hand. Never commit it.

   The Sparkle tools are in the resolved package artifacts; the commands below use:

   ```sh
   SPARKLE_BIN=$(ls -d ~/Library/Developer/Xcode/DerivedData/Lamp_Bible-*/SourcePackages/artifacts/sparkle/Sparkle/bin | head -1)
   ```

## Release gates

Don't start the build until both of these pass. Each one protects something that can't be
recalled once a disk image is public.

### 1. Bundled content is cleared

The app copies `../lamp-bible-modules/modules_db/bundled_modules.db.zlib` into its bundle.
Rebuild it without pending-rights content, from the modules repository:

```sh
python3 scripts/bundle_all.py --book-modules outputs/books -o modules_db/bundled_modules.db
```

Never use `--include-pending-rights` for a release. Without it, the bundler includes only modules
whose `CONTENT_RIGHTS.json` status is releasable — `cleared`, `owner-approved` (with a dated
`releaseDecision`), or `territory-restricted` (with its territory control) — and fails closed on
anything else. See that repository's `RELEASE_RIGHTS_CHECKLIST.md`.

### 2. Third-party notices are complete

```sh
swift package resolve
python3 scripts/generate_third_party_notices.py
```

This writes `Resources/Third Party Licenses/`, which ships in the app and opens from
Help → Third-Party Notices. It exits non-zero, and the release stops, when:

- a shipped dependency publishes no licence, unless the script's `ACCEPTED_GAPS` table records a
  dated decision to ship it anyway (currently only SwiftUIEKtensions). `--allow-gaps` skips this
  check entirely and is for development builds only;
- a newly resolved package has no entry in the script's `PACKAGES` or `EXCLUDED` tables;
- the TipTap editor bundle no longer matches the iOS app's, whose JavaScript notices it reuses.

The notices depend on the content database, so run this *after* gate 1. The CrossWire KJV notice
is included only when the database contains `KJVs`. Commit the regenerated folder, and update the
Mac section of `lamp-bible-web/app/software-licences/page.tsx` if any component or version
changed.

## Building a release

Set the version once for the commands that follow:

```sh
VERSION=0.2.0
```

### 1. Bump the version numbers

In Xcode, select the **Lamp Bible** target → General → Identity:

- **Version** (`MARKETING_VERSION`) — the version people see, e.g. `0.2.0`.
- **Build** (`CURRENT_PROJECT_VERSION`) — an integer that **must increase with every release**.
  Sparkle compares build numbers, not version strings: a release with a new version but the same
  build number is never offered to anyone.

Set both for the Debug and Release configurations, and set the **lamp-mcp** target's build number
to match. Commit.

### 2. Archive and export

```sh
rm -rf build && mkdir build

xcodebuild -project "Lamp Bible.xcodeproj" -scheme "Lamp Bible" -configuration Release \
  -destination "generic/platform=macOS" -archivePath build/LampBible.xcarchive archive

xcodebuild -exportArchive -archivePath build/LampBible.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
```

Export re-signs the app, its embedded `lamp-mcp` helper and Sparkle's own helpers with the
Developer ID certificate.

### 3. Check the exported app

```sh
APP="build/export/Lamp Bible.app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime"
lipo -archs "$APP/Contents/MacOS/Lamp Bible"          # expect: x86_64 arm64
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" "$APP/Contents/Info.plist"
```

The first two lines must show the Developer ID authority and the hardened runtime. If `lipo`
shows only `arm64`, the site's "Apple silicon and Intel" claim is wrong for this build — fix the
build or `macRelease.architectures` before publishing.

### 4. Notarize and staple the app

Stapling the app itself lets it pass Gatekeeper on first launch even without a network
connection.

```sh
ditto -c -k --keepParent "$APP" build/LampBible.zip
xcrun notarytool submit build/LampBible.zip --keychain-profile lamp-notary --wait
xcrun stapler staple "$APP"
```

If notarization fails, `xcrun notarytool log <submission id> --keychain-profile lamp-notary`
explains why.

### 5. Build, sign, notarize and staple the disk image

```sh
DMG="build/Lamp-Bible-$VERSION.dmg"
mkdir build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Lamp Bible" -srcfolder build/dmg -ov -format UDZO "$DMG"

codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile lamp-notary --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
```

`spctl` must report `accepted` and `source=Notarized Developer ID`.

### 6. Sign the update and record its details

```sh
"$SPARKLE_BIN/sign_update" "$DMG"      # prints sparkle:edSignature="…" length="…"
shasum -a 256 "$DMG"
```

Sign the **final, stapled** disk image. Stapling changes the file, and a signature taken before
it makes every installed copy reject the update.

### 7. Publish the disk image

```sh
gh release create "v$VERSION" "$DMG" --repo mattsbennett/lamp-bible-macos \
  --title "Lamp Bible $VERSION" --notes "<what changed>"
```

The download URL is
`https://github.com/mattsbennett/lamp-bible-macos/releases/download/v$VERSION/Lamp-Bible-$VERSION.dmg`.

### 8. Update the website

In `lamp-bible-web/lib/site.ts`, update `macRelease`:

| Field | Value |
| --- | --- |
| `version` | `$VERSION` |
| `build` | The new build number |
| `releasedAt` | Today, as `YYYY-MM-DD` |
| `url` | The GitHub download URL above |
| `lengthBytes` | `length` from `sign_update` |
| `edSignature` | `sparkle:edSignature` from `sign_update` |
| `sha256` | From `shasum` |

Also update `minimumOS` and `minimumSystemVersion` if the deployment target changed. Build, commit
and deploy. The first time `url` is set, it also turns on every Mac download link on the site, and
the Mac sections of the app privacy page (software updates and AI chat) — so for the first release,
also bump the "Last updated" date in `app/privacy/apps/page.tsx`.

### 9. Verify the release

```sh
curl -s https://lampbible.com/appcast.xml | xmllint --format -
curl -sI https://lampbible.com/download/mac/latest | grep -i location
curl -sL https://lampbible.com/download/mac/latest -o /tmp/check.dmg && shasum -a 256 /tmp/check.dmg
```

- The feed lists the new version, build, length and signature.
- `/download/mac/latest` redirects to the new disk image, and its checksum matches.
- The feed may take up to ten minutes to update at the edge.

Then install the **previous** release on a Mac, choose Lamp Bible → Check for Updates…, and let it
update. This is the only test that proves the whole chain: the build number, the signature, the
feed and the hosting. For the very first release there's nothing to update from, so run this test
when shipping the second.

## If a release goes wrong

- **Stop offering it:** restore the previous `macRelease` values and redeploy. Copies that haven't
  updated yet won't be offered the bad build.
- **Copies that already updated can't be rolled back.** Sparkle only moves forward, so ship a fix
  with a higher build number.
- **Never reuse a build number** or replace a published disk image in place. A cached feed could
  then pair the old signature with the new file, and installed copies would reject the update.
