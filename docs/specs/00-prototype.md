# T3 Agent Huddle — Product Spec

> **Original product spec**, written before the build. Parts are superseded by what was built: the [other specs in this folder](README.md) describe each feature as built, [`status.md`](status.md) says what is verified, and the maintainer's live checks covers approvals (Q1). Where this spec and the code disagree, the code and the live findings win.

| | |
|---|---|
| **Status** | Original draft. Implemented as a prototype; see the note above for what differs. |
| **Date** | 2026-11-14 |
| **Owner** | The maintainer |
| **Target** | T3 Code (Beta) 0.1.9 on this Mac mini (Apple M4 Pro, macOS 27.0.1) |
| **Inspiration** | A similar tool for Claude Code in VS Code. Not part of this repository. |

## 1. Summary

**Build a small native macOS companion app** that floats in the top-right corner and shows every running T3 Code thread. It talks to the local T3 server over its loopback MCP endpoint and never touches T3's install or database.

**One planned feature cannot be built on T3's public surface today: clicking Allow/Deny on a permission prompt.**

- T3's MCP tool for pending requests says outright that it does not list approvals and cannot approve them (§5.4).
- The CLI has no approval command either.
- v1 therefore **shows** that a thread needs permission and **jumps** to T3 Code to approve. In-widget Allow/Deny exists only as an opt-in through T3's internal `/ws` (§12, Q1); there is still no supported MCP surface for it.

**The rest splits into verified and not-yet-verified:**

- **Verified here**: listing threads across all projects, the step timeline of completed steps, and the output of completed commands.
- **Rides on the Milestone 0 spike**: whether an external app gets the same MCP tools as an in-thread agent (if not, this design falls — Q4), the shape of questions and answers (Q5), live output of a command still running (Q15), and a thread-level jump (Q9).

### Evidence labels used in this document

Every claim about T3 Code carries one of these, so a reader can tell fact from guess.

| Label | Meaning |
|---|---|
| **[V]** | Verified on this Mac through the public CLI, the MCP tools, or an unauthenticated loopback request. |
| **[B]** | Seen only as strings inside the 0.1.9 app bundle. Not a contract; may change in any release. |
| **[U]** | Unverified. Must be settled in Milestone 0 before code depends on it. |

## 2. Goals and non-goals

### Goals

- **Glanceable**: see every active T3 thread, its title, and a one-line status without bringing T3 Code to the front.
- **Inspectable**: click a thread to see its steps in order and the latest command output.
- **Answerable**: answer an agent's multiple-choice question from the widget.
- **Visible permission requests**: see that a thread is blocked on a permission, and what it wants to run, then get to the approval in one click.
- **Jump**: one click from a row to that thread in T3 Code.
- **Close**: cross a finished session off the list; the header count drops.
- **Safe by construction**: loopback only, least-privilege token, zero writes to T3's files.

### Non-goals

- **Not a T3 Code replacement.** No composer, no diff view, no starting threads, no model switching.
- **No changes to T3 Code**: not its app bundle, its install, its settings files, or its SQLite databases.
- **No remote access by default.** No LAN, Tailscale, relay, or T3 Connect paths: this Mac only. The one exception, added later, is the opt-in inline approvals for another machine (Q1, §10).
- **No Windows or Linux.** macOS first; nothing here assumes another platform.
- **No distribution.** No signing for release, no notarisation, no publishing, no GitHub remote.
- **No Claude Code / VS Code support.** The original concept targets those; this one targets T3 threads only.
- **No subagent rows.** Child threads are not shown (reading them has a side effect, §5.3).

## 3. Constraints

These bind the spec and the later prototype.

- **Do not modify T3 Code.** Not the app, the install, `~/.t3/bin/t3`, or anything under `~/.t3/userdata` (`state.sqlite`, `statev2.sqlite`, `settings.json`, `secrets/`, and the rest).
- **Never open T3's SQLite files — not even read-only.** A second reader on a live WAL database is a risk the project does not need.
- **The only footprint in T3 goes through its own API**: answering a question, the optional settle on Close, and one OAuth client registration. T3 records those itself; the huddle never writes a T3 file directly.
- **If T3 needs a config change, document it in the README; do not apply it.** The only exception is a trivially reversible, project-local file inside this repository.
- **No pushing, no publishing, no GitHub remote required.**
- **Prototype work happens on a branch, in a later thread.** This thread delivers `docs/specs/00-prototype.md` only.
- **macOS first.** Do not assume Windows.
- **Do not invent UI.** Anything not stated in this spec is listed under Open questions (§12) rather than specified.

## 4. User stories

The maintainer, on a Mac mini, with several T3 threads running at once.

| # | Story |
|---|---|
| U1 | With T3 Code minimised, I glance at the top-right corner and see how many threads are running and what each is doing. |
| U2 | I click a thread and see what it has done, what it is doing now, and the live output of its current command. |
| U3 | A thread needs permission. I see which one and the exact command, and I get to the approval in one click. |
| U4 | A thread asks me a multiple-choice question. I pick an option and send it without leaving what I am doing. |
| U5 | I click the arrow on a row and T3 Code comes forward on that thread. |
| U6 | A thread is done. I cross it off and the count drops. |
| U7 | I collapse the widget to its header when I need the screen space, and expand it again later. |
| U8 | I trust it: it cannot be reached from the network and it cannot corrupt my T3 state. | — |

## 5. What was found on this machine

All checks were read-only. Nothing was registered, paired, installed, or written.

### 5.1 Runtime and install [V]

- **CLI**: `~/.t3/bin/t3`, version `0.1.9`. It is a shell shim that runs the desktop app's bundled server script with `ELECTRON_RUN_AS_NODE=1`. Every CLI call starts an Electron process.
- **App**: `/Applications/T3 Code (Beta).app`, bundle id `com.t3tools.t3code`, version `0.1.9`.
- **Server**: `~/.t3/userdata/server-runtime.json` reports `host 127.0.0.1`, `port 3773`, `origin http://127.0.0.1:3773`, `serverVersion 0.1.9`, plus `pid` and `ownerId`.
- **Listener**: `lsof` shows the app listening on `127.0.0.1:3773` only (IPv4 loopback).
- **Remote access**: `t3 status --json` reports `lan.enabled: false` and no background service installed. `connect.enabled` is `true` (T3 Connect relay) — unrelated to this tool, which never uses it.

### 5.2 Authentication [V]

- `POST /mcp` without a credential returns `401` with `{"error":"invalid_mcp_credential"}` and a `WWW-Authenticate: Bearer resource_metadata=…` header.
- `/.well-known/oauth-protected-resource/mcp` advertises two scopes: `orchestration:read` and `orchestration:operate`, bearer token in the header.
- `/.well-known/oauth-authorization-server` advertises a standard public-client flow:
  - authorization code grant with PKCE `S256`,
  - dynamic client registration at `/oauth/mcp/register`,
  - token endpoint auth method `none`.
- **`/mcp` responds with `access-control-allow-origin: *`.** The bearer token is the only gate, so token handling is the whole security story (§9).
- The CLI needs no token on this machine; it authenticates through the local data directory. `t3 pair` and `t3 auth session` exist for minting scoped bearer sessions.

### 5.3 Thread data [V]

| Need | Surface | Notes |
|---|---|---|
| All active threads, every project | MCP `t3_thread_list` with `allProjects: true`, `statuses: [...]` | Returns `threadId`, `projectId`, `title`, `link`, `status`, `model`, `settled`, `snoozed`, `parentThreadId`, `itemCount`, `updatedAt`. Paged with `cursor`, `limit` ≤ 100. |
| Same, CLI | `t3 thread list --project <id-or-path> --json` | **Per project only.** No all-projects flag and no `project list` command. |
| One thread's state | MCP `t3_thread_read` / `t3 thread show <id> --messages N --json` | Adds `activeRunId`, `runCount`, `pendingRequestCount`, `archived`, `branch`, `worktreePath`. |
| Step-by-step timeline | MCP `t3_thread_read` with `view: "activity"` | Items carry `position`, `itemId`, `type`, `status`, `title`, `text`, `updatedAt`. Page with `afterPosition`; cap size with `limit` and `maxCharsPerItem`. **The CLI has no activity view.** |
| Command output | Same, `type: "command_execution"` | `text` is `$ <command>` followed by its output. Long text continues with `itemId` + `textOffset`. |

- **Statuses** (from the tool schema): `idle`, `preparing`, `queued`, `starting`, `running`, `waiting`, `completed`, `interrupted`, `failed`, `cancelled`, `rolled_back`.
- **Item types seen**: `command_execution`, `dynamic_tool` (titled e.g. `Read <path>`), `reasoning`, `assistant_message`. Only `status: "completed"` was observed; in-progress and failed values are **[U]**.
- **Backlog is large**: this machine has 935 `idle` threads and 551 in finished states, many already settled. The huddle must never list "everything not running".
- **`idle` is not "just finished"**: the sampled idle thread had no run at all, and a finished thread reports `completed`. Exact `idle` semantics are **[U]**.
- **Subagents come back even without `includeSubagents`**: an `allProjects` listing returned a thread with `relationshipToParent: "subagent"`. Filter on `parentThreadId` client-side.
- **List rows do not carry `pendingRequestCount`** — only a thread read does.
- **Side effect**: the read tool states that "reading a child's final result marks it delivered." The huddle must never read subagent threads.
- **Two link formats** come back for the same thread: the CLI gives `https://app.t3.codes/threads/<environmentId>/<threadId>`; MCP gives `t3-thread://v2/<environmentId>/<threadId>`.

### 5.4 Questions and permissions

- **The task brief assumed three tools** (`t3_pending_request_list`, `_read`, `_respond`). **This build has one**: `t3_pending_request` with `action: list | read | respond`. [V]
- **Its own description rules approvals out** [V]: *"Pending user questions in a thread… list: their ids; approvals are not listed… respond: answer one with `answers`; this cannot approve a permission request."*
- **Questions are answerable**: `respond` takes a `requestId` and an `answers` object. The exact shape of `answers` and of a question read is **[U]** — no question was pending during the investigation, so none could be read.
- **Approvals exist only internally** [B]: the bundle contains a `runtime-request.respond` command with `threadId`, `requestId`, `decision`, optional `feedback`, sent by the first-party client over a `/ws` WebSocket. There is no CLI command for it.
- **Do not answer with `t3 thread send` / `t3_thread_send`.** That queues a new turn; it does not resolve a pending request.

### 5.5 Other controls [V]

- **Organise**: `t3_thread_organize` with `pin`, `snooze`, `settle`, `unsettle`, `archive`, `unarchive`, `mark_unread`.
- **Interrupt**: `t3_thread_interrupt`. The huddle does not use it in v1.
- **Open a project**: `t3 app [<path>]` — "Open a project in the running T3 Code desktop app." It takes a project directory, not a thread.
- **There is no `t3_app` MCP tool in this build** [B], although the task brief mentioned one. Focusing a project is CLI-only.
- **URL schemes registered by the app**: `t3code` and `t3code-dev`. Only `t3code://pair` and `t3code://app` appear in the bundle [B]. `t3-thread://` is **not** a registered scheme.

### 5.6 Caveat on how this was measured

- The MCP calls above ran **from inside a T3 agent thread**, using that thread's own credential.
- Whether an **external** OAuth client gets the same tools, with the same behaviour, is **[U]**. Tool descriptions such as "omit `threadId` for this thread" show the tools are written for agents.
- Milestone 0 exists to settle this before any UI is built.

## 6. Architecture

### 6.1 Decision

**A standalone native macOS app, `Agent Huddle.app`, written in Swift/SwiftUI, acting as an MCP client of the local T3 server.**

```
┌────────────────────────────┐        loopback HTTP, Bearer token        ┌──────────────────────┐
│ Agent Huddle.app (Swift)   │ ───────────────────────────────────────▶ │ T3 Code (Beta)       │
│  floating NSPanel, corner  │   POST http://127.0.0.1:3773/mcp          │ server on 127.0.0.1  │
│                            │ ◀─────────────────────────────────────── │ :3773                │
│  Discovery → Auth → MCP    │                                           └──────────────────────┘
│  client → Store → Views    │   reads (never writes):
│                            │   ~/.t3/userdata/server-runtime.json
│  own state: Keychain +     │
│  ~/Library/Application     │   jump: activates com.t3tools.t3code
│  Support/AgentHuddle/      │
└────────────────────────────┘
```

### 6.2 Why this shape

- **It needs to float above everything, in a corner, without stealing focus.** That is an `NSPanel` (floating, non-activating, joins all Spaces). Only a real app can do it.
- **MCP is the only public surface with what the widget needs**: all-projects listing, the activity timeline, and pending questions. The CLI lacks all three.
- **A separate process cannot damage T3.** It holds a scoped token and makes HTTP calls; it has no access path to T3's files beyond one read of a JSON file.
- **The toolchain is already here.** Xcode and Swift 6.4 are installed, so nothing new needs installing. A native app also idles at a few megabytes, which matters for something that runs all day.

### 6.3 Alternatives rejected

| Option | Why not |
|---|---|
| **In-process T3 plugin or extension** | No plugin surface was found, and it would mean modifying T3 Code — ruled out by the constraints. |
| **CLI wrapper** (poll `t3 thread list/show`) | Per-project only, no activity view, no pending requests, no respond. Each call starts Electron. Kept only as a degraded fallback (§6.5). |
| **Skill or MCP server** | Those are surfaces an agent calls. They have no window and cannot sit on the desktop. |
| **Electron or Tauri app** | Works, but needs toolchains that would have to be installed, and costs far more memory for a four-row panel. |
| **Menubar-only popover** | The concept is a persistent floating panel; a popover closes when focus moves. A menubar item may be added as an extra (§12, Q11). |
| **Internal WebSocket client** (`/ws`) | Would unlock Allow/Deny and push updates, but it is an undocumented protocol that can break on any T3 update. Not the design for reading or polling. Used only for the opt-in inline approvals, one command (Q1). |

### 6.4 Components

- **Discovery** — reads `server-runtime.json`; refuses any origin whose host is not loopback; re-reads when the file changes or the server stops answering.
- **Auth** — obtains and stores the bearer token (§7.1).
- **MCP client** — minimal JSON-RPC over HTTP: `initialize`, `tools/list`, `tools/call`. No other MCP features needed.
- **Poller** — decides what to fetch and when (§7.3).
- **Store** — the single in-memory model (§8); pure reducer from fetched JSON to view state, so it is testable without a server.
- **Views** — list, detail, collapsed header.
- **Jump** — brings T3 Code forward on a thread (§7.5).

### 6.5 Degraded modes

- **T3 not running** (no runtime file, or connection refused): header shows a grey dot and "T3 Code not running". No retries faster than every 5 s.
- **Not authorised** (no token, or `401`): header shows "Connect to T3 Code" with one button that starts the auth flow.
- **Read-only fallback**: if MCP auth cannot be obtained at all, the app may list threads for configured project paths via `t3 thread list --project <path> --json`. No steps, no questions. This is a fallback, not a target.

## 7. Integration with T3 Code

### 7.1 Auth and token

**Preferred: the MCP OAuth flow the server advertises.** [U until M0]

1. Register a public client at `/oauth/mcp/register` (name "Agent Huddle").
2. Open `/oauth/mcp/authorize` with PKCE `S256`, requested scopes, and a loopback redirect on an ephemeral port bound to `127.0.0.1`.
3. The user approves in T3 Code or the browser.
4. Exchange the code at `/oauth/mcp/token`.

**Fallback: a scoped bearer session from the CLI.** [U until M0]

```sh
t3 pair --scope orchestration:read --scope orchestration:operate --label "Agent Huddle" --ttl 5m
```

- The user runs this once and pastes the result into the app. Whether a pair-derived session is accepted on `/mcp` is unverified.

**Rules either way**

- **Scopes**: `orchestration:read` and `orchestration:operate` only. Never the wider `t3 pair` defaults (terminal, filesystem, settings, access, relay).
- **Read-only mode**: a setting inside the app that blocks answering questions, settling and approving. As built, the token is still the read plus operate one (the access level is chosen at sign-in); read-only is not a separate scope request.
- **Storage**: macOS Keychain only. Never a file, never a log line, never `UserDefaults`.
- **Revocation**: the CLI help says linked environments appear under Settings → Connections. Whether an OAuth MCP client is listed and revocable there is **[U]** (M0). On `401`, the app drops its token and asks to reconnect.

### 7.2 Calls the app makes

| Purpose | Tool and arguments | Scope |
|---|---|---|
| List active threads | `t3_thread_list` `{allProjects: true, statuses: [preparing, queued, starting, running, waiting], limit: 100}` | read |
| Refresh finished threads already in the huddle | `t3_thread_list` `{allProjects: true, statuses: [completed, failed, interrupted, cancelled], settled: false, limit: 25}`, matched against known ids | read |
| Thread state + steps | `t3_thread_read` `{threadId, view: "activity", afterPosition, limit: 50, runLimit: 1, maxCharsPerItem: 400}` | read |
| Rest of a long command output | `t3_thread_read` `{threadId, view: "activity", itemId, textOffset}` | read |
| Find pending questions | `t3_pending_request` `{action: "list", threadId}` | read |
| Read one question | `t3_pending_request` `{action: "read", threadId, requestId}` | read |
| Answer a question | `t3_pending_request` `{action: "respond", threadId, requestId, answers}` | operate |
| Close as "settle" (optional) | `t3_thread_organize` `{action: "settle", threadId}` | operate |
| Project path for jump | `t3_project_read` `{projectId}` | read |

- **The Scope column is an assumption [U].** The server advertises the two scopes but not which tool needs which.
- **Always pass `threadId` explicitly.** Several tools default to "this thread", which means nothing for an external client.
- **Never pass `includeSubagents`, and drop any row whose `parentThreadId` is set.** Never read such a thread.
- **Reads must be side-effect free.** The bundle has a `thread.visit` command and an unread state [B]. M0 must confirm that polling does not mark threads as read in T3 Code.
- **Never call** `t3_thread_send`, `t3_thread_launch`, `t3_thread_interrupt`, or any project-mutating tool in v1.

### 7.3 Polling

No push channel was found on the public surface, so v1 polls.

- **List**: every 2 s while the panel is expanded, every 5 s while collapsed.
- **Read only what changed**: re-read a thread when its `status`, `updatedAt`, or `itemCount` differs from the last poll. Page forward from the last seen `position`.
- **Detail view open**: that one thread is read every 1 s, and the newest `command_execution` item is re-read for fresh output.
- **Pending questions**: call `t3_pending_request list` only for threads whose read shows `pendingRequestCount > 0` or whose status is `waiting`.
- **Back off** to 15 s after three consecutive failures; return to normal on the first success.
- **Budget**: with four running threads, at most about three requests per second, all on loopback.

### 7.4 What must stay loopback-only

- **Everything, with one opt-in exception.** The app connects to `127.0.0.1` (or `::1`) only, on the port from the runtime file. The exception is inline approvals for another machine (Q1): per machine, https/wss only, system trust, no redirects, an address from discovery or typed by the user and stored with the credential, and the machine must prove it is the linked one first.
- **The app opens no listening socket**, except the short-lived OAuth redirect listener, bound to `127.0.0.1` on an ephemeral port and closed after one request.
- **The app never asks T3 to bind wider.** It never runs `t3 up`, `t3 serve --host`, `--lan`, `--tailscale-serve`, or `t3 connect`.

### 7.5 Jump to thread

- **As built**: T3 Code's own thread deep link `t3code://threads/<environmentId>/<threadId>` (found in the desktop bundle's link parser). A linked machine returns its thread link as markdown, which the app strips to the bare URL. The landing on the right thread has not been observed.
- **Superseded draft options**: activating the app by bundle id, or `t3 app <projectPath>` (which opens a new thread in the project, so it is not used).
- **If delivery fails**: the panel shows a brief hint with the thread title so it can be picked in T3 Code.

## 8. Data model

All of this lives in the huddle's memory. Only the small local-preferences record is persisted, in the huddle's own folder.

### Session — one T3 thread

| Field | Source |
|---|---|
| `threadId`, `projectId`, `title`, `link` | thread list |
| `t3Status` | thread list `status` |
| `attention` | derived: `none`, `needsPermission`, `asksQuestion`, `failed`, `done` |
| `statusLine` | derived, see below |
| `progress` | derived, see below; may be absent |
| `buddyColor` | derived: stable hash of `threadId` into a fixed palette (blue, pink, orange, purple, teal, yellow) |
| `pendingRequestCount`, `activeRunId` | thread read |
| `lastPosition` | highest activity `position` seen |
| `updatedAt` | thread list |
| `hidden` | local preference (Close) |

### Step — one activity item of the active run

| Field | Source |
|---|---|
| `itemId`, `position` | activity item |
| `kind` | from `type`: `command_execution` → terminal, `dynamic_tool` → tool (pencil for writes/edits), `assistant_message` → message |
| `label` | `title` if present, else the first line of `text` |
| `state` | from `status`: done, running, pending, failed |
| `output` | `text` for `command_execution`, paged on demand |

- **`reasoning` items are not shown as steps.** They are noise at a glance and may be long.

### Question

| Field | Source |
|---|---|
| `requestId`, `threadId` | `t3_pending_request` list |
| `tag`, `prompt`, `options[]`, `multiSelect` | `t3_pending_request` read — exact field names **[U]** |
| `selection` | local, until sent |
| `state` | `pending`, `sending`, `answered`, `error` |

### PermissionPrompt

| Field | Source |
|---|---|
| `threadId` | thread |
| `summary` | the tool and command awaiting approval, e.g. `Bash: <command>` — source **[U]** |
| `state` | `pending`, `resolvedElsewhere`; plus `allowed` / `denied` only if Q1 is solved |

### Derived fields

- **Membership**: a thread is in the huddle when it is active (`preparing`, `queued`, `starting`, `running`, `waiting`), or when the huddle saw it active during this app session and it has since finished without being settled, archived, snoozed, or hidden. As built, rows on the list are kept across restarts until closed or settled (spec 02), and a thread is also in when it finished within the last 30 minutes (even if never seen running), while one of its subagents is still working, or while it waits on a background task. Threads with a `parentThreadId` are excluded. `idle` threads are never listed.
- **Header count** = number of sessions in the huddle.
- **`statusLine`**, first match wins:
  1. `needs permission`
  2. `asks a question`
  3. the label of the step currently running
  4. the T3 status in words (`Queued`, `Done`, `Failed`, `Interrupted`)
- **`progress`**: the original concept shows `n/m` plus a phase word. T3's timeline has no known total, so this is an open question (Q3). As built, the progress bar was dropped: the row shows a step count, run time, a model icon and the project instead.

### Local preferences (persisted)

- Hidden thread ids, panel position and collapsed state, mute, read-only mode, Close behaviour.
- Stored in `~/Library/Application Support/AgentHuddle/`. No thread content is ever written to disk.

## 9. UX, mapped to the screenshots

Visual language: a dark rounded panel, a lime accent, white titles, grey secondary text, and one coloured "buddy" per session.

### 9.1 Corner widget

- **Position**: top-right of the main display, just under the menu bar. Draggable; position is remembered.
- **Behaviour**: floats above other windows, appears on every Space, does not take keyboard focus when clicked.
- **Header, left to right**: lime status dot, the name **Agent Huddle**, the session count in grey, then three icons — speaker, chevron, ×.
  - **Dot**: lime when connected; grey when T3 is unreachable or unauthorised.
  - **Speaker**: mute toggle. What it mutes is an open question (Q7).
  - **Chevron**: collapses the panel to its header. The collapsed look is not specified (Q8).
  - **×**: hides the widget. How it comes back is not shown (Q8).

### 9.2 Session list

Each row shows:

- **Buddy avatar** in the session's colour. Buddies could blink and bob; v1 ships them static.
- **Title** — the T3 thread title, one line, truncated.
- **Status line** — one grey line; lime when the thread needs attention.
- **Progress** — lime `n/m`, a grey phase word, and a thin lime bar (subject to Q3).
- **Open-in-thread icon** (arrow in a rounded square) and **×**, stacked at the right edge.

Behaviour:

- **Hover or selection** draws a lime outline around the row.
- **Clicking the row body** opens the detail view.
- **Order**: threads needing attention first, then by most recent activity. The original order is not specified (Q10).
- **Empty state**: "No active threads" — not in the original concept; kept to one line.

### 9.3 Detail view

- **Top bar**: back chevron, small buddy pills for moving between sessions, then open-in-thread, speaker, chevron, ×.
- **Header card**: the same buddy, title, status line, and progress as the row.
- **Step checklist**: one line per step, each with a state marker and a kind icon.
  - Filled check = done; spinner with brighter text = running; empty circle = pending.
  - Terminal icon for commands; pencil icon for file writes and edits.
- **Terminal output**: as built, it lives inside the expanded step: the command in lime prefixed with `$` and the latest output lines below it in white monospace (the original draft had a separate **Terminal** pane).
  - Shows the tail of the newest `command_execution` step, refreshed every second.
  - Output is display-only. No input, no scrollback beyond the last ~20 lines.
- **Difference from the concept**: the concept lists steps not yet started. T3 exposes steps as they happen, so pending steps appear only if a plan source is found (Q3).

### 9.4 Permission prompt

Concept: the row gains a lime outline, the status reads **needs permission**, and a panel opens under it with the command (`Bash: npm run build`) and three buttons — **Allow**, **Deny** and a jump to the editor. After Allow, the status reads **Allowed ✓**.

v1 behaviour on T3:

- **Same outline, same status line, same command text** — provided the pending command can be read (Q2).
- **One primary button: "Review in T3 Code"** (as built; "In T3 Code" in the original draft), which jumps to the thread (§7.5).
- **Allow and Deny are not shown by default.** They appear only after the user opts in to inline approvals from the menu (Q1); then they are disabled in Read-only mode. Without the opt-in there are no disabled buttons; a disabled Allow invites clicking.
- **When the request is resolved in T3 Code**, the panel closes and the status line returns to normal. The "Allowed ✓" confirmation appears only if the huddle itself sent the decision.
- **A sound plays once** when a thread starts needing permission, unless muted (Q7).

### 9.5 Question

- **Row**: lime outline; status reads **asks a question**.
- **Panel under the row**: a small lime tag (the question's header, for example `LANGUAGE`), the question text, and one radio row per option. The selected option has a lime outline and a filled dot.
- **Buttons**: **Send** (lime) and **Type in T3 Code** (grey, jumps to the thread).
- **Send** is disabled until an option is selected. It calls `t3_pending_request respond`.
- **On success** the panel closes. **On failure** the panel stays, with a one-line error and the selection kept.
- **If the question was answered elsewhere**, the panel closes on the next poll.
- **Several questions in one request, multi-select, and free text** are not specified (Q5).

### 9.6 Jump to thread

- **Clicking the arrow icon** on a row or in the detail top bar brings T3 Code forward on that thread.
- The concept lands on the matching editor tab. The T3 equivalent is the thread being selected in T3 Code's sidebar — achievable only as far as §7.5 allows.

### 9.7 Close

- **Concept**: the row's × becomes a red **Close** pill; clicking it removes the row and the count drops from 4 to 3.
- **How the pill appears** (hover, or a first click that arms it) is undecided (Q6). v1: first click on × turns it into the red pill for three seconds; second click confirms.
- **What Close does** in v1: hides the session from the huddle. Nothing changes in T3.
- **Close never stops an agent.** It does not interrupt, cancel, archive, or delete.
- **A hidden thread comes back by itself** if it later needs permission, asks a question, or starts working again (a new run).
- **Optional setting**: "Close also settles the thread in T3 Code" (`t3_thread_organize settle`), off by default, offered only for finished threads (Q6).

### 9.8 Not in the concept, not in v1

No settings window beyond the few toggles above, no notifications-centre banners, no keyboard shortcuts, no theming, no light mode.

## 10. Security and privacy

- **Loopback only.** Connect only to `127.0.0.1` / `::1`. Refuse to start if the runtime file names any other host. One opt-in exception: inline approvals for another machine (Q1).
- **Never expose port 3773.** No proxying, forwarding, tunnelling, or re-serving of T3's API. The app is a client only.
- **Token is the only gate — treat it that way.** `/mcp` allows any origin, so a leaked token works from any local process or web page.
  - Keychain storage, accessible to this app only.
  - Never logged, never in crash reports, never in the repository, never in a command line.
  - Minimum scopes; a read-only mode exists.
- **Verify the peer before sending the token.** Confirm the process listening on the port is the T3 Code app (the `pid` in the runtime file is alive and belongs to bundle `com.t3tools.t3code`). Otherwise a different local process on port 3773 could harvest the token.
- **No writes to T3 state.** One file is read (`server-runtime.json`). Nothing under `~/.t3` is written, moved, or locked. SQLite files are never opened.
- **No reads of T3 secrets.** Nothing under `~/.t3/userdata/secrets/`, `clerk/`, or `connection-catalog.json`.
- **Thread content stays in memory.** Commands and output can contain secrets. They are never written to disk, never logged, never sent anywhere.
- **No network beyond loopback.** No telemetry, no update check, no analytics. The app can run with outbound network blocked; only the opt-in inline approvals for another machine (Q1) ever connect to a non-loopback host, and only to that machine.
- **Agent text is untrusted.** Titles, commands, questions, and options are rendered as plain text — no markdown, no links, no HTML — so an agent cannot draw a fake button.
- **No blind approvals, ever.** If Allow arrives later (Q1), it is per request, shows the full command untruncated, and has no "always allow".
- **App Sandbox** is wanted but unresolved (Q16): the redirect listener, the read under `~/.t3`, and running `t3 app` each need an entitlement or an exception.

## 11. Testing plan

**Principle: no test may write to the real T3 server or touch `~/.t3`.** Automated tests run against a fake.

| Layer | What | How |
|---|---|---|
| **Store / reducer** | Membership, status line, attention, ordering, hide and reappear, count | Unit tests over JSON fixtures recorded from real responses (redacted) |
| **MCP client** | JSON-RPC framing, paging by `position`, long-text continuation, `401` handling, back-off | Tests against a fake MCP server on an ephemeral loopback port |
| **Auth** | PKCE flow, Keychain round trip, token dropped on `401`, token never logged | Fake authorisation server; log-scanning assertion |
| **Discovery** | Missing file, stale `pid`, non-loopback host refused, port change | Temp-dir fixtures |
| **Security** | Only loopback connections; no file opened under `~/.t3` except the runtime file; no SQLite open | Run the app under file and network tracing during the manual pass |
| **UI** | Each state in §9 | SwiftUI previews and offscreen snapshots with fixture data |
| **Contract drift** | Tool names and required fields still exist | A read-only check on launch: `tools/list` must contain the tools in §7.2, else show "Unsupported T3 Code version" |

### Manual acceptance pass (live T3, a throwaway project)

1. Start four threads; the widget shows four rows and count 4. *(U1)*
2. Minimise T3 Code; rows keep updating. *(U1)*
3. Open a thread running a long command; steps and output advance. *(U2)*
4. Trigger a permission request; the row flags it and "In T3 Code" jumps. Approve in T3; the flag clears. *(U3)*
5. Trigger a multiple-choice question; pick and Send; the agent continues with that answer. *(U4)*
6. Click the arrow; T3 Code comes forward. *(U5)*
7. Close a finished thread; count drops to 3; the thread is unchanged in T3. *(U6)*
8. Quit T3 Code; the widget shows "not running" and recovers when T3 restarts.
9. Revoke the connection in T3 Settings; the widget asks to reconnect.
10. Compare checksums of `server-runtime.json` and directory listings of `~/.t3/userdata` before and after — only T3's own changes.

## 12. Open questions

Ordered by how much they change the product.

| # | Question | Why it is open | Proposed default |
|---|---|---|---|
| **Q1** | **How can the widget Allow or Deny a permission?** | The public MCP tool excludes approvals [V]. The internal `/ws` RPC accepts a separately paired non-MCP session and decided two real approvals (accept, decline) on 2026-11-14 [V]. | **Resolved as an opt-in (the maintainer approved, on condition that it is optional):** default off, "In T3 Code" only. From the menu, "Set up inline approvals…" takes a pairing code made with `t3 auth pairing create`, stores the session in its own Keychain account, and shows Allow / Deny (accept and decline only). The credential is broader than the MCP one (no approvals-only scope exists). The `/ws` client sends the one command `runtime-request.respond`. "Turn off inline approvals" forgets it; the session itself must be revoked in T3. Internal protocol, can break on a T3 update; the Swift client is verified against the fake only. **Extended to another machine (The maintainer approved lifting "loopback only" for this one purpose, opt-in per machine):** "Set up inline approvals for another machine…" takes a pairing code made on that machine and an https address (from `peerLinks.list` via a separate read-only `access:read` code, or typed). The decision goes to that machine's own `/ws` over wss, system trust, no redirects, only after its environment id matches the linked one; the credential and its one address live in a per-machine Keychain item. |
| **Q2** | Can the widget even *detect* a pending permission and read its command? | `pendingRequestCount` and `status: waiting` exist, but whether approvals count, and where the command text is, was not observed. | M0 spike. If undetectable, the row shows only `Waiting` plus the jump button. |
| **Q3** | Where do `n/m` and the phase word ("5/7 Animations") come from? | T3's timeline shows no total. | As built: a step count (no bar). A plan or todo list as `n/m` is not implemented; its shape has not been seen in a real thread. |
| **Q4** | Does an external OAuth client get the same MCP tools as an in-thread agent? | All MCP calls here ran inside a T3 thread. | M0 spike; it decides the auth path in §7.1. |
| **Q5** | What is the exact shape of a question and of `answers`? Multi-select? Free text? | No question was pending to read. | M0 spike. v1 handles single-select; anything else falls back to "Type in T3 Code". |
| **Q6** | What should Close mean — hide locally, settle, or archive? And is the red pill hover or click-to-arm? | The concept only shows the row vanishing. | Hide locally; click-to-arm. Optional settle setting. |
| **Q7** | What does the speaker icon control? | The icon is visible but no sound is described. | A single chime when a thread starts needing attention; the icon mutes it. |
| **Q8** | What do the collapsed state and the header × look like, and how does the widget come back? | Neither state is specified. | Collapse to the header bar. × hides until relaunch or a menubar item click. |
| **Q9** | Is there a thread-level deep link into the T3 desktop app? | `t3 app` is project-level; only `t3code://pair` and `t3code://app` were seen [B]. | Test in M0; fall back to activating the app. |
| **Q10** | Rows below an open prompt: scroll, clip, or hide while the count still includes them? | Not specified. | The list scrolls; the row with the prompt scrolls into view. |
| **Q11** | Should there also be a menubar item? | The concept shows only a floating panel. | Yes, a minimal one: show/hide and quit. Confirm with the maintainer. |
| **Q12** | How long do finished threads stay listed? | The concept shows only running sessions, and this Mac has 551 finished threads. | As built: threads the huddle saw working, plus any unsettled thread that finished in the last 30 minutes, until closed or settled in T3. A thread waiting on a background task or a subagent counts as working. |
| **Q13** | Should it start at login? | Not covered. A login item is a user-level system change. | Off by default; documented in the README, enabled only by the user. |
| **Q14** | Where does the progress bar sit in a row? | Superseded: the bar was replaced by an info line (steps, run time, model icon, project). | See README "What the panel shows". |
| **Q15** | Does a command that is still running expose partial output, and what `status` does it carry? | Only `completed` items were observed. | M0 spike. If output arrives only on completion, the Terminal pane shows the command and a spinner. |
| **Q16** | Can the app run under App Sandbox? | It needs a loopback listener, one read under `~/.t3`, and to launch `t3 app`. | Try sandboxed in M6; if it blocks the jump, ship unsandboxed and say so in the README. |
| **Q17** | Does polling change unread state in T3 Code? | A `thread.visit` command exists [B]; whether MCP reads trigger it is unknown. | M0 check. If reads mark threads read, poll the list only and read on demand. |

## 13. Milestones for a prototype

All work on a branch, in a later thread. Each milestone ends runnable.

| # | Milestone | Done when |
|---|---|---|
| **M0** | **Spike: prove the surface.** A command-line Swift target that authenticates as an external client, lists tools, lists threads, reads activity, and captures redacted fixtures. Triggers one real question, one real permission, and one long-running command in a throwaway thread to answer Q2, Q4, Q5, Q9, Q15, Q17. | Those six questions have written answers; fixtures are in the repo; this spec is updated. **Stop and review if Q4 fails.** |
| **M1** | **Read-only list.** Floating panel, discovery, auth, polling, rows with title and status line, header count, degraded states. | Manual steps 1, 2, 8, 9 pass. |
| **M2** | **Detail view.** Steps and terminal pane. | Manual step 3 passes. |
| **M3** | **Questions.** Panel, Send, error and answered-elsewhere states. | Manual step 5 passes. |
| **M4** | **Permissions (detect and jump) and jump-to-thread.** | Manual steps 4 and 6 pass. |
| **M5** | **Close, collapse, mute, buddies.** | Manual step 7 passes; reviewed against §9. |
| **M6** | **Hardening.** Security checks, contract-drift check, README covering setup, revocation, and any T3 setting the user must change themselves. | Manual step 10 passes; README written. |
| *Later* | In-widget Allow/Deny, if Q1 gets a supported answer. | — |

## Appendix — commands used for the investigation

All read-only. Recorded so the findings can be re-checked after a T3 update.

```sh
~/.t3/bin/t3 --version                      # t3 v0.1.9
~/.t3/bin/t3 thread --help                  # list, start, send, show
~/.t3/bin/t3 project --help                 # add, remove, rename
~/.t3/bin/t3 serve --help
~/.t3/bin/t3 app --help                     # opens a project directory
~/.t3/bin/t3 pair --help                    # scopes, ttl, label
~/.t3/bin/t3 status --json                  # lan disabled, no service
~/.t3/bin/t3 thread list --json             # per project
~/.t3/bin/t3 thread show <id> --messages 1 --json
jq . ~/.t3/userdata/server-runtime.json
lsof -nP -iTCP:3773 -sTCP:LISTEN            # 127.0.0.1 only
curl -s http://127.0.0.1:3773/.well-known/oauth-protected-resource/mcp
curl -s http://127.0.0.1:3773/.well-known/oauth-authorization-server
curl -si -X POST http://127.0.0.1:3773/mcp  # 401 without a credential
```

- MCP tools exercised from inside a T3 thread: `t3_thread_list`, `t3_thread_read` (activity view), `t3_pending_request` (list).
- Bundle strings were searched read-only for tool names, URL schemes, and approval commands; those results are the **[B]** items.
- Not done, on purpose: client registration, pairing, token minting, opening any SQLite file, sending any message, or responding to any request.
