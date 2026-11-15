# 07 — Inline approvals for threads on another machine (opt-in, per machine)

**Status:** built, **off by default, per machine** · **Evidence:** the building blocks ran live on T3 Code 0.1.9 against **this Mac's own https address** (origin policy, identity check, token exchange with `scope=`, one accept over `wss`, `peerLinks.list`) and the descriptor of one linked MacBook was verified. A decision to a genuinely separate machine over Tailscale, decline, the Inline approvals window, the Keychain store and the model's machine route were **never run against real T3**.

## Purpose and user value

- **One panel for a fleet:** **Allow** and **Deny** work for a thread that runs on a linked machine (for example a headless Mac mini over Tailscale).
- **The one place the app leaves the loopback:** this is the only exception to "loopback only" (spec 12). It is opt-in per machine and heavily guarded.

## Behaviour as built

### Where it is set up

*Since spec 14:* in the Settings window's **Machines** tab, each machine's line **Approve commands from the panel** (state chip On / Off / Needs re-pairing / Setting up) opens the setup below in place; **Turn off** works in place too, and "Find addresses…" sits at the bottom of the tab. The separate Inline approvals window is gone. The rows and steps below are the same, now inside each machine's row:

- **This Mac** row: spec 06.
- **Linked machines**: every linked machine, plus any machine that still has a saved login but is no longer linked (label "Unlinked machine (xxxxxxxx…)", so its login can still be removed).
- **Find addresses…** (shown when at least one machine is listed).
- With no linked machine: "No other machine is linked. Link one in T3 Code (Settings → Connections), then it shows up here.".

#### Per-machine states

| State | Chip | Row subtitle | Button |
|---|---|---|---|
| **On** | On (lime) | saved host · login saved | Turn off |
| **Off** | Off (grey) | "N address(es) found · not set up", or "address not found · type it when you set up" | Set up… |
| **Needs re-pair** | amber | "T3 refused the saved login. Pair again." | Set up… |

A machine is **On** while its credential exists in the vault. **Needs re-pair** is set when T3 rejected the saved login and clears on a successful setup. Needs re-pair is held in memory only: after a restart the machine shows Off.

### Setup, per machine (the row's **Set up…**)

1. **Address.** The step lists candidates: the saved address first, then every https address discovery found, without repeats. Each is checked against the linked machine when the row opens and shows:
   - "is this machine ✓" (answers with the linked machine's environment id),
   - "different machine",
   - "not reachable",
   - the policy's reason for an invalid address,
   - or "checking…".

   The user may select one, or type another (checked on Return). A typed address wins over the selection.
2. **Pairing code.** The window shows `t3 auth pairing create --scope orchestration:read --scope orchestration:operate --label "Agent Huddle approvals" --ttl 10m`, to be run **on that machine**. The user pastes the code.
3. **Warning** (same wording as spec 06), then **Turn on** (enabled when the code and an address are non-empty and nothing is in flight).
4. **Enrollment** (any failure stops with a reason and nothing saved):
   1. The machine must be linked to this Mac's T3 now.
   2. The address passes the origin policy.
   3. **Identity check first** (nothing secret is sent).
   4. Then the single-use code is exchanged at that origin's `/oauth/token` with the same form as spec 06.
   5. The result is saved in the Keychain vault (below).

The pairing code and the typed address are never logged.

### Find addresses… (optional discovery)

- **Why:** T3's MCP does not share linked machines' addresses. They are available only through the `/ws` RPC `peerLinks.list` on this Mac's T3, which needs the scope `access:read` besides `orchestration:read`.
- **Setup:** the user runs `t3 auth pairing create --scope orchestration:read --scope access:read --label "Agent Huddle discovery" --ttl 10m` **on this Mac**, pastes the code, clicks **Find addresses**.
- **What happens:** the app exchanges the code on loopback (scopes `orchestration:read access:read`, label "Agent Huddle discovery"), upgrades `ws://127.0.0.1:<port>/ws?orchestrationProtocol=2`, sends **one** frame `{"_tag":"Request","id":"1","tag":"peerLinks.list","headers":[],"payload":{}}`, reads `links:[{label, environmentId, urls, …}]`, and drops the session. Timeout 15 s.
- **Result:** each machine's `urls` are filtered by the origin policy (http and loopback names dropped); the first acceptable is the default and all acceptable ones are offered. Held in memory for this run only.
- **What it reveals:** names and addresses of linked machines and which sessions exist. It cannot send, launch or change anything and carries no credential. The session cannot be revoked by the app and lasts about 30 days: the window says to revoke "Agent Huddle discovery" with `t3 auth session revoke`.
- **Not a trust root:** an address from discovery is checked like a typed one.
- It is refused unless the granted scopes include `access:read` and are only the two requested.

### Credential storage

Each machine's credential is `{environmentId, origin, token}` inside the app's one Keychain item (service `app.t3huddle.AgentHuddle`, account `vault`, accessible when unlocked, this device only), keyed by environment id. The origin travels with the token in that record, so the token can never be paired with another host. Earlier versions kept one item per machine (`approvals-remote-<percent-encoded environment id>`); the first launch with the vault migrates and deletes them.

### Origin policy (`RemoteOriginPolicy.production`)

- https only for any non-loopback host. A bare host such as `mac-mini.tailnet.ts.net` gets `https://` prefixed; anything else must say https itself.
- Every spelling of a loopback or unspecified host is refused for a remote machine: `localhost`, `*.localhost`, `127/8`, `0/8`, `::1`, `::`, long and v4-mapped forms.
- No user name or password, no path (except `/`), no query, no fragment; port 1–65535.
- The result is normalised to `https://host[:port]`; the socket URL is `wss://host[:port]/ws?orchestrationProtocol=2`.
- The loopback-http variant (`loopbackFixture`, `package` access) exists for tests and snapshots only.
- The stored origin is **re-validated before every use**.

### Transport rules

- System certificate trust only. No challenge handler, no pinning, no skip; a private CA the system does not trust is refused by design.
- No proxy, no cookies, no URL credential storage, **no redirects** (descriptor, token exchange and `/ws` upgrade each refuse a 3xx).
- One short-lived `wss` connection per click.

### Identity check

- `GET <origin>/.well-known/t3/environment`, **no Authorization header**, 8 s timeout, response under 262,144 bytes.
- It must be a 2xx JSON with `environmentId` equal to the linked environment's id; else "… did not answer like T3 Code" or "… is a different machine from the one linked. Nothing was sent."
- The check runs **before the pairing code is sent** and **again before every decision**. Its result is a `VerifiedRemoteOrigin`, the only value `ApprovalSocket(remote:)` and the enrollment accept.
- The environment id is public. The proof is TLS with system trust for the name plus the id; it is not a signature.

### The decision

Same rules as spec 06 (explicit click, no default button, never in Read-only mode, only an approvable `waiting` request, re-read through the MCP with the thread's `environmentId` and the same command text, the one frame with accept or decline), with these differences:

- The route is `.machine(<environment id>)`: it needs that machine's credential.
- The stored origin is re-validated, then re-identified, then the bearer goes to that `wss` URL.
- **Rejection:** 401, 403 or a scope or credential failure deletes **only that machine's** credential, sets it to Needs re-pair, and toasts "<machine> rejected the approvals credential. Inline approvals for it are off; set them up again." This Mac's credential stays.
- The thread id the MCP reports for a linked machine's thread is assumed to be the id that machine's `/ws` accepts.

### What the panel shows

- **Machine set up:** Allow and Deny as in spec 06.
- **Thread on a machine with no credential, once any inline approval is on:** "Approving commands from the panel isn't set up for <machine name>. Settings → Machines, or decide in T3 Code.". Review in T3 Code works.
- **Everything off:** the panel is unchanged.
- **Remote-only setup:** this Mac's permission rows are unchanged (no hint, no buttons).

### Turn off

**Turn off** on a machine's row removes its credential from the vault. The window says to revoke the session on **that machine** (`t3 auth session list`, then `t3 auth session revoke <id>` for "Agent Huddle approvals").

## T3 data and tools

| What | Detail | Evidence |
|---|---|---|
| Linked machines | `t3_environment_links {}` → `links[{environmentId or id, label or name}]`; present only with Settings → Labs → Linked environments | tool Live (empty list); row shape fake only |
| Descriptor | `GET /.well-known/t3/environment` → `{environmentId, label, platform, serverVersion, orchestrationProtocolVersion, capabilities}`, unauthenticated | **Live** (this Mac over https, and the linked MacBook) |
| Addresses | `/ws` RPC `peerLinks.list` → `links[{label, environmentId, urls, status, access, linkedAt, expiresAt, lastReachedAt, lastError}]`, needs `access:read` | **Live** (returned the MacBook's https Tailscale url) |
| Scope `access:read` | gates exactly `peerLinks.list` and `subscribeAuthAccess`; metadata only | Bundle read (0.1.9); live for `peerLinks.list` |
| Token exchange and decision | as spec 06, on the machine's own T3 | Live on this Mac's https address (one accept, sequence 844956) |
| Remote thread read for the re-check | `t3_thread_read` with `environmentId` | Fake; the link relay Live for list/read |

## Security and privacy

Every item is an AGENTS.md hard rule and is enforced by a test:

- **Opt-in per machine.** Nothing is sent to a machine before its setup.
- **https/wss only**, system trust, no pinning, no redirects, no proxy, no cookies.
- **The host is never derived from agent text:** only from discovery or what the user typed, stored with the credential and re-validated.
- **Prove the machine first** (identity check before the code and before every decision).
- **Same decision rules** and the same one-command socket.
- **A rejected credential drops only that machine's.**
- **Discovery is separate and read-only:** `PeerLinkDiscovery.swift` has one RPC tag, one `.send(`, and names no command.
- **Tokens, pairing codes and addresses** stay out of argv, logs and the repository; `HuddleLog` scrubs them.
- **Source scans:** no `URLAuthenticationChallenge`, `SecTrust`, `NSAllowsArbitraryLoads` and friends anywhere under `Sources/`; the loopback fixture policy is not reachable from `main.swift`; proof types are minted only in `RemoteOrigin.swift`.

## Acceptance criteria

| ID | Statement | Tests (`RemoteApprovalTests` unless noted) | Evidence |
|---|---|---|---|
| RMT-01 | Production policy needs https for any remote host; refuses every loopback spelling; refuses user info, path, query, fragment | `productionPolicyRequiresHTTPSForAnyRemoteHost`; `productionPolicyNeverAcceptsALoopbackHostForAnotherMachine`; `policyRefusesUserinfoPathQueryAndFragment`; `everySpellingOfALoopbackOrUnspecifiedHostIsNotAnotherMachine` | Fake (pure) |
| RMT-02 | The fixture policy allows plain http only to a loopback literal; an origin normalises and derives `wss` only | `theFixturePolicyAllowsOnlyPlainHTTPToALoopbackLiteral`; `aValidatedOriginIsNormalizedAndDerivesWssOnly` | Fake (pure) |
| RMT-03 | Discovery picks the first address the policy accepts; all accepted ones are offered | `discoveryPicksTheFirstAddressThePolicyAccepts`; `discoveryReadsLinkedMachineAddressesWithAThrowawayReadOnlySession` | Fake; `peerLinks.list` Live |
| RMT-04 | The local path stays strictly loopback | `theLocalPathStaysStrictlyLoopback` | Fake |
| RMT-05 | The legacy per-machine account names (read only by the migration into the vault) are distinct per machine and from the other credentials, and round-trip environment ids | `keychainAccountsAreSeparatePerMachineAndFromTheOtherCredentials`; `theKeychainAccountPrefixRoundTripsEnvironmentIds` | Fake (account names only; no Keychain round trip) |
| RMT-06 | The descriptor is fetched with no credentials and must match the linked environment; a non-T3 answer is refused | `theDescriptorIsFetchedWithoutCredentialsAndMustMatchTheLinkedEnvironment`; `anAddressThatDoesNotAnswerLikeT3IsRefused` | Fake; descriptor Live |
| RMT-07 | A redirect on the descriptor, the token exchange and the `/ws` upgrade is not followed and the credential goes nowhere else | `aRedirectOnTheDescriptorIsNotFollowed`; `aRedirectOnTheTokenExchangeIsNotFollowedAndTheCodeGoesNowhereElse`; `aRedirectOnTheWebSocketUpgradeIsNotFollowedAndTheBearerGoesNowhereElse` | Fake |
| RMT-08 | Off by default: nothing is sent to another machine | `offByDefaultNothingIsSentToAnotherMachine` | Fake |
| RMT-09 | Setup checks the machine, then exchanges the code there with the least scope | `setupChecksTheMachineThenExchangesTheCodeThereWithTheLeastScope` | Fake; exchange Live on own https address |
| RMT-10 | An address that is another machine, plain http, or loopback is refused and no code is sent; only a linked machine can be set up; a code without operate is refused | `setupRefusesAnAddressThatIsAnotherMachineAndSendsNoCode`; `setupWithTheProductionPolicyRefusesPlainHTTPAndLoopbackBeforeAnyRequest`; `setupIsOnlyForAMachineThatIsLinked`; `aCodeWithoutOperateIsRefusedAndNothingIsSaved` | Fake |
| RMT-11 | Allow sends exactly one accept frame to the other machine only; Deny sends decline | `allowSendsExactlyOneRespondFrameToTheOtherMachineOnly`; `denySendsDecline` | Fake; accept over `wss` Live on own https address; decline None |
| RMT-12 | Read-only mode blocks a remote decision; a changed request is not sent | `readOnlyModeBlocksARemoteDecision`; `aRemoteRequestThatChangedSinceItWasShownIsNotSent` | Fake |
| RMT-13 | A machine that stops answering as the linked one is never sent the bearer | `aMachineThatStopsAnsweringAsTheLinkedOneIsNotSentTheBearer` | Fake |
| RMT-14 | A rejected credential drops only that machine's, and this Mac's credential stays | `aRejectedRemoteCredentialDropsOnlyThatMachine`; `thisMacsThreadsStillUseThisMacsCredentialWhenARemoteOneExists`; `turningOffForgetsOnlyThatMachinesCredential` | Fake |
| RMT-15 | A thread on a machine with no credential says so by name and sends nothing | `aThreadOnAMachineWithoutACredentialSaysSoAndSendsNothing` | Fake |
| RMT-16 | A stored origin that breaks the policy is never used; thread text cannot change where the bearer goes | `aStoredOriginThatBreaksThePolicyIsNeverUsed`; `textInsideAThreadCannotChangeWhereTheBearerGoes` | Fake |
| RMT-17 | While deciding remotely only the allowed MCP tools are called | `onlyTheAllowedMCPToolsAreCalledWhileDecidingRemotely` | Fake |
| RMT-18 | Discovery needs `access:read`, refuses anything broader, keeps nothing, and sends only `peerLinks.list` | `discoveryNeedsAccessReadAndRefusesAnythingBroader`; `discoveryHelperSendsOnlyPeerLinksList`; `discoveryFileIsReadOnlyAndNamesNoCommand` | Fake; Live for the call |
| RMT-19 | A remote-only setup leaves this Mac's permission rows unchanged | `aRemoteOnlySetupDoesNotChangeThisMacsPermissionRows` | Fake |
| RMT-20 | A credential for an unlinked machine stays listed and removable | `aCredentialForAnUnlinkedMachineCanStillBeRemoved`; `ApprovalsWindowStateTests.aMachineWithALoginButNoLinkStaysListedSoItCanBeRemoved` | Fake |
| RMT-21 | Window states go Off, On, Needs re-pair; addresses are offered saved-first without repeats; each is checked against the linked machine (this machine, other machine, unreachable, invalid) | `ApprovalsWindowStateTests.aMachineIsOffThenOnThenNeedsRepairAfterTheLoginIsRefused`; `ApprovalsWindowStateTests.addressCandidatesListTheSavedOneFirstThenTheDiscoveredOnesWithoutRepeats`; `ApprovalsWindowStateTests.eachAddressIsCheckedAgainstTheMachineYouLinked` | Fake |
| RMT-22 | Source scans: system certificate trust only; fixture policy not in production wiring; remote connections only through the verified origin types; remote files never name the decision command | `certificateValidationIsTheSystemDefaultEverywhere`; `theLoopbackFixturePolicyIsNotReachableFromTheProductionWiring`; `remoteConnectionsAreBuiltOnlyThroughTheVerifiedOriginTypes`; `remoteFilesNeverNameTheDecisionCommand` | Fake (static) |
| RMT-23 | A real decision to a separate machine over Tailscale, a live decline, and a revoked real credential | none | **None** |
| RMT-24 | The window's layout, the built `.app` against an https host | none | **None** |

## Open questions

- **RMT-Q2 (owner: maintainer, live pass):** one decision to a genuinely separate machine over Tailscale, accept and decline.
- **RMT-Q3:** the MCP's thread id for a linked machine's thread is assumed to be the id that machine's `/ws` accepts.
- **RMT-Q4:** a failing remote `t3_thread_read` or pending check is `try await` inside the poll, so it surfaces as the panel's connection error, not isolated to that machine. Untested.
- **RMT-Q5:** the shipped `.app` has no ATS keys or sandbox entitlement; default ATS accepts valid TLS 1.2+ https. Not run in the bundle.
- **RMT-Q6:** per README, links "expire after 30 days"; what does the panel show then? Not specified.

## Sources

`Sources/HuddleCore/{RemoteOrigin,RemoteApproval,PeerLinkDiscovery,HuddleModel+RemoteApprovals,HuddleModel+Approvals,ApprovalSocket,ApprovalEnrollment}.swift`, `Sources/AgentHuddle/{ApprovalsWindow,ApprovalSetup}.swift`, README "Optional: Allow / Deny for a thread on another machine", AGENTS.md "Hard rules".
