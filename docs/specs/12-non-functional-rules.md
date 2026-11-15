# 12 — Cross-cutting non-functional rules

**Status:** built · **Evidence:** the security rules are enforced by automated tests and source scans against the fake; performance is **designed, not measured**.

This spec owns the rules the other specs reuse. Feature specs link here instead of restating them.

## Purpose and user value

- **Trust:** a status widget that holds a bearer token to T3 must not leak it, widen its reach, or write into T3.
- **Quiet:** polling stays cheap and backs off when T3 is away.

## Rules as built

### Security hard rules (AGENTS.md, from SPEC §3 and §10)

| # | Rule | Enforced by |
|---|---|---|
| S1 | **Loopback only.** Connect to the IP literals `127.0.0.1` and `::1`; `localhost` and every other host are refused; every URL passes `LoopbackGuard`. The one exception is inline approvals for another machine (spec 07): per machine, https/wss, verified identity | `SecurityTests.loopbackGuardRules`; `DiscoveryTests.nonLoopbackHostRefused`; `ApprovalTests.theSocketRefusesNonLoopbackOrigins`; `RemoteApprovalTests` (policy and scans) | Spec 15 adds a second opt-in exception: another machine's MCP over https, per machine, same guardrails (`MachinesTests`).
| S2 | **Never modify T3 Code.** Nothing written under `~/.t3`; no T3 setting changed. T3-side footprint is limited to: one OAuth client registration, answering a question, a message the user writes and sends (spec 13), the optional settle, and the opt-in approval and discovery sessions | `SecurityTests.sourcesTouchHomeT3OnlyForTheRuntimeFileAndNeverOpenSQLite` (static); tool-set tests below |
| S3 | **Read one T3 file only:** `server-runtime.json`, in `Discovery.swift` | same scan |
| S4 | **Never open T3's SQLite files**, and the word `sqlite` may not appear in any source, even a comment | same scan |
| S5 | **Tokens stay out of argv, logs and the repository.** Logging goes through `HuddleLog`, which scrubs registered secrets and any bearer pattern; no `--token` flag | `SecurityTests.tokenNeverAppearsInLogsEvenOn401AndErrors`; `logScrubberRedactsBearerPatterns`; `appBinaryDoesNotAcceptATokenOnTheCommandLine`; `ApprovalTests.enrollmentRequestsLeastScopeAndKeepsOnlyThatSession`; `RemoteApprovalTests.discoveryReadsLinkedMachineAddressesWithAThrowawayReadOnlySession` |
| S6 | **Thread content stays in memory.** Not logged, not written | `StoreTests.preferencesRoundTripUnderInjectedDirectory` |
| S7 | **Agent text is untrusted.** Titles, commands, questions, options, branch and project names render as plain text: no markdown, no links, no HTML | Code convention (`Text(verbatim:)`); **no test** |
| S8 | **No tests against real T3.** Tests use `FakeT3` on an ephemeral `127.0.0.1` port and inject their own paths | `SecurityTests.fakeServerListensOnLoopbackOnly` |
| S9 | **Fixtures stay synthetic.** No data captured from real threads is committed | Code review only |
| S10 | **Tools the client may call:** `t3_thread_list`, `t3_thread_read`, `t3_pending_request`, `t3_project_read`, `t3_environment_read`, `t3_environment_links`, `t3_thread_organize` with `action:"settle"` only, and `t3_thread_send` with `mode:"queue"` or `mode:"steer"` only, from the Send button (spec 13). `t3_environment_link` exists in code but no UI or poll calls it. Never `t3_thread_send` with any other mode or with `freshContext`, never `t3_thread_launch`, `t3_thread_interrupt` or `t3_queue`, and never `includeSubagents` | `ModelTests.clientNeverCallsForbiddenToolsOrIncludeSubagents`; `ApprovalTests.theMCPClientStillNeverCallsForbiddenTools`; `RemoteApprovalTests.onlyTheAllowedMCPToolsAreCalledWhileDecidingRemotely` |
| S11 | **No in-widget Allow or Deny by default.** Only through the opt-ins (specs 06, 07); no subagent rows | `ApprovalTests.offByDefaultNoSocketNoExchangeNoButtons`; `RemoteApprovalTests.offByDefaultNothingIsSentToAnotherMachine`; `StoreTests.membershipExcludesIdleAndSubagents` |
| S12 | **Do not invent UI.** Anything not specified in these specs or `docs/specs/00-prototype.md` is an open question | Process rule |
| S13 | **No push, no remote, no publishing.** Work stays on a local branch | Process rule (see spec 11, PKG-Q1) |
| S14 | **Inline approvals send one command** (`runtime-request.respond`, accept or decline) and `/ws` is used for nothing else except the read-only `peerLinks.list` | `ApprovalTests.socketSourceMentionsOnlyTheOneCommand`; `RemoteApprovalTests.discoveryFileIsReadOnlyAndNamesNoCommand` |

### Source-scan tripwires

`SecurityTests` scans every `.swift` file under `Sources/`; these fail the suite even inside a comment:

- the word `sqlite`, in any case;
- `UserDefaults` (preferences go through `PreferencesStore`);
- `userdata/secrets` or `connection-catalog`;
- a line containing `.t3/` outside the whitelisted files (`Discovery.swift` for `userdata/server-runtime.json`; `T3Jumper.swift`, `main.swift`, `Scenario.swift`, `FakeT3Server.swift`, comments only);
- the string `"--token"` in `Sources/AgentHuddle`.

`ApprovalTests` and `RemoteApprovalTests` add scans for the approval and certificate-trust rules (spec 06, 07).

### Persisted data

| Where | What | Never |
|---|---|---|
| `~/Library/Application Support/AgentHuddle/preferences.json` | closed thread ids, panel origin and max height, collapsed, muted, read-only, close-settles, OAuth client id and redirect port (public, non-secret) | titles, commands, output, tokens |
| Keychain `app.t3huddle.AgentHuddle` / `vault` | one JSON item: the MCP access token, the opt-in approvals session (spec 06) and per-machine `{environmentId, origin, token}` (spec 07). Earlier versions used separate `bearer`, `approvals-bearer` and `approvals-remote-<id>` items; they are migrated and deleted on first launch | |
| Memory only | threads, steps, output tails (20,000 characters), questions, discovered addresses, toasts | disk |

### Performance and polling

| Item | Value | Evidence |
|---|---|---|
| List poll | 2 s expanded, 5 s collapsed | `StoreTests.pollScheduleAndBackoff` |
| Open thread | read and output refresh every 1 s | `ModelTests.detailViewShowsLiveTerminalOutput` |
| Back-off | 5 s after the first failure, 15 s from the third; first success resets | `HardeningTests.retryNeverFasterThanBackoffEvenWithDetailOpen` |
| Per-request timeout | 5 s (MCP), 10 s (OAuth, exchange), 8 s (identity check), 15 s (`/ws`) | Code |
| List paging | up to 5 pages of 100 for active threads; finished refresh one page of 25 | `LiveShapeTests.numericNextCursorIsKeptAndSentBackAsANumber`; `HardeningTests.finishedRefreshIsOnePageWithNoCursorChasing` |
| Re-read rule | only changed threads | `StoreTests.needsReadOnlyWhenChanged` |
| Pending-request calls | only for `waiting` threads or those with `pendingRequestCount > 0` | `ModelTests.questionAndPermissionDetected` (indirect) |
| Output | incremental by `textOffset`; tail of 20,000 characters; full fetch capped at 200,000 | `HardeningTests.longOutputKeepsTheTailAndFetchesOnlyNewText` |
| Memory | 200 steps per thread; step detail 1,500 characters | Code |
| Budget | SPEC §7.3: about three requests per second with four running threads | **Not measured** |

### Quality gates

- **Tests:** Swift Testing (`@Suite`, `@Test`, `#expect`). 291 tests in 35 suites. Run one suite by struct name (`swift test --filter SecurityTests`).
- **No linter or formatter** is configured; match the surrounding style.
- **UI checks:** `AgentHuddle --snapshot DIR` renders every UI state to PNGs; add each new state to `Snapshots.swift`. No automated test clicks the panel.
- **Change together:** a new T3 tool or argument updates the fake handler and the allowed set in `ModelTests.clientNeverCallsForbiddenToolsOrIncludeSubagents`; `ContractCheck.required` lists only tools the app cannot work without; a bug found against real T3 gets the fake corrected and a regression test; the test count in README and `docs/specs/status.md` is updated; approval frame changes update `FakeApprovals.swift`.

### Live checks (run only when the user asks)

`scripts/live-check.sh`, `scripts/live-check-remote.sh <https address>` and `scripts/make-demo.sh` act on the real T3 or regenerate tracked binaries. Launching the app with no flags uses the real runtime file, the Keychain and the real jump.

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| NFR-01 | Only loopback hosts are accepted by the discovery, MCP client, OAuth client and local socket | `SecurityTests.loopbackGuardRules`; `DiscoveryTests.nonLoopbackHostRefused`; `MCPClientTests.clientRefusesNonLoopbackEndpoint`; `OAuthTests.relayOrRemoteEndpointsAreRefusedBeforeAnyRequest`; `ApprovalTests.theSocketRefusesNonLoopbackOrigins` | Fake |
| NFR-02 | A redirect never carries a token to another host | `SecurityTests.redirectsAreNotFollowed`; `RemoteApprovalTests` redirect tests | Fake |
| NFR-03 | No source mentions SQLite, `UserDefaults`, T3 secret paths; `~/.t3` only where whitelisted; no `--token` | `SecurityTests.sourcesTouchHomeT3OnlyForTheRuntimeFileAndNeverOpenSQLite`; `appBinaryDoesNotAcceptATokenOnTheCommandLine` | Fake (static) |
| NFR-04 | No token, pairing code or session token reaches a log line | `SecurityTests.tokenNeverAppearsInLogsEvenOn401AndErrors`; `logScrubberRedactsBearerPatterns`; `ApprovalTests.enrollmentRequestsLeastScopeAndKeepsOnlyThatSession` | Fake |
| NFR-05 | Only the allowed MCP tools are called, never with `includeSubagents`, and no subagent thread is read | `ModelTests.clientNeverCallsForbiddenToolsOrIncludeSubagents`; `ModelTests.fourRowsCountAndNoiseExcluded` | Fake |
| NFR-06 | Preferences contain no thread content | `StoreTests.preferencesRoundTripUnderInjectedDirectory` | Fake |
| NFR-07 | The fake listens on `127.0.0.1` only | `SecurityTests.fakeServerListensOnLoopbackOnly` | Fake (uses `lsof`) |
| NFR-08 | Agent text is rendered as plain text everywhere | none | **None** (convention; no scan for `Text("…")` with agent strings) |
| NFR-09 | Polling honours its schedule and back-off | `StoreTests.pollScheduleAndBackoff`; `HardeningTests.retryNeverFasterThanBackoffEvenWithDetailOpen` | Fake |
| NFR-10 | Request volume stays near the budget with four running threads | none | **None** |
| NFR-11 | The whole suite passes in a few seconds without T3 | `swift test` | Run for this review: 190 passed in 1.05 s |

## Open questions

- **NFR-Q1:** S7 (plain text only) has no automated guard. Add a source scan that agent fields use `Text(verbatim:)`?
- **NFR-Q2:** SPEC §7.3's request budget was never measured.
- **NFR-Q3:** `SecurityTests` whitelists `T3Jumper.swift` for `.t3/` lines, but that file no longer names `.t3/` (the jump uses the deep link). Tighten the whitelist.
- **NFR-Q4:** `outputCaches` (spec 03) and closed ids (spec 01) are never pruned.
- **NFR-Q5:** App Sandbox is untried (SPEC Q16).

## Sources

AGENTS.md, `Tests/HuddleCoreTests/SecurityTests.swift`, `Sources/HuddleCore/{Security,Discovery,Store}.swift`, `docs/specs/00-prototype.md` §3, §7.3, §10, §11, README "Limitations".

## Added after the security reviews

- **Development switches are debug-only.** `--fixture`, `--mcp-url`, `--snapshot`, `--record`, `--prefs-dir`, `--runtime-file`, `--no-token` and `--print-window-id` are refused by a release build. Evidence: run against the release binary (refusal message), no automated test.
- **The peer check is tied to the listener.** The runtime file's pid must own the listening socket on the file's port and be a T3 bundle; the file must be a small regular file owned by the user; the check is repeated on every poll. Tests: `ListenerOwnershipTests` (real kernel query against this test process); checked once against the real T3. Not checked: a code-signing identity.
- **Every network read is bounded** (`BoundedHTTP`; loopback listener request cap and deadline; WebSocket 256 KiB). Tests: `BoundedHTTPTests`, including a response of unknown length.
- **Untrusted text is cleaned** (`DisplayText`) and logs carry error categories only. Tests: `DisplayTextTests`, `InvisibleTextTests`, `CredentialLifecycleTests`.
- **Thread ids are per machine**: a duplicate id from a second machine is ignored; a decision re-checks its machine and request before sending. Tests: `ApprovalTextTests`, `RequestUnchangedTests`.
- **Remote machines are names, not IP addresses**, and an address T3 did not list needs the user's confirmation. Tests: `RemoteApprovalTests` (origin policy), `ApprovalsWindowStateTests`.
