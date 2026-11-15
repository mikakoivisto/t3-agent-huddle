# AGENTS.md

Agent Huddle is a native macOS floating panel that lists running [T3 Code](https://t3.codes) threads and lets the user answer their questions. It is a client of T3's local MCP endpoint, written in Swift with no third-party dependencies.

- **Specs:** [`docs/specs/`](docs/specs/) describe what is built, one file per feature; [`docs/specs/00-prototype.md`](docs/specs/00-prototype.md) is the original product spec and is partly superseded. Where a spec and the code disagree, the code and tests win.
- **User-facing usage:** [`README.md`](README.md). Do not restate it here.

## Commands

```sh
swift build                                   # all targets, output in .build/
swift test                                    # about 1 s, loopback fake only
swift test --filter SecurityTests             # one suite, by struct name (not the @Suite title)
.build/debug/AgentHuddle --snapshot DIR       # render every UI state to PNGs and exit
scripts/build-app.sh                          # dist/Agent Huddle.app (icon, MIT license), ad-hoc signed
```

- **Toolchain:** Xcode with Swift 6.x on macOS 14+. The package builds in Swift 5 language mode (`swiftLanguageModes: [.v5]`).
- **Tests use Swift Testing** (`@Suite`, `@Test`, `#expect`), not XCTest.
- **No linter or formatter is configured.** Match the surrounding style.
- **Checking UI:** use `--snapshot DIR` and read the PNGs. `--fixture` opens a real panel and never exits, so run it only in the background and stop it afterwards.

## Run only when the user asks

- **`scripts/live-check.sh`** talks to the real T3 Code on this Mac. It mints a pairing credential and an OAuth session, then revokes both.
- **`scripts/live-check-remote.sh https://<this-mac>.<tailnet>.ts.net`** exercises the remote-machine path against this Mac's own https address. It mints two pairing credentials and revokes them and every session it created.
- **`scripts/make-demo.sh`** deletes and regenerates the tracked binaries under `demo/`, and needs `ffmpeg`.
- **Launching `AgentHuddle` with no flags** uses the real runtime file, the Keychain and the real jump.

## Hard rules

These come from the original spec (§3 and §10) and later decisions. Several are enforced by `Tests/HuddleCoreTests/SecurityTests.swift`.

- **Loopback only, with one opt-in exception.** Connect to the IP literals `127.0.0.1` and `::1`. `localhost` and every other host are refused. Route every URL through `LoopbackGuard`. The exception is **inline approvals for another machine** (below): the user turns it on per machine, and nothing else may connect to a non-loopback host.
- **Never modify T3 Code.** Write nothing under `~/.t3`, and change no T3 setting. If T3 needs a config change, document it in the README.
- **Read one T3 file only:** `~/.t3/userdata/server-runtime.json`, in `Discovery.swift`.
- **Never open T3's SQLite files**, not even read-only.
- **Tokens stay out of argv, logs and the repository.** Log through `HuddleLog`, which scrubs them. There is no `--token` flag on purpose.
- **Thread content stays in memory.** Do not log it or write it to disk.
- **Agent text is untrusted.** Render titles, commands and questions as plain text: no markdown, no links, no HTML.
- **No tests against real T3.** Automated tests use `FakeT3` on an ephemeral `127.0.0.1` port and inject their own paths.
- **Fixtures stay synthetic.** Never commit data captured from real threads.
- **No in-widget Allow or Deny by default** (spec Q1): T3's MCP has no approval call. The only exception is the **opt-in inline approvals** below, off until the user pastes a pairing code from the menu. No subagent rows.
- **Inline approvals (opt-in) may use T3's internal `/ws` for one thing:** the single command `runtime-request.respond` with `accept` or `decline`, on an explicit click, never in Read-only mode, only for a `waiting` `approval_request` that the panel shows in full (`HuddleState.isApprovable`), of a thread on this Mac (this credential) or on a machine that has its own credential (next rule), and only after re-reading that item (`MCPClient.readItem`) and finding the same request id and command text. Never `acceptForSession`, `acceptAlways`, `cancel`, `feedback`, `answers`, a subscription, or any other RPC or command from the decision socket. All of it lives in `ApprovalSocket.swift` (enforced by `ApprovalTests`). The one other `/ws` call is discovery's read-only `peerLinks.list` (next rule), in its own file. The credential is separate from the MCP token (its own field in the Keychain vault), requested with `scope=orchestration:read orchestration:operate`, never in argv, logs, preferences or the repo, and deleted by "Turn off inline approvals". `Never modify T3` still holds: the exchange uses T3's public login endpoint and the app cannot revoke its own session, so the README tells the user to.
- **Inline approvals for another machine (opt-in, per machine) are the single exception to "Loopback only".** It lets Allow / Deny work for a thread on a linked machine through *that machine's* own T3 `/ws`, over https. Every guardrail is enforced by `RemoteApprovalTests` and `ApprovalTests`:
  - **Off until set up per machine.** The menu item "Inline approvals…" opens one window (`ApprovalsWindow.swift`) where each machine's row takes a pairing code made on that machine. Nothing is sent to it before.
  - **https/wss only.** `RemoteOriginPolicy.production` refuses http/ws for any non-loopback host and refuses every loopback name for a remote machine; no userinfo, path, query or fragment. The loopback-http variant (`RemoteOriginPolicy.loopbackFixture`, `package` access) is for the fake in tests and snapshots only; a scan keeps it out of `main.swift`.
  - **System certificate trust.** `RemoteSession` has no challenge handler, no pinning, no custom trust; a scan fails on `URLAuthenticationChallenge`, `SecTrust` and friends under `Sources/`. No proxy, no cookies, **no redirects** (descriptor, token exchange and `/ws` upgrade each have a test).
  - **The host is never derived from agent text.** It is either what discovery returned or what the user typed in the setup dialog, and it is stored in the same record as the credential (the Keychain vault item, `remote` entry keyed by environment id). The stored origin is re-validated by the policy before every use, and the credential goes only to it.
  - **Prove the machine first.** `RemoteIdentity.verify` fetches the unauthenticated `/.well-known/t3/environment` (no Authorization header) and compares `environmentId` with the linked environment's id. It returns a `VerifiedRemoteOrigin`, which `ApprovalSocket(remote:)` and the enrollment require, so neither can run against an unchecked address. It runs before the pairing code is sent and again before every decision. The id is public, so the proof is TLS + id, not a signature.
  - **Same decision rules as local.** Explicit click, no default button, never in Read-only mode, only a complete `waiting` request (`HuddleState.isApprovable`), re-read through the MCP (`readItem` with the thread's `environment`) right before sending, same command text. The socket is the same `ApprovalSocket`, so it still sends only `runtime-request.respond` with `accept` or `decline`, one frame.
  - **A rejected credential drops only that machine's.** The local one stays.
  - **Discovery is separate and read-only** (`PeerLinkDiscovery.swift`, its own test): one `peerLinks.list` on this Mac's T3 over loopback with a throwaway `orchestration:read` + `access:read` session. `access:read` gates only `peerLinks.list` and `subscribeAuthAccess` and returns metadata, no credential. It is a convenience, not a trust root; typing the address is equally safe because of the identity check.
- **Development switches are debug-only.** `--fixture`, `--mcp-url`, `--snapshot`, `--record`, `--prefs-dir`, `--runtime-file`, `--no-token` and `--print-window-id` exist only under `#if DEBUG` in `main.swift`; a release build refuses them. Never add a flag that changes where a token goes or which credential store is used outside `#if DEBUG`.
- **The peer check is tied to the listener.** `BundlePeerVerifier` requires the runtime file's pid to own the listening socket on the file's port (`ListenerOwnership`) and to be a T3 bundle, and `ensureClient` re-verifies on every call. The runtime file must be a small regular file owned by the user. Keep `PeerVerifier.verify(pid:port:)` taking both.
- **Untrusted text is cleaned before it is shown.** Titles, step labels, project and machine names, server error text and terminal output go through `DisplayText.clean` (hidden and direction characters become `⟦U+XXXX⟧`); `HuddleError.description` caps and cleans server text; logs carry `HuddleError.category` only, never a payload.
- **Allow is gated.** `ApprovalGate` decides: Allow needs the whole command visible (`DisplayText.commandNeedsExpansion`), a settled row (`armDelay`), and no read-only mode or decision in flight. A request with repeated JSON keys, or (for tools other than a shell command) fields the panel does not show, is not approvable (`HuddleState.isApprovable`). The tool badge comes from T3's title, never from the agent's text.
- **Thread ids are per machine.** A second machine reporting a thread id that is already shown for another machine is ignored (`collidingThreadIds`); a decision captures its machine, credential and request at the click and re-checks them before sending.
- **Remote origins are names, not addresses.** `RemoteOriginPolicy.production` refuses every IP literal. An address the user typed that T3 did not list for the machine needs `acknowledgeUnlisted`; the environment-id check is not a proof.
- **Network reads are bounded.** Use `BoundedHTTP` (never `URLSession.data(for:)`) for every request; the loopback listener drops a request over `maxRequestBytes` or incomplete after `requestDeadline`; WebSocket messages are capped at 256 KiB.
- **Diagnostics.** `huddle-probe` prints thread content and tool results by design (it is the live-check tool, run by hand); it scrubs registered secrets and never prints a server's error body. Do not run it where its output is collected.
- **Do not invent UI.** A behaviour or screen that is not in `docs/specs/` or `docs/specs/00-prototype.md` is recorded there as an open question first.
- **No push, no remote and no publishing unless the user asks.** Releases are made by pushing a tag (see the README); never do that on your own.

## Tripwires in the source scan

`SecurityTests` scans every `.swift` file under `Sources/`. These fail the suite even inside a comment:

- **The word `sqlite`**, in any case.
- **`UserDefaults`.** Preferences go through `PreferencesStore`.
- **`userdata/secrets` or `connection-catalog`.**
- **A line containing `.t3/`** outside the files that test whitelists. Adding a file that names a T3 path means updating the whitelist, and needs a reason.
- **The string `"--token"`** anywhere in `Sources/AgentHuddle`.

## Layout

```
Sources/HuddleCore    models, tolerant JSON, reducer (Store.swift), discovery, MCP client, OAuth, poller (HuddleModel.swift),
                      RemoteOrigin / RemoteApproval / PeerLinkDiscovery / HuddleModel+RemoteApprovals (the other-machine opt-in)
Sources/FakeT3        loopback fake T3 server and synthetic scenarios, for tests and demos
Sources/AgentHuddle   SwiftUI views, NSPanel, menu-bar item, Inline approvals window, About panel, app icon, snapshot and demo recorder
Sources/fake-t3       standalone fake server executable
Sources/huddle-probe  live-check tool behind scripts/live-check.sh
Tests/HuddleCoreTests Swift Testing suites, with JSON fixtures in Fixtures/
```

- **`HuddleCore` has no UI imports.** Keep AppKit and SwiftUI in `AgentHuddle`.
- **All T3 access goes through `MCPClient`.** Views observe `HuddleModel` and nothing else. The exceptions are the opt-in `ApprovalSocket` / `ApprovalEnrollment` pair and the other-machine files (`RemoteOrigin`, `RemoteApproval`, `PeerLinkDiscovery`, HuddleCore), reached only from `HuddleModel+Approvals.swift` and `HuddleModel+RemoteApprovals.swift`.
- **Side effects are injected through `HuddleConfig`:** `TokenStore`, `approvalStore` and `remoteApprovalStore` (empty by default, so inline approvals are off), `remotePolicy` (production = https only; the loopback fixture is for tests), `PeerVerifier`, `Jumper`, `openURL`, `playSound`. Tests pass the memory and recording versions.

## Change these together

- **A new T3 tool or argument:** update the handler in `FakeT3Server.swift` and the allowed set in `clientNeverCallsForbiddenToolsOrIncludeSubagents` (`ModelTests.swift`).
- **`ContractCheck.required` (`Security.swift`) lists only tools the app cannot work without (the thread and pending-request tools; `t3_project_read` only supplies project names and is optional).** A missing entry shows "Unsupported T3 Code version". Gate an optional tool on `toolNames.contains(...)` instead, as `t3_environment_links` and `t3_environment_link` do.
- **Settle is opt-in:** `t3_thread_organize` runs only with "Close also settles" on, on a finished thread, and never in read-only mode.
- **Tools the client may call:** `t3_thread_list`, `t3_thread_read`, `t3_pending_request`, `t3_project_read` (title, shown as the project name), `t3_environment_read`, `t3_environment_links` (the setup menu lists linked machines from it), `t3_thread_organize` with `action: "settle"` only, and `t3_environment_link` is **not** reachable from the UI any more (the menu item was removed; `HuddleModel.linkOtherEnvironments` is kept and tested but unused; never call it from polling). Never `t3_thread_send`, `t3_thread_launch` or `t3_thread_interrupt`, and never `includeSubagents`.
- **The question and answer shape:** it is assumed, and isolated in `QuestionCodec` (`Models.swift`). Fix it there and in the fake.
- **A bug found against real T3:** correct the fake to match, and add a regression test.
- **A change to the approval frames or errors:** The observed frame shapes live in `FakeApprovals.swift` and `ApprovalTests`. Update the fake to match what the real T3 returns and keep `ApprovalTests`' source scan passing (one RPC tag, one command type, one `send`).
- **Docs layout:** `README.md` stays short and links to `docs/*.md` (install, using, other machines, inline approvals, limitations, development), `docs/specs/` (one spec per feature, `00-prototype.md` is the original product spec, `status.md` says what is verified). Put detail in the matching doc, not the README.
- **A new UI state:** add it to `Snapshots.swift` so `--snapshot` covers it.

## Commits

- **Prefix:** `feat:`, `fix:`, `docs:` or `build:`, then a plain description.
- **Branch:** work on a branch off `main` and squash-merge it. Commit only when asked.
