# 11 — App packaging and distribution

**Status:** build script and workflows written · **Evidence:** none of this ran in this review. The build script and CI are described from their source; no workflow has run on a hosted runner (the repository has no remote), and the built `.app` was never run against a real T3 Code. `swift test` was run for this review (see index).

## Purpose and user value

- **Get a double-clickable app** from the repository without installing anything global.
- **Reproducible release** from a version tag.
- **Trusted by macOS:** releases are signed with a Developer ID and notarized by Apple, so Gatekeeper opens them without an override (from v0.2.1; earlier releases were ad-hoc signed).

## Behaviour as built

### Toolchain

- Swift package, tools version 6.0, **Swift 5 language mode**, macOS 14 or later. No third-party dependencies.
- Products: `AgentHuddle` (the app), `fake-t3` (standalone fake server), `huddle-probe` (live-check tool). Targets: `HuddleCore` (no UI), `FakeT3`, `AgentHuddle`, tests.
- The `AgentHuddle` executable depends on `FakeT3`, so the shipped binary also contains the fake server and its launch modes (`--fixture`, `--mcp-url`, `--snapshot`, `--record`).

### `scripts/build-app.sh`

1. `swift build -c release --product AgentHuddle`.
2. Create `dist/Agent Huddle.app` and copy the binary to `Contents/MacOS/AgentHuddle`.
3. **Icon:** the binary renders its own 1024 px icon (`AgentHuddle --icon FILE`: a dark rounded tile with a lime outline, one buddy face and a lime status dot). `sips` scales it to 16–512 px plus @2x and `iconutil` makes `AppIcon.icns`. The 1024 px PNG is also copied to `assets/icon-1024.png` in the repository (a side effect outside `dist/`).
4. Copy `LICENSE` into `Contents/Resources`.
5. Write `Info.plist`:

   | Key | Value |
   |---|---|
   | `CFBundleIdentifier` | `app.t3huddle.AgentHuddle` |
   | `CFBundleName`, `CFBundleDisplayName` | Agent Huddle |
   | `CFBundleShortVersionString` | `$VERSION` (the release tag; a local build takes the newest `v*` tag) |
   | `CFBundleVersion` | `$BUILD` (the commit count; the release checks out the full history) |
   | `LSMinimumSystemVersion` | 14.0 |
   | `LSUIElement` | true (no Dock icon) |
   | `NSHumanReadableCopyright` | Copyright © 2026 Mika Koivisto. MIT License. |
   | `NSHighResolutionCapable` | true |

   No ATS keys, no sandbox entitlement, no usage-description keys.
6. **Codesign:** with `SIGN_IDENTITY`, else the first "Developer ID Application" identity in the keychain, using the hardened runtime and a secure timestamp (`--options runtime --timestamp`, no entitlements: the app needs none); else ad-hoc (`--sign -`). Then `codesign --verify --strict`.
7. Zip with `ditto` to `dist/AgentHuddle.zip`.

### Notarization and the DMG (`scripts/notarize.sh`)

1. Checks that the app is signed with a Developer ID (`codesign -dvv`, the authority lines) and, with `APPLE_TEAM_ID`, by that team.
2. Submits the zip with `xcrun notarytool submit --wait` (App Store Connect API key: `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`); anything but `Accepted` prints Apple's log and fails.
3. Staples the ticket to the app, zips it again, checks it with `spctl --assess --type execute`.
4. Builds `dist/AgentHuddle.dmg` with `scripts/make-dmg.sh` (below), signs it, notarizes and staples it, checks it with `spctl --assess --type open`.

### The DMG window (`scripts/make-dmg.sh`)

- **Contents:** the app, a link to `/Applications`, UDZO.
- **Background:** rendered by the app itself (`AgentHuddle --dmg-background DIR`, `DMGBackground.swift`): the dark panel colours, the "Agent Huddle" wordmark with a lime dot and rule, "Drag the app onto Applications to install.", the release version top right, a dashed lime arrow from the app to Applications, and four buddies standing bottom right. 660×400 at 1x and 2x, joined into one TIFF with `tiffutil` so Finder shows the sharp one on a Retina screen.
- **Label plates:** Finder draws icon labels black in light mode and white in dark mode, and a DMG cannot set their colour, so each label sits on a mid-grey plate (`#767A70`, about 4.5:1 for both). The plates are 124 pt wide, enough for "Agent Huddle.app" when Finder shows every extension.
- **Finder's path bar** is a global Finder setting and covers the bottom 28 pt when it is on; nothing important is drawn there.
- **Layout:** the window's `.DS_Store` (icon view, 128 pt icons, 13 pt text, no toolbar or sidebar, icon centres matching the background) is written by [dmgbuild](https://github.com/dmgbuild/dmgbuild) (MIT), not by scripting Finder, so it works headless in CI. It is installed into a throwaway virtualenv from `scripts/dmg-requirements.txt`: wheels only, pinned by hash, because the release job that runs it holds the signing keychain. `DMGBUILD=/path/to/dmgbuild` uses one you already have.
- **Checked** by mounting a DMG built this way and capturing its Finder window (dark mode, path bar on): the background fills the window and the labels sit on their plates. Light mode was not captured; the plate colour is chosen to work for black labels too.

Prints submission ids and statuses only. A new team's first submission can take hours (seen: over 30 minutes, then accepted); later ones take seconds.

It installs nothing and writes no login item.

### About and licence

- MIT licence, © 2026 Mika Koivisto, in `LICENSE`, in the bundle's resources and in the About panel (menu-bar item → About Agent Huddle, spec 10).
- The About text says the project is independent and not affiliated with or endorsed by T3 Tools.

### CI (`.github/workflows/ci.yml`)

- **Triggers:** push to `main` and `build/**`, and pull requests. Concurrent runs for a ref cancel older ones. Read-only contents permission, 30-minute timeout.
- **Runner:** `macos-15`.
- **Steps:** `swift --version`, debug build, `swift test` (loopback fake only), `scripts/build-app.sh`, upload `dist/AgentHuddle.zip` as artifact `AgentHuddle-<sha>`.
- **Signing dry run** (job `sign-and-notarize`, pushes to `build/**` only, never pull requests): the release's signing steps below, uploading the signed zip and DMG as `AgentHuddle-signed-<sha>`.

### Release (`.github/workflows/release.yml`)

- **Trigger:** push of a tag `v*`. Contents write permission.
- **Steps:** full-history checkout; `swift test`; `scripts/ci-signing-keychain.sh setup` (the certificate into a throwaway keychain, the API key into a temp file); `VERSION="${TAG#v}" scripts/build-app.sh` (Developer ID signed); `scripts/notarize.sh`; the keychain and key removed (always); `SHA256SUMS` for the zip and the DMG; `gh release create "$TAG" … --generate-notes --verify-tag` with the DMG, the zip and `SHA256SUMS`.
- **Secrets:** `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `APPLE_TEAM_ID`, passed only to the steps that need them.

### What users hit

| Situation | What happens | Evidence |
|---|---|---|
| First launch of a download | A notarized, stapled app or DMG opens after the usual "downloaded from the internet" question; releases up to v0.2.0 (ad-hoc) need **Open Anyway** | `spctl` accepts the CI build ("Notarized Developer ID"); not yet opened from a browser download |
| No Dock icon | The app is reachable only from the menu bar | Code |
| macOS Keychain prompts | An ad-hoc signature changes with every build, so a new build prompts again for Keychain access; a Developer ID signature keeps the identity, so signed updates do not. The first signed version prompts once (the identity changed). All secrets are in one item (`vault`) | Observed by the maintainer (several prompts per new build before the vault); the vault itself is tested against memory |
| Peer check | A wrong "Listener on the T3 port is not T3 Code" if the pid-to-bundle check misjudges a real install | Unproven (spec 08) |
| Sandbox | The app is not sandboxed; App Sandbox untried | README Limitations |
| Start at login | Not provided; add the binary under System Settings → General → Login Items by hand | README |

### Demo assets

`scripts/make-demo.sh` deletes and regenerates the tracked binaries under `demo/` (stills and a clip of the app's own panel) from the fake server; it needs `ffmpeg`. Run only when asked.

## T3 data and tools

None.

## Security and privacy

- The bundle contains no credentials and no real thread data; fixtures and fake data are synthetic.
- The release workflow publishes only the zip and its checksum.
- Release builds ship the loopback-only launch flags; `--mcp-url` exits for a non-loopback URL, and no flag takes a token.
- AGENTS.md: "No push, no remote, no publishing. Work stays on a local branch." The release workflow is written but must not run from this repository without that rule changing.

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| PKG-01 | The package builds, and its tests pass with no real T3 and no `~/.t3` access | `swift test` (305 tests in 38 suites) | **Run for this review** before the history cleanup: all passed in about 1 s. Not run by CI |
| PKG-07 | A tagged release is Developer ID signed, notarized and stapled, as a DMG and a zip | none | **CI**: the `build/signing` dry run, both submissions Accepted, `spctl`: "Notarized Developer ID" |
| PKG-02 | `scripts/build-app.sh` produces `dist/Agent Huddle.app` and `dist/AgentHuddle.zip` with the bundle id, version, `LSUIElement`, icon, licence, a Developer ID or ad-hoc signature | none | **None** in this review (the script writes to `assets/`, outside the allowed paths) |
| PKG-03 | The app does not read the Keychain or `~/.t3` in `--fixture` mode | `SecurityTests.sourcesTouchHomeT3OnlyForTheRuntimeFileAndNeverOpenSQLite` (static); `main.swift` wiring | Fake (static) |
| PKG-04 | The release version comes from the tag | none | **None** |
| PKG-05 | The About panel carries the MIT licence | none | **None** |
| PKG-06 | The sources contain no `UserDefaults`, SQLite mention, T3 secrets path or `--token` flag | `SecurityTests.sourcesTouchHomeT3OnlyForTheRuntimeFileAndNeverOpenSQLite`; `appBinaryDoesNotAcceptATokenOnTheCommandLine` | Fake (static) |

## Open questions

- **PKG-Q1 (owner: maintainer):** AGENTS.md forbids publishing while `release.yml` publishes on a tag. Keep the workflow dormant, or lift the rule when a remote exists?
- **PKG-Q2:** the build script rewrites the tracked `assets/icon-1024.png` each time. Intended?
- **PKG-Q3 (answered):** `CFBundleVersion` is the commit count, so it grows with every commit; a local build used to say 0.1.0 (1) whatever the release.
- **PKG-Q4:** the shipped binary includes `FakeT3` and `Scenario` code and its launch modes. Split the app target to drop them?
- **PKG-Q5:** `AppIcon.swift:3` says "four buddies"; the code draws one (`BuddyView(index: 0, …)`).
- **PKG-Q6:** with the single vault item, is one prompt per new ad-hoc build what users see? Observe once more.
- **PKG-Q7:** an updater (Homebrew cask, or an in-app check that needs an exception to "Loopback only") is on hold until signed releases are out.

## Sources

`Package.swift`, `scripts/build-app.sh`, `.github/workflows/{ci,release}.yml`, `Sources/AgentHuddle/{About,AppIcon,main}.swift`, `LICENSE`, README "Build, test, run" and "CI and releases", AGENTS.md "Commands".
