# DOOM (2016) launcher

Mac launcher for a GOG copy of DOOM (2016). The game is not in the repo or the release zip. The app is `Doom2016GOG.app`, bundle id `com.doom2016.macos`. GitHub repo: `truwa/doom2016-launcher` (private until the pre-release checklist below). Support files live in `~/Library/Application Support/DOOM 2016`.

## How it runs

`macos/DoomApp.swift` is the SwiftUI app. It shells out to the bundled Python and `launch.py`.

`launch.py` downloads Wine (latest WineHQ macOS build from Gcenx) into the support folder, creates the prefix, installs Microsoft's VC++ 2015–2022 runtime, and starts `DOOMx64vk.exe`. Vulkan is the bundled KosmicKrisp ICD (`vulkan/kosmickrisp_icd.json` plus `libvulkan_kosmickrisp.dylib`). GOG install and save sync use Heroic gogdl v1.3.1, also downloaded into the support folder. The GOG token file is `gog-auth.json`, mode `0600`. The support folder is mode `0700`. Lines that contain `token` are not printed.

`macos/AppUpdate.swift` is the launcher update check and installer. `build_app.sh` assembles `dist/Doom2016GOG.app`. `release.sh` signs, notarizes, staples, zips, and publishes.

## Build, sign, notarize, release

Certificate on this machine: `Developer ID Application: Mehmet Akif Ozdas (2DG34W64L7)`. Team ID `2DG34W64L7`.

One-time, the notary password stays in the Keychain. There is no profile stored yet:

```bash
xcrun notarytool store-credentials doom2016-notary --apple-id YOU@icloud.com --team-id 2DG34W64L7
```

Then:

```bash
./release.sh 1.2.0 path/to/notes.txt
```

That sets the version, runs `build_app.sh` with `REQUIRE_SIGN=1`, signs every nested Mach-O inside-out with hardened runtime and a timestamp, notarizes the zip, staples the app, zips the stapled app as `dist/DOOM-2016-<version>.zip`, and runs `gh release create`. On a rejected notarization it prints `notarytool log`. `DEBUG=1` is refused. Override the profile with `NOTARY_KEYCHAIN_PROFILE`.

`build_app.sh` alone builds `dist/Doom2016GOG.app`. `DEBUG=1` compiles in the test feed. `PYTHON_STANDALONE` can point at an existing python-build-standalone tree. No home-directory path is hard-coded.

Entitlements in `macos/entitlements.plist` go on executables only (the app and bundled Python). Dylibs get the hardened runtime and a timestamp, without those keys.

- `allow-unsigned-executable-memory`: Wine writes Windows code into memory and executes it. The hardened runtime blocks that without this key.
- `allow-jit`: Wine's code allocator uses `MAP_JIT` under the hardened runtime.
- `disable-library-validation`: KosmicKrisp and Wine's libraries are not all sealed into this bundle under this Team ID.

The downloaded Wine process does not inherit these entitlements. It is a separate program in the support folder.

## Updates

Checks run only from Check for Updates. Nothing checks on launch.

The feed is `https://api.github.com/repos/truwa/doom2016-launcher/releases/latest`. Versions are semantic versions (`1.10` is newer than `1.9`, a prerelease is older than the release). The dialog says up to date, or names the new version and shows the release notes, or a readable error.

Download Update opens a separate window: HTTPS zip, byte count and percent, Cancel. The zip is unpacked in a temp folder. Before it can be installed the new app must pass `codesign --verify --deep --strict`, the same Team ID as the running app, bundle id `com.doom2016.macos`, and `spctl --assess`. Any failure stops and leaves the installed app alone.

Update & Relaunch starts a helper and quits. The helper waits until this process exits, copies the new app beside the current one, renames the old app aside, then renames the new one into place. If a step fails it puts the old app back. It clears `com.apple.quarantine` only when that attribute is present. Temp files and the backup are removed after a successful relaunch. The installed location does not have to be `/Applications`.

If macOS is running the app from `AppTranslocation` (a zip that was opened in place), the update refuses. Move the app to a normal folder and open that copy. The previous helper tried to `rm -rf` that read-only path and filled `/tmp/doom2016-update.log` with "Read-only file system".

## Debug feed while the repo is private

Release binaries do not contain a token or a feed override. A `DEBUG=1` build reads `DOOM_UPDATE_FEED` (a folder with `release.json` and a zip, or an `http://127.0.0.1` / `http://localhost` URL). It can also read a GitHub token from the Keychain item service `doom2016-launcher-update`, account `github`. Do not put that token in the repo.

```bash
security add-generic-password -s doom2016-launcher-update -a github -w "$TOKEN"
DEBUG=1 ./build_app.sh
./scripts/make-test-update.sh 1.2.0
open --env DOOM_UPDATE_FEED="$PWD/dist/update-test" --env DOOM_UPDATE_SKIP_NOTARIZATION=1 dist/Doom2016GOG.app
```

`DOOM_UPDATE_SKIP_NOTARIZATION=1` skips only the `spctl` check, and only for that debug feed. Signature and Team ID are still required.

## Known issues

- The repo is private, so the public releases API returns HTTP 404. That is what made the update link unreachable. Shipping an update does not fix already-installed 1.1 copies until they can see a public release, and those copies still use the old replacer.
- No notarytool keychain profile is stored yet. `./release.sh` stops and prints the `store-credentials` command.
- Wine is whatever Gcenx has marked latest at first launch, not a pinned commit. The installed version is written to `WINE_VERSION`.
- Full screen and Command-Tab still close the game. Borderless does not.
- KosmicKrisp in the app is the x86_64 compat build v0.1.0 (Mesa 26.2.4). Macs before the M5 need that patched build.

## Pre-release checklist

1. Scan history for secrets: `git log -p --all | grep -E 'gho_|ghp_|github_pat_|BEGIN PRIVATE|AKIA'`. On 2026-10-20 that scan matched nothing.
2. Confirm the release binary has no feed override: `strings dist/Doom2016GOG.app/Contents/MacOS/Doom | grep DOOM_UPDATE_FEED` should print nothing. A DEBUG build will print it.
3. Make the repository public yourself.
4. Install the previous release, use Check for Updates, and install the new notarized zip from the real GitHub release.

## Changelog

### 2026-10-20

Update checks are manual. The download window verifies the signature, Team ID, and notarization, then a helper swaps the app in place and relaunches. `release.sh` signs inside-out, notarizes, staples, and publishes. DEBUG builds can point at a local feed. License texts for Wine, gogdl, and KosmicKrisp are in `licenses/`. The GOG token file stays mode `0600` in a `0700` support folder.
