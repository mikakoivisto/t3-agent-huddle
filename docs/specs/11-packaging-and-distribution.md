# 11 — App packaging and distribution

**Status:** build script and workflows written · **Evidence:** none of this ran in this review. The build script and CI are described from their source; no workflow has run on a hosted runner (the repository has no remote), and the built `.app` was never run against a real T3 Code. `swift test` was run for this review (see index).

## Purpose and user value

- **Get a double-clickable app** from the repository without installing anything global.
- **Reproducible release** from a version tag.
- **Honest about trust:** the app is ad-hoc signed, not notarized; users must approve it once.

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
   | `CFBundleShortVersionString` | `$VERSION` (default `0.1.0`) |
   | `CFBundleVersion` | `1` (fixed) |
   | `LSMinimumSystemVersion` | 14.0 |
   | `LSUIElement` | true (no Dock icon) |
   | `NSHumanReadableCopyright` | Copyright © 2026 Mika Koivisto. MIT License. |
   | `NSHighResolutionCapable` | true |

   No ATS keys, no sandbox entitlement, no usage-description keys.
6. **Ad-hoc codesign** (`codesign --force --sign -`) and verify.
7. Zip with `ditto` to `dist/AgentHuddle.zip`.

It installs nothing and writes no login item.

### About and licence

- MIT licence, © 2026 Mika Koivisto, in `LICENSE`, in the bundle's resources and in the About panel (menu-bar item → About Agent Huddle, spec 10).
- The About text says the project is independent and not affiliated with or endorsed by T3 Tools.

### CI (`.github/workflows/ci.yml`)

- **Triggers:** push to `main` and `build/**`, and pull requests. Concurrent runs for a ref cancel older ones. Read-only contents permission, 30-minute timeout.
- **Runner:** `macos-15`.
- **Steps:** `swift --version`, debug build, `swift test` (loopback fake only), `scripts/build-app.sh`, upload `dist/AgentHuddle.zip` as artifact `AgentHuddle-<sha>`.

### Release (`.github/workflows/release.yml`)

- **Trigger:** push of a tag `v*`. Contents write permission.
- **Steps:** `swift test`; `VERSION="${TAG#v}" scripts/build-app.sh`; SHA-256 of the zip into `AgentHuddle.zip.sha256`; `gh release create "$TAG" … --generate-notes --verify-tag` with both files.
- No debug build step, no notarization, no signing identity.

### What users hit

| Situation | What happens | Evidence |
|---|---|---|
| First launch of a downloaded zip | Gatekeeper refuses an unsigned or un-notarized app; right-click → Open once (README) | Documented; not observed here |
| No Dock icon | The app is reachable only from the menu bar | Code |
| macOS Keychain prompts | An ad-hoc signature changes with every build, so a new build prompts again for Keychain access. All secrets are in one item (`vault`), so it is one prompt rather than one per credential. A Developer ID signature would stop the repeats | Observed by the maintainer (several prompts per new build before the vault); the vault itself is tested against memory |
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
| PKG-01 | The package builds, and its tests pass with no real T3 and no `~/.t3` access | `swift test` (291 tests in 35 suites) | **Run for this review** before the history cleanup: all passed in about 1 s. Not run by CI |
| PKG-02 | `scripts/build-app.sh` produces `dist/Agent Huddle.app` and `dist/AgentHuddle.zip` with the bundle id, version, `LSUIElement`, icon, licence, ad-hoc signature | none | **None** in this review (the script writes to `assets/`, outside the allowed paths) |
| PKG-03 | The app does not read the Keychain or `~/.t3` in `--fixture` mode | `SecurityTests.sourcesTouchHomeT3OnlyForTheRuntimeFileAndNeverOpenSQLite` (static); `main.swift` wiring | Fake (static) |
| PKG-04 | The release version comes from the tag | none | **None** |
| PKG-05 | The About panel carries the MIT licence | none | **None** |
| PKG-06 | The sources contain no `UserDefaults`, SQLite mention, T3 secrets path or `--token` flag | `SecurityTests.sourcesTouchHomeT3OnlyForTheRuntimeFileAndNeverOpenSQLite`; `appBinaryDoesNotAcceptATokenOnTheCommandLine` | Fake (static) |

## Open questions

- **PKG-Q1 (owner: maintainer):** AGENTS.md forbids publishing while `release.yml` publishes on a tag. Keep the workflow dormant, or lift the rule when a remote exists?
- **PKG-Q2:** the build script rewrites the tracked `assets/icon-1024.png` each time. Intended?
- **PKG-Q3:** `CFBundleVersion` is fixed at `1`; Sparkle-style updates or notarization would need it to grow.
- **PKG-Q4:** the shipped binary includes `FakeT3` and `Scenario` code and its launch modes. Split the app target to drop them?
- **PKG-Q5:** `AppIcon.swift:3` says "four buddies"; the code draws one (`BuddyView(index: 0, …)`).
- **PKG-Q6:** with the single vault item, is one prompt per new ad-hoc build what users see? Observe once more.

## Sources

`Package.swift`, `scripts/build-app.sh`, `.github/workflows/{ci,release}.yml`, `Sources/AgentHuddle/{About,AppIcon,main}.swift`, `LICENSE`, README "Build, test, run" and "CI and releases", AGENTS.md "Commands".
