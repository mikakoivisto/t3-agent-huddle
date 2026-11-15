# 06 — Inline approvals for threads on this Mac (opt-in)

**Status:** built, **off by default** · **Evidence:** the wire protocol was verified live on T3 Code 0.1.9 (Node spike: accept and decline on real threads; Swift client: one accept, through the https path of `scripts/live-check-remote.sh`). The loopback `ws://` route in the app (`HuddleModel` → `ApprovalSocket(origin:)`), decline from Swift, the setup window and the Keychain store ran only against the fake or not at all.

## Purpose and user value

- **Decide in the panel:** **Allow** or **Deny** a pending tool request under the exact command, instead of switching to T3 Code.
- **Contained:** the feature is off until the user pastes a pairing code, and it can send exactly one kind of command.

## Why it is a separate opt-in

T3's MCP surface cannot decide an approval (`t3_pending_request` handles user questions only; MCP-client tokens are refused on `/ws`). The decision command exists only on T3's internal `/ws` RPC, which accepts a separately paired, non-MCP session. That session's `orchestration:operate` scope also covers sending to, launching and interrupting threads; no approvals-only scope exists.

## Behaviour as built

### Setup (Settings → Machines, this Mac's row, **Approve commands from the panel** → **Turn on…**, in place)

1. The window shows the command to run in a terminal on this Mac, with a **Copy** button:

   `t3 auth pairing create --scope orchestration:read --scope orchestration:operate --label "Agent Huddle approvals" --ttl 10m`

2. The user pastes the printed code (a bare credential or a `…/pair#token=<credential>` link) into a secure field and clicks **Turn on**.
3. The app sends `POST /oauth/token` on this Mac's T3 (loopback, form encoded):

   | Field | Value |
   |---|---|
   | `grant_type` | `urn:ietf:params:oauth:grant-type:token-exchange` |
   | `subject_token` | the pairing code |
   | `subject_token_type` | `urn:t3:params:oauth:token-type:environment-bootstrap` |
   | `requested_token_type` | `urn:ietf:params:oauth:token-type:access_token` |
   | `scope` | `orchestration:read orchestration:operate` (always sent: a bare pairing code carries 16 scopes) |
   | `client_label` | `Agent Huddle approvals` |

4. The response is accepted only if the granted scopes include `orchestration:operate` and contain nothing beyond the two requested. Otherwise nothing is saved and the user sees why (for example the HTTP status and T3's code, or "granted more than requested … revoke the session").
5. The session token is stored in the Keychain vault (service `app.t3huddle.AgentHuddle`, account `vault`, `approvals` field; formerly its own item `approvals-bearer`, migrated on first launch), accessible when unlocked, this device only. The pairing code is single use and is not stored.
6. The window shows a warning: the login could also send messages to, launch and interrupt threads; the app only uses it to answer approvals.

**State:** inline approvals are **on** exactly while that credential exists (read at launch and after changes).

### What the panel shows

- **Permission panel, thread on this Mac, approvals on:** **Allow** (white) and **Deny** (red) under the command, above **Review in T3 Code**. Neither is a default button.
- **Disabled and dimmed** in Read-only mode (with the note "Read-only mode — decide in T3 Code") and while a decision is in flight ("Sending…").
- **Not approvable request:** the note "This request can't be approved here — decide in T3 Code". Review in T3 Code still works.
- **Error:** T3's sentence or ours under the buttons (first 160 characters).
- **Off:** the panel looks exactly as without the feature.

### Which requests are approvable

A request is approvable only when the panel shows all of it: `HuddleState.isApprovable`.

- the `approval_request` item's status is `waiting` (not `pending` or `completed`);
- the item text is not truncated;
- the text is non-empty and either **plain text of 400 characters or fewer**, or a JSON object whose **only material key is the one shown** (one of `command`, `path`, `file_path`, `url`; `description` and `timeout` are informational). A Write with `path` plus `content`, or a command plus a second path, is **not** approvable;
- the item id is `turn-item:runtime-request:<encodeURIComponent(requestId)>`, and the request id is the tail **decoded exactly once**.

A pending request whose item has not yet been seen `waiting` is re-read every poll, because T3 can flip an item's status without changing the thread's `updatedAt` or `itemCount`. A new run forgets the old run's request.

### The decision (one explicit click)

All guards run in order; any failure stops and sends nothing:

1. Some approvals feature is on, and no decision for this thread is in flight.
2. Not in Read-only mode.
3. The thread is on this Mac and this Mac's credential exists.
4. **Re-read that very item** (`t3_thread_read` with `itemId`, `textOffset:0`, `maxCharsPerItem:4000`, not just the newest positions): it must exist, still be approvable, have the same request id, and produce the **same summary text** the user saw. Else: "The request changed. Check it in T3 Code."
5. Open `ws://127.0.0.1:<port>/ws?orchestrationProtocol=2` with `Authorization: Bearer <token>`, only after the origin passes the loopback guard.
6. Send **one** text frame and wait for the matching `Exit`:

   ```json
   {"_tag":"Request","id":"1","tag":"orchestration.dispatchCommand","headers":[],
    "payload":{"type":"runtime-request.respond","commandId":"<lowercase uuid>",
               "threadId":"<thread id>","requestId":"<runtime request id>","decision":"accept"|"decline"}}
   ```

7. Close the socket. One connection per click; no subscription, no reconnect. Timeout 15 s.

**Never sent:** `acceptForSession`, `acceptAlways`, `cancel`, `feedback`, `answers`, any other command or RPC.

**Outcomes**

| Outcome | App behaviour |
|---|---|
| `Exit` Success | clear the prompt, suppress re-detection 4 s, refresh |
| `Exit` Failure | show T3's sentence with the long request id replaced by "this request" (for example "… is resolved.", "… was not found.") |
| HTTP 401 or 403 on upgrade, or a failure naming a missing scope, "not authenticated" or "invalid credential" | credential rejected: delete it, switch the feature off, toast "T3 Code rejected the approvals credential. Inline approvals are off; set them up again."; the panel falls back to Review in T3 Code |
| HTTP 426 | "This T3 Code version speaks a different approval protocol. Use "In T3 Code"." |
| Timeout or no connection | "T3 Code did not answer in time…" or "Couldn't reach T3 Code to send the decision." |

### Turning off

**Turn off** on the "This Mac" row removes the credential from the vault at once. T3 does not let a client revoke its own session, so the window says to run `t3 auth session list` then `t3 auth session revoke <id>` for the session labelled "Agent Huddle approvals", or remove it in T3 Code Settings → Connections. The token stays valid in T3 for about 30 days (`expires_in` 2591999) until then.

## T3 data and tools

| What | Detail | Evidence |
|---|---|---|
| Token exchange | `POST /oauth/token` as above → `{access_token, token_type:"Bearer", expires_in, scope}` | **Live** (Node, and Swift on the https path) |
| Session scopes | granted = requested ∩ the code's scopes | Live (bundle read); the Swift down-scoping live too |
| Upgrade | `GET /ws?orchestrationProtocol=2` with bearer. No `orchestrationProtocol=2` → 426; a bad bearer → 401 | Live (unauthenticated `curl`) |
| Command | `orchestration.dispatchCommand` `runtime-request.respond`, `decision` accept / decline | **Live** (accept and decline, Node; accept, Swift) |
| Replies | `Exit` Success `{sequence}`; Failure "Runtime request <id> is resolved." / "… was not found." | Live |
| Request id | from the item id, decoded once; it contains `%`-escapes and colons | Live |
| `orchestration:operate` alone | probably enough; not tried | None |
| Other providers | only `pi` run | None |
| Revoked or expired real token | not tried; a made-up bearer gives 401 | None |

## Security and privacy

- **Credential:** its own field in the Keychain vault, never in argv, logs, preferences or the repository; `HuddleLog` scrubs it.
- **Broader than the MCP token:** stated in the README and in the setup window; the app requests only `orchestration:read` and `orchestration:operate` even if the code carries more.
- **One command only:** enforced by a source scan on `ApprovalSocket.swift` (one RPC tag, one command type, one frame builder, one `.send(`; the words `acceptForSession`, `acceptAlways`, `"cancel"`, `feedback`, `answers`, `subscribe` are absent) and by a test of every frame the client can build.
- **Loopback guard:** the socket is built through `LoopbackGuard`; a non-loopback origin is refused. Remote machines use a different, verified path (spec 07).
- **Explicit click, no default, never in Read-only mode.**
- **No blind approvals:** the panel shows the whole request or offers no Allow.
- **Internal protocol:** `/ws` is T3's private first-party protocol (orchestration protocol 2); a T3 update can break it without notice.
- **`Never modify T3 Code` holds:** the exchange uses T3's public login endpoint; the app writes nothing under `~/.t3`.

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| AMC-01 | With no credential, no socket is opened, no exchange is sent, no buttons show, and a decision attempt does nothing | `ApprovalTests.offByDefaultNoSocketNoExchangeNoButtons` | Fake |
| AMC-02 | The feature is on only while the credential exists, and turning it off deletes it | `ApprovalTests.onlyWhileTheCredentialExists` | Fake |
| AMC-03 | Setup requests exactly `orchestration:read orchestration:operate`, sends the label and grant type, and keeps only that session; nothing sensitive reaches the log | `ApprovalTests.enrollmentRequestsLeastScopeAndKeepsOnlyThatSession` | Fake |
| AMC-04 | A pairing code is single use; a wrong one is refused with T3's reason | `ApprovalTests.aPairingCodeIsSingleUseAndAWrongOneIsRefused`; `ApprovalTests.aRefusedPairingCodeSaysWhy` | Fake |
| AMC-05 | A code without `orchestration:operate` is refused and nothing is saved | `ApprovalTests.aCodeWithoutOperateScopeIsRefusedAndNothingIsSaved` | Fake |
| AMC-06 | A pasted pairing link yields the bare credential; the shown command carries the right scopes and label and no `access:write` | `ApprovalTests.pastedPairingLinkYieldsTheBareCredential` | Fake |
| AMC-07 | Allow sends exactly one `runtime-request.respond` accept frame with exactly these payload keys, T3 moves on, the prompt clears | `ApprovalTests.allowSendsExactlyOneRespondFrameAndT3MovesOn` | Fake; frame shape Live |
| AMC-08 | Deny sends decline | `ApprovalTests.denySendsDecline` | Fake; decline Live (Node) |
| AMC-09 | Read-only mode sends nothing and shows an error | `ApprovalTests.readOnlyModeBlocksDecisions` | Fake |
| AMC-10 | A request whose command changed since it was shown is not sent, even when the approval is far behind the newest positions | `ApprovalTests.aRequestThatChangedSinceItWasShownIsNotSent`; `ApprovalTests.theCheckBeforeSendingReadsTheItemEvenFarBehindTheNewestPositions` | Fake |
| AMC-11 | T3's failure sentences ("is resolved", "was not found") replace the long request id | `ApprovalTests.aRequestAlreadyDecidedInT3ShowsT3sSentenceNotTheLongId` | Fake (sentences Live) |
| AMC-12 | A revoked credential switches the feature off, deletes it, toasts, and the prompt remains with Review in T3 Code | `ApprovalTests.aRevokedCredentialTurnsTheFeatureOffAndFallsBack` | Fake |
| AMC-13 | Only this Mac's threads use this credential | `ApprovalTests.onlyThisMacsThreadsAreOffered` | Fake |
| AMC-14 | Only a complete `waiting` request offers a request id; only a fully shown request is approvable (JSON keys, 400-character cap, empty, plain text) | `ApprovalTests.onlyAWaitingCompleteApprovalOffersARequestId`; `ApprovalTests.onlyAFullyShownRequestIsApprovable` | Fake |
| AMC-15 | A request id is decoded exactly once; item id and request id are inverses | `ApprovalTests.requestIdIsDecodedExactlyOnce`; `ApprovalTests.itemIdAndRequestIdAreInverse` | Fake (encoding Live) |
| AMC-16 | A new run forgets the old run's request | `ApprovalTests.aNewRunForgetsTheOldRunsRequest` | Fake |
| AMC-17 | A pending approval is re-read each poll until T3 marks it waiting, then Allow appears | `LateApprovalTests.aPendingApprovalIsRereadUntilItIsWaiting` | Fake |
| AMC-18 | Every frame the client can build is the one command with accept or decline; the socket source names nothing else; no other file opens a WebSocket except the read-only discovery file (spec 07) | `ApprovalTests.everyFrameTheClientCanBuildIsRuntimeRequestRespondWithAcceptOrDecline`; `ApprovalTests.socketSourceMentionsOnlyTheOneCommand` | Fake |
| AMC-19 | The socket refuses non-loopback origins; the protocol version is part of the upgrade URL | `ApprovalTests.theSocketRefusesNonLoopbackOrigins`; `ApprovalTests.protocolVersionIsPartOfTheUpgradeURL` | Fake |
| AMC-20 | The MCP client's tool set is unchanged while deciding; the fake exposes no approval tool | `ApprovalTests.theMCPClientStillNeverCallsForbiddenTools`; `ApprovalTests.theFakeKeepsTheMCPSurfaceUnchanged` | Fake |
| AMC-21 | A real accept and decline through the app's loopback `ws://` route | none | **None** (Node spike and the https `ApprovalSocket(remote:)` path ran live; the loopback `ApprovalSocket(origin:)` path never did) |
| AMC-22 | The vault round trip against the real Keychain (checked once by hand), and the setup and turn-off windows | `KeychainVaultTests` (memory) | **Partial** (tests use memory; windows never opened) |

## Open questions

- **AMC-Q1 (owner: maintainer):** run the in-app accept and decline live on a throwaway thread. The Swift loopback route and decline from Swift are unverified.
- **AMC-Q2:** is `orchestration:operate` alone enough (it would drop `orchestration:read`)? Not tried.
- **AMC-Q3:** other providers (Claude, Codex, ACP) were not run. The approval item is assumed identical.
- **AMC-Q4:** an MCP approve option in T3 ("If we want this") would make this credential unnecessary. Retire the feature if T3 ships it?
- **AMC-Q5:** the app cannot revoke its own session; the user must. Is a reminder with the session's expiry date needed?

## Sources

`Sources/HuddleCore/{ApprovalSocket,ApprovalEnrollment,HuddleModel+Approvals,HuddleModel+RemoteApprovals,Store}.swift`, `Sources/AgentHuddle/{ApprovalSetup,ApprovalsWindow}.swift`, README "Optional: Allow / Deny in the panel", AGENTS.md "Hard rules".
