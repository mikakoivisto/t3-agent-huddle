# 09 — Showing threads from other machines (T3 peer links)

**Status:** built for display; linking itself is **done outside the app** with the T3 CLI · **Evidence:** a second Mac linked over a Tailscale https address on T3 Code 0.1.9 appeared as `reachable`, and the panel showed that machine's recently finished thread under its own group (live check, README). The row shape of `t3_environment_links` with entries, the Labs-on error path and a working linked thread's question or permission were not captured.

## Purpose and user value

- **One panel, several machines:** threads running on a linked machine (for example a headless Mac mini) show under that machine's header next to this Mac's.
- **No extra network surface:** the app talks only to `127.0.0.1`. This Mac's T3 relays each call to the linked machine. (The one exception is the opt-in inline approvals, spec 07.)

## Behaviour as built

### What the app does

- **Environment list:** `t3_environment_read {}` gives this Mac (`environmentId`, `label`); `t3_environment_links {}` gives linked machines. Refreshed on every poll while the list is empty, then every 30 s (every 3 s for 3 minutes after a link request). The list is replaced only when the new list is non-empty.
- **Per-machine calls:** the same list, read, pending-request and project calls are repeated for each linked machine with `environmentId`. Calls for this Mac send no `environmentId`.
- **Isolation of list failures:** a linked machine whose active list fails (offline, `capability_denied`) is skipped without an error banner. A failed finished list for any machine makes the finished page non-exhaustive, so nothing is dropped.
- **Grouping:** by machine with headers whenever more than one machine has rows (spec 01).
- **Gating:** if `tools/list` has no `t3_environment_links` (Settings → Labs → "Linked environments" off, or no such T3 version), the app shows this Mac only and no error. With the setting off, any `environmentId` returns `capability_denied`.
- **Rows of linked machines** use the markdown-link and deep-link rules of spec 05.

### What the app does not do

- **No link action in the UI.** The menu item that called `t3_environment_link` was removed. `HuddleModel.linkOtherEnvironments` (which asks T3 to show its approval card with `requestedAccess:"approval-required"`) is kept and tested but never called by the UI or by polling.
- **Never** calls `t3_environment_unlink`, `t3_environment_preferences_update` or any link-mutating tool.

### Setup the user does (documented in README)

1. **On this Mac:** turn on Settings → Labs → Linked environments.
2. **Both machines need a secure address:** T3 refuses to link over plain `http://` (`PeerLinkError … is plain http`). Tailscale is the documented route:
   1. Install Tailscale on both Macs (`brew install --cask tailscale` or the download page) and sign in with the same account.
   2. On the other machine: `tailscale serve --bg 3773` gives `https://<machine-name>.<tailnet>.ts.net` with a real certificate; T3 stays on loopback there. If asked, enable HTTPS certificates once in the Tailscale admin console under DNS.
   3. From this Mac: `ping <machine-name>.<tailnet>.ts.net`.
3. **Link:** on the other machine create a pairing code (`t3 pair`, or `~/.t3/bin/t3 auth pairing create --label "link" --ttl 10m`); on this Mac run `~/.t3/bin/t3 environment link https://<machine-name>.<tailnet>.ts.net --pairing-code <code> --access approval-required` (use `approval-required`, not `full-access`).
4. **Check:** `~/.t3/bin/t3 environment list` shows the machine `reachable`.
5. **Remove:** `~/.t3/bin/t3 environment unlink <environment id>` (forgets it here; also revoke the session on that machine). The link expires after 30 days; link again then.

The Tailscale relay and T3 Connect (`*.t3coderelay.com`) are out of scope and refused as non-loopback.

## T3 data and tools

| What | Detail | Evidence |
|---|---|---|
| `t3_environment_read {}` | `{environmentId, label, serverVersion}` | **Live** |
| `t3_environment_links {}` | `{links:[…], environmentId, notListed:"…"}`; app accepts rows with `environmentId` or `id` and `label`, `name` or `displayName`; skips `isLocal` or `local` rows | Live with `links: []`; non-empty rows: fake only |
| Labs setting | adds 3 tools (71 total); without it every `environmentId` is `capability_denied` | Live |
| `environmentId` on every tool | routes the call to the linked machine through T3's peer link | Live (list and read on a linked machine, README) |
| Linked machine's `link` | markdown `[Title](t3-thread://v2/<env>/<id>)` | Live |
| `t3_environment_link` | `{reason, requestedAccess, hint?, environmentId?, url?}` returns `pending`; the user approves in a T3 card; the outcome goes to the calling thread, so an external client polls `t3_environment_links` | Described live; the card never triggered |
| Per-client link list | M0 L8: links are per MCP client; README later shows CLI-made links visible to the app | See open question |

## Security and privacy

- **Loopback only.** The relay hop is T3's, not the app's.
- **Least access:** documentation and the fake use `approval-required`; never `full-access`.
- **No machine address or credential is stored** by this feature (unlike spec 07).
- **Agent text is untrusted:** machine labels render as plain text.

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| LNK-01 | With the Labs setting off, the panel shows this Mac only, with no error banner and no `environmentId` sent | `LiveShapeTests.linkedEnvironmentsOffMeansLocalOnlyAndNoErrorBanner`; `LinkingTests.withoutTheLabsSettingThereIsNoLinkToolAndAHintIsShown` | Fake; the denial Live |
| LNK-02 | With links on, rows group under machine labels, this Mac first; remote calls carry `environmentId` and local calls do not; a remote question is answered on its machine | `LiveShapeTests.threadsGroupedByEnvironmentWhenLinkedEnvironmentsAreOn` | Fake; grouping of a finished remote thread Live |
| LNK-03 | A live-shaped link list (`links:[…]`) is read | `LinkingTests.preLinkedMachineListedByLiveShape` | Fake |
| LNK-04 | Nothing linked yet shows this Mac only and the app never links on its own | `LinkingTests.nothingLinkedYetShowsThisMacOnlyAndNeverLinksOnItsOwn` | Fake; empty list Live |
| LNK-05 | The kept link action asks T3 with `approval-required`, polls until the machine appears, and keeps local-only while the approval is pending | `LinkingTests.userActionAsksT3ForTheLinkCardThenTheMachineAppears`; `pendingApprovalKeepsLocalOnly` | Fake (UI entry removed) |
| LNK-06 | A linked machine's markdown link becomes a clean bare link, environment id and deep link | `DeepLinkTests.threadSummaryStoresABareLinkAndEnvironmentFromAMarkdownLink`; `remoteSessionJumpsToACleanDeepLink`; `fromAMarkdownLinkAsLinkedMachinesReturnThem` | Fake; shape Live |
| LNK-07 | A real link to a separate machine shows its running and question rows | none | **None** (only a recently finished thread seen) |
| LNK-08 | The setup steps (Labs, Tailscale, `t3 environment link`) work as written | none (README records one live run on 2026-11-14) | Live (once) |

## Open questions

- **LNK-Q1:** does `t3 environment link` (CLI) populate the same per-client list the MCP shows? README says the linked machine's thread appeared; M0 L8 said links are per MCP client. Reconcile.
- **LNK-Q2:** a failing remote `t3_thread_read` or pending check is `try await` inside the poll, so it surfaces as the panel's connection error, not isolated to that machine (see spec 07, RMT-Q4). Isolate it?
- **LNK-Q3:** what does the user see when a link expires after 30 days? Nothing is specified.
- **LNK-Q4:** `HuddleModel.linkOtherEnvironments` and `MCPClient.projectPath` are unused code. Delete, or keep for a future UI?
- **LNK-Q5:** a machine whose id is unknown to the link list still gets a group, labelled with its raw id.

## Sources

`Sources/HuddleCore/{MCPClient,HuddleModel,Store}.swift`, README "Show threads from other machines", AGENTS.md "Tools the client may call".
