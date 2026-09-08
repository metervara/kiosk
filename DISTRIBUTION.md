# GitHub distribution

Use Git tags for versions and GitHub Releases for downloads. Each release has a universal `Kiosk.app` ZIP that runs on Apple Silicon and Intel, plus a SHA-256 checksum. The source repository stays small: build products, credentials, and release archives are ignored; editable icons and plists are tracked.

## Prepare a version

The single source of version metadata is **`Assets/Info.plist`**:

- `CFBundleShortVersionString`: the visible version, for example `1.1.0`.
- `CFBundleVersion`: a positive integer build number; increase it for each release build, including prereleases.

Edit those fields directly, or use the explicit editing command:

```sh
./scripts/version.sh 1.1.0 2
```

`./scripts/version.sh` shows and validates the current values. Builds copy the plist verbatim; they do not invent versions, replace placeholders, or rewrite the source asset.

Commit the version change and other release changes, then push a matching annotated tag:

```sh
git add Assets/Info.plist
git commit -m "Release 1.1.0"
git tag -a v1.1.0 -m "Kiosk 1.1.0"
git push origin main
git push origin v1.1.0
```

For the initial version already in this folder, use `v1.0.0` after committing the project. Prerelease tags may have `-alpha.N`, `-beta.N`, or `-rc.N`, such as `v1.1.0-rc.1`; the plist still contains `1.1.0`, and each candidate gets its own incremented build number. A mismatched or malformed tag fails validation.

## What GitHub does

`.github/workflows/ci.yml` tests and builds branch pushes and pull requests on both `macos-15` (Apple Silicon) and `macos-15-intel`. The release workflow reuses those checks for the tagged commit. These runner labels are listed in GitHub's [runner image documentation](https://github.com/actions/runner-images).

After both test jobs pass, `.github/workflows/release.yml`:

1. Checks that the tag matches the source plist.
2. Builds each architecture using SwiftPM, combines them with `lipo`, and ad-hoc signs the resulting bundle.
3. Packages `Kiosk-1.1.0-macos-universal.zip` and its `.sha256` file.
4. Attaches the downloads and release notes to a draft, then automatically publishes the completed release. Candidate tags are also marked as prereleases.

Pushing the tag is the release action: no separate Publish click is needed. Re-running a failed workflow can replace assets in an unfinished draft and refreshes the generated installation/signing block while preserving change notes you edited outside that block. Keep the `kiosk-build` comment markers so the block can be found. It refuses to overwrite an already published release: make a new version for changes. See the [GitHub release command documentation](https://cli.github.com/manual/gh_release_create).

After publication, users can download the ZIP from your repository's Releases page, unzip it, and move `Kiosk.app` into `/Applications`. Use the attached app ZIP, not GitHub's automatically generated “Source code” archive. A public repository's published releases are publicly downloadable; private repository downloads require repository access.

## Ad-hoc signing

Local builds and GitHub releases always run `codesign --force --sign -`. No Apple Developer account, certificates, keychain setup, repository signing secrets, or notarization service is required.

The app is ad-hoc signed and **not notarized**. macOS Gatekeeper may block a browser-downloaded copy until manually approved. Release notes identify this signing status.

## Build a release locally

For a universal ad-hoc signed download:

```sh
./scripts/package-release.sh
```

Or specify a matching tag, including a prerelease suffix:

```sh
./scripts/package-release.sh v1.1.0-rc.1
```

Nothing is uploaded to GitHub by the local packaging command.

The standalone `./build.sh --universal` makes just the universal app. Plain `./build.sh` keeps the faster current-architecture build. All generated release files are in `dist/`.

To verify a downloaded archive against its checksum, keep the ZIP and `.sha256` file together and run:

```sh
shasum -a 256 -c Kiosk-1.1.0-macos-universal.zip.sha256
```

## Installing updates

End the kiosk session, quit the menu-bar app, replace `/Applications/Kiosk.app`, and launch it again. The bundle ID remains `xyz.metervara.kiosk`, so existing configuration and operator credentials remain in the same preferences domain. Keep the app in the same location when using launch at login.

This setup provides version history, release notes, and downloadable updates. There is no in-app automatic updater; install updates deliberately between exhibitions or maintenance windows.
