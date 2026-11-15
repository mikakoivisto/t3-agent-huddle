# 08 — Connecting to T3 Code

**Status:** built · **Evidence:** the OAuth flow, the contract check, discovery and read calls ran live on T3 Code 0.1.9 through `scripts/live-check.sh` (sign-in approved with a throwaway pairing code, not the browser page). The browser approval page, the Keychain store, the process-bundle peer check and the sign-in button were never run against real T3.

## Purpose and user value

- **Connect with one button:** the user clicks **Connect to T3 Code**, approves once, and the panel fills.
- **Safe by default:** the token never leaves the loopback and is never printed; the app refuses to talk to a process that is not T3 Code.
- **Fail visibly:** every broken state has a headline in the panel.

## Behaviour as built

### Finding T3

- **Runtime file:** `~/.t3/userdata/server-runtime.json` is the **only** T3 file the app reads. It provides `host`, `port`, `pid`.
- **Loopback only:** `host` must be `127.0.0.1` or `::1` (IP literals; `localhost`, `0.0.0.0`, LAN, DNS and CGNAT names are refused). The MCP URL becomes `http://<host>:<port>/mcp`. IPv6 is bracketed.
- **Missing or unreadable file:** "T3 Code not running", with no network call.
- **Invalid file** (not an object, missing host or port, port outside 1–65535): "Runtime file invalid: …".
- **Re-resolved** after any failure, so a port change is picked up on the next poll.

### Peer check (before the token is sent)

`BundlePeerVerifier`: the `pid` must be alive, its executable path must be inside an `.app` bundle, and that bundle's identifier must be `com.t3tools.t3code`. Otherwise the panel shows "Listener on the T3 port is not T3 Code" and **no request is sent**.

### Sign-in (OAuth 2.0 with PKCE)

1. **Resolve and verify** the endpoint (loopback guard, peer check).
2. **Discover** `GET /.well-known/oauth-authorization-server`. The authorization, token and registration endpoints must be on the MCP server's own host and port; a foreign host is refused.
3. **Listener:** a one-shot HTTP server on `127.0.0.1`, preferring the previously used port, else an ephemeral one. Redirect URI `http://127.0.0.1:<port>/callback`. It answers one request with a small "Agent Huddle is connected" page and is closed afterwards.
4. **Client:** reuse the client id saved in preferences when the redirect port is unchanged; otherwise dynamic registration at `/oauth/mcp/register` (`client_name` "Agent Huddle", grant `authorization_code`, response `code`, `token_endpoint_auth_method` `none`, scope `orchestration:read orchestration:operate`).
5. **Authorize:** open the authorization URL in the default browser with `response_type=code`, `client_id`, `redirect_uri`, `scope`, `state` (16 random bytes), `code_challenge` (S256 of a 48-byte random verifier), `code_challenge_method=S256`, `resource` (the MCP URL).
6. **Callback checks:** an `error` is shown; `state` must match; if `iss` is present it must equal the issuer; a `code` is required. Wait at most 180 s ("timed out waiting for approval"). **Cancel** ends the wait.
7. **Exchange:** `POST` the token endpoint with the code and verifier. The access token is registered with the log scrubber, saved to the Keychain, and the client id and port are saved to preferences.
8. The user approves in T3's page with a pairing code and chooses an access level. The install guide advises the level the user's threads run at, usually "auto" (spec 13: T3 refuses answers and messages to a thread in a broader mode than the sign-in); read-only cannot answer or send, and full access only if the threads run that way.

**No refresh grant** is advertised, so the user signs in again when the token expires (about 30 days).

### Token storage and lifetime

- **Keychain:** service `app.t3huddle.AgentHuddle`, account `vault` (the `bearer` field; formerly its own item `bearer`, migrated on first launch), accessible when unlocked, this device only. Never a file, log line, argv or `UserDefaults`; there is no `--token` flag.
- **Paste fallback:** "or paste a token" saves a pasted token to the Keychain. A token from `t3 auth session issue` is **rejected** by real T3 (401 on `/mcp`), so this is a fallback only.
- **On HTTP 401 or 403** from any call: the token is deleted, the state becomes "Connect to T3 Code", and a red note says T3 rejected the token (HTTP 401) and why a CLI token may not work.
- **Revoke:** `t3 auth session list` and `t3 auth session revoke <id>`.

### Sign out

- **Menu → Sign Out of T3 Code…** (shown only while a token is stored). A confirmation says what happens, then the token is deleted from the Keychain vault, the MCP client is dropped, the list is cleared and the panel shows **Connect to T3 Code** again, so a different access level can be chosen on the next sign-in (spec 13).
- **T3 keeps the session:** a client cannot revoke its own session, so the note under Connect says to run `t3 auth session list` and `t3 auth session revoke <id>` for Agent Huddle.
- **Untouched:** the inline-approvals logins (their own Turn off), preferences, the OAuth client id (reused next time), drafts in memory.
- **If the Keychain refuses** the delete, nothing else changes and the note says so.

### Connection states

| State | Headline | Trigger |
|---|---|---|
| Connecting | "Connecting…" | before the first answer |
| Connected | none; green dot | a poll succeeded; failures reset |
| Not running | "T3 Code not running" | missing runtime file, connection refused, timeout, DNS failure |
| Unauthorized | "Connect to T3 Code" and the button | no token, or 401 or 403 |
| Unsupported | "Unsupported T3 Code version: <reason>" | contract check failed |
| Error | the message | any other failure, including a refused peer |

A failed sign-in shows its reason in red under the button and never contains the token. After three consecutive failures the poll slows to 15 s (spec 02).

### MCP transport

- JSON-RPC over streamable HTTP: `initialize` (protocol `2025-03-26`, client "Agent Huddle"), notification `initialized`, then `tools/list` and `tools/call`.
- Replies are plain JSON or `text/event-stream` (the last JSON-RPC message wins); `structuredContent` is preferred, else the first text block parsed as JSON.
- 5 s timeout per request. A 404 on a live session resets the session.
- The session is ephemeral: no proxy, no cookies, no cache, **no redirects**.

### Contract check

On connect the app reads `tools/list`. It must contain these tools with these arguments (a tool with no advertised schema is allowed):

| Tool | Required arguments |
|---|---|
| `t3_thread_list` | `allProjects, statuses, limit, cursor, settled` |
| `t3_thread_read` | `threadId, view, afterPosition, limit, maxCharsPerItem, itemId, textOffset` |
| `t3_pending_request` | `action, threadId, requestId, answers` |
| `t3_project_read` | `projectId` |

Anything missing shows "Unsupported T3 Code version: missing tool <name>" or "<name> lost argument <arg>", and **no data call is made**. Optional tools (`t3_environment_links`, `t3_environment_link`) are gated on their presence instead (spec 09). `runLimit` and `environmentId` are sent but not checked.

### Read-only mode

A menu toggle (spec 10), persisted. It blocks **Send** (spec 04), inline Allow and Deny (specs 06, 07) and the settle on Close. It is enforced **in the app only**: the OAuth token is always requested with `orchestration:read orchestration:operate`, so it does not reduce the token's scopes.

### Launch modes (development)

`--fixture` (in-process fake T3, dummy token, no Keychain), `--mcp-url http://127.0.0.1:PORT/mcp` (token from `HUDDLE_MCP_TOKEN`), `--snapshot DIR`, `--record DIR`, `--prefs-dir DIR`, `--runtime-file FILE`, `--no-token`, `--sound`. A non-loopback `--mcp-url` exits with an error. Launching with no flags uses the runtime file, the Keychain and the real jump.

## T3 data and tools

| What | Detail | Evidence |
|---|---|---|
| `POST /mcp` without a credential | `401 {"error":"invalid_mcp_credential"}`, `WWW-Authenticate` with resource metadata, `access-control-allow-origin: *` | **Live** |
| Protected-resource metadata | scopes `orchestration:read`, `orchestration:operate`; bearer in the header | Live |
| Authorization server | PKCE `S256`, dynamic registration at `/oauth/mcp/register`, token endpoint auth `none`, only `authorization_code` | Live |
| CLI bearer on `/mcp` | `t3 auth session issue` bearer is rejected (401) | **Live** |
| OAuth token tools | the full tool set (68, or 71 with the Labs setting); contract check passes | **Live** |
| Approval decision on `/mcp` | `POST /oauth/mcp/decision` with `decision:{_tag:"pairing-code", access, code}`, used by the probe in place of the browser page | Live (probe only) |
| Browser approval page | the page the user sees | **None** |
| Refresh | not advertised | Live (metadata) |

## Security and privacy

- **Loopback only** for everything in this spec; route every URL through `LoopbackGuard`.
- **Token is the only gate** (`/mcp` allows any origin): Keychain only, scrubbed from logs, never in argv, minimum scopes.
- **Verify the peer first** (`BundlePeerVerifier`).
- **Footprint in T3:** one OAuth client registration on first Connect; everything else is reads. The app writes nothing under `~/.t3`.
- **Redirects are never followed**; OAuth endpoints on a foreign host are refused; the relay (`*.t3coderelay.com`) is refused as non-loopback.
- **`state` is checked before the code exchange.**

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| CON-01 | A loopback runtime file resolves to `http://127.0.0.1:<port>/mcp`; IPv6 loopback works; a port change is picked up | `DiscoveryTests.resolvesLoopbackRuntimeFile`; `ipv6LoopbackAccepted`; `portChangeIsPickedUpOnNextResolve` | Fake; live resolution via live-check |
| CON-02 | A missing file means "not running" with no network call; invalid files are rejected | `DiscoveryTests.missingFile`; `invalidFiles`; `HardeningTests.missingRuntimeFileMeansNotRunningWithoutNetwork` | Fake |
| CON-03 | Non-loopback hosts (0.0.0.0, LAN, DNS, CGNAT, `localhost`) are refused | `DiscoveryTests.nonLoopbackHostRefused`; `SecurityTests.loopbackGuardRules`; `MCPClientTests.clientRefusesNonLoopbackEndpoint` | Fake |
| CON-04 | A refused peer receives nothing; an accepted peer connects | `HardeningTests.peerRefusalSendsNothingToTheServer`; `OAuthTests.peerRefusalBlocksRegistration` | Fake (`BundlePeerVerifier` itself: **None**) |
| CON-05 | PKCE challenge matches the RFC 7636 vector | `OAuthTests.pkceChallengeMatchesRFC7636Vector` | Fake (pure) |
| CON-06 | The full flow registers, authorizes, exchanges and connects | `OAuthTests.fullFlowRegistersExchangesAndConnects` | Fake; flow Live via probe (browser page: None) |
| CON-07 | A static CLI-style token is rejected like real T3 | `OAuthTests.staticTokenIsRejectedLikeRealT3` | Fake; Live (rejection) |
| CON-08 | A second sign-in reuses the registered client while the port is free | `OAuthTests.secondSignInReusesTheRegisteredClientWhenPortIsFree` | Fake |
| CON-09 | A wrong `state` is rejected before the exchange; denial surfaces and stores nothing; timeout is reported | `OAuthTests.wrongStateIsRejected`; `userDenialSurfacesAndStoresNothing`; `timeoutWhenNobodyApproves` | Fake |
| CON-10 | An authorization server on another host, or a relay or remote endpoint, is refused before any request | `OAuthTests.authorizationServerOnAnotherHostIsRefused`; `relayOrRemoteEndpointsAreRefusedBeforeAnyRequest` | Fake |
| CON-11 | 401 drops the token and asks to connect, with a visible reason; pasting a good token reconnects | `ModelTests.unauthorizedDropsTokenAndAsksToConnect`; `MCPClientTests.unauthorizedWithWrongTokenMapsTo401Error` | Fake; 401 Live |
| CON-12 | With no token there is no request at all | `ModelTests.noTokenMeansConnectStateWithoutAnyRequest` | Fake |
| CON-13 | A stopped server shows "T3 Code not running" and the panel recovers when it returns | `ModelTests.serverGoneThenBackRecovers`; `MCPClientTests.unreachableServerMapsToNotRunning` | Fake |
| CON-14 | A missing tool or a lost argument shows "Unsupported T3 Code version" and makes no data call | `ModelTests.contractDriftShowsUnsupportedVersion`; `contractDriftDetectsLostArgument`; `MCPClientTests.handshakeListsToolsAndPassesContractCheck` | Fake; check passes Live |
| CON-15 | SSE and `structuredContent` replies both decode; tool errors surface | `MCPClientTests.sseAndStructuredContentFramingBothWork`; `sseReplyDecoderPicksJsonRpcEvent`; `toolErrorsSurfaceAsToolFailed` | Fake |
| CON-16 | A redirect is not followed and the token is not sent on | `SecurityTests.redirectsAreNotFollowed` | Fake |
| CON-17 | The token never appears in logs, including on 401 and errors; bearer patterns are scrubbed | `SecurityTests.tokenNeverAppearsInLogsEvenOn401AndErrors`; `logScrubberRedactsBearerPatterns` | Fake |
| CON-18 | The app accepts no token on the command line | `SecurityTests.appBinaryDoesNotAcceptATokenOnTheCommandLine` | Fake (static scan) |
| CON-19 | Read-only mode blocks Send, Allow and Deny | `ModelTests.readOnlyModeBlocksSend`; `ApprovalTests.readOnlyModeBlocksDecisions`; `RemoteApprovalTests.readOnlyModeBlocksARemoteDecision` | Fake |
| CON-20 | Keychain save, load and delete of the `bearer` field | `KeychainVaultTests` (memory); once by hand against the real Keychain | **Partial** |
| CON-21 | The sign-in button, the Cancel button and the browser approval page | none | **None** |
| CON-22 | The real peer check on a live T3 process | none | **None** (README: "unproven against your real install") |

## Open questions

- **CON-Q1:** SPEC §7.1 says Read-only mode "requests `orchestration:read` alone"; the code never narrows the token. Keep it app-side only, or request read-only scope when the toggle is on (needs a new sign-in)?
- **CON-Q2:** is the pid-to-bundle peer check right on a real install (T3 may listen from a helper process outside the `.app/` path)? If not, the panel wrongly says "Listener on the T3 port is not T3 Code".
- **CON-Q3:** the contract check requires `t3_project_read` although it only supplies a cosmetic project name (AGENTS.md says the list holds only tools the app cannot work without). Make it optional?
- **CON-Q4:** token lifetime is about 30 days with no refresh. Should the panel warn before expiry?
- **CON-Q5:** App Sandbox (SPEC Q16) is untried.

## Sources

`Sources/HuddleCore/{Discovery,OAuth,MCPClient,Security,HuddleModel}.swift`, `Sources/AgentHuddle/{T3Jumper,Views,main}.swift`, README "Connect to your real T3", `docs/specs/00-prototype.md` §5.2, §6.5, §7.1 (partly superseded).
