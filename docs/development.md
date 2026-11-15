# Development

## Build, test, run

Needs Xcode (Swift 6.x) on macOS 14+. Nothing global is installed; everything stays in `.build/`.

```sh
swift build                 # or: open Package.swift in Xcode
swift test                  # 224 tests; fake server on an ephemeral 127.0.0.1 port; never touches ~/.t3
```

### Fake-server demo (no T3 needed)

```sh
.build/debug/AgentHuddle --fixture
```

Starts an in-process fake T3 on `127.0.0.1` (random port) with running threads, a question, a permission and a command whose output advances. The panel appears top-right; the menu-bar item shows/hides it, opens Inline approvals and quits. Jump is a log stub, the token is a dummy, the Keychain is never read, and preferences go to a temp folder.

Other modes (**debug builds only**: a release build, including the downloaded app, refuses `--fixture`, `--mcp-url`, `--snapshot`, `--record`, `--prefs-dir`, `--runtime-file` and the other development switches, so nothing that launches the app can redirect its token or swap its credential stores):

```sh
.build/debug/fake-t3 [--port N]                       # standalone fake MCP server; prints its URL
HUDDLE_MCP_TOKEN=fake-token .build/debug/AgentHuddle --mcp-url http://127.0.0.1:PORT/mcp
.build/debug/AgentHuddle --snapshot DIR               # render every UI state to PNGs and exit
scripts/make-demo.sh                                  # regenerate demo/ (needs ffmpeg)
```

`--mcp-url` accepts loopback IP literals only. There is deliberately no `--token` flag: tokens never go on a command line.

## Automated live check (no clicking)

```sh
scripts/live-check.sh --huddle          # mints a 10-min pairing code, signs in via OAuth, runs the REAL HuddleModel read-only
                                        # against 127.0.0.1:3773, prints what the panel would show, then revokes the pairing
                                        # code and the OAuth session it created
scripts/live-check.sh --call t3_thread_list '{"allProjects":true,"statuses":["running"],"limit":3}'   # read-only tools only
```

It only calls read-only tools, never prints the pairing secret or the access token, and cleans up on exit.

**Try the sign-in flow without T3:** `.build/debug/AgentHuddle --fixture --no-token`.

The T3 Connect **relay** (`*.t3coderelay.com`) is out of scope: remote, non-loopback, refused by the app on purpose (see [`specs/00-prototype.md`](specs/00-prototype.md) §2).

**Not done for you, on purpose:** `t3 pair`, any login item, any T3 setting. The app registers its own OAuth client with T3 only when you click **Connect to T3 Code** (and you approve in T3), and reuses that registration afterwards. To start it at login, add the built binary in System Settings → General → Login Items yourself (spec Q13: off by default).

The app reads exactly one T3 file, `~/.t3/userdata/server-runtime.json` (host/port/pid): it must be a small regular file owned by you, it refuses any non-loopback host, and before sending the token it checks that the pid in the file **owns the listening socket on that port** (asked of the kernel, so the file cannot pair a real T3 pid with another process's port) and belongs to an app bundle with id `com.t3tools.t3code`. The check is repeated on every poll, so a cached connection is dropped if T3 restarts or another process takes the port. It does not check a code-signing identity. If it wrongly refuses, the panel says "Listener on the T3 port is not T3 Code".

## CI and releases

- **CI** (`.github/workflows/ci.yml`) runs on pushes to `main` and `build/**` and on pull requests: debug build, `swift test`, then the release build and `scripts/build-app.sh`. The zipped app is uploaded as a workflow artifact.
- **Release** (`.github/workflows/release.yml`) runs when you push a tag like `v0.2.0`: tests, release build with that version in the app's Info.plist, then a GitHub release with `AgentHuddle.zip` and its SHA-256.
- The app is ad-hoc signed and not notarized; see [Install](install.md) for the first launch.

## Layout

```
Sources/HuddleCore   models, tolerant JSON, reducer (Store.swift), discovery, MCP client, poller/model, security
Sources/FakeT3       loopback HTTP server + fake T3 tools + synthetic scenarios (tests and demos; the module is linked into the app binary, and only debug builds can start it)
Sources/AgentHuddle  SwiftUI views, NSPanel, menu-bar item, Inline approvals window, About, snapshot + demo recorder
Sources/fake-t3      standalone fake server
Sources/huddle-probe live-check tool (scripts/live-check.sh)
Tests/               224 tests, §11 layers
```
