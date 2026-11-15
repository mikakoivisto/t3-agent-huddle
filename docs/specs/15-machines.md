# 15 — Machines: connect to any T3, this Mac or another

**Status:** built (core and window), M1–M4 decided as recommended · **Evidence:** live on 2026-11-15 (`scripts/live-check.sh --remote-mcp <https address> --remote-send …`, against the Mac mini's own Tailscale https address with throwaway threads): identity check, OAuth sign-in with a pairing code on that machine's T3 page, 71 tools and the contract check, thread list, a steer that reached the running turn, a queued message that became the next turn, and a written answer that arrived word for word. `MachinesTests` cover the rest against two fakes. The Machines window itself has not been clicked through by hand.

Supersedes, once built: the "this Mac only" connection of spec 08, the link-based remote view of spec 09, and the separate Inline approvals window of spec 07 (folded into the Machines window). Spec 06 and 07's decision rules stay as they are.

## Purpose and user value

- **Start anywhere:** on first launch, connect to T3 on this Mac or on another machine (a headless Mac mini, a build box). No local T3 needed.
- **Everything works on every connected machine:** list, read, answer (option or written), message, steer. Each machine is reached through its **own** T3 MCP, so T3 never refuses a send because it came through a link (spec 13, `capability_denied`).
- **One place for machines:** the Machines window shows each machine, how it is connected, and its optional inline approvals.

## Decisions this spec needs from the maintainer

| # | Decision | Recommendation |
|---|---|---|
| M1 | Extend the "loopback only" exception to the MCP of another machine. | Yes, per machine and off until set up, with the remote-approvals guardrails: https only, system trust, no redirects, names not IP addresses, identity check before the sign-in and before every connection. |
| M2 | Keep showing machines that are only **linked** in T3 (not connected here)? | Yes, read-only: their rows show, with "Connect *machine* to answer here" instead of buttons. It keeps today's view for people who do not connect every machine. |
| M3 | One setup for MCP and approvals? | One row and one flow per machine, but **two pairing codes** when approvals are wanted: a pairing code is single use, and T3 refuses an MCP token on `/ws`. Approvals stay an optional second step. |
| M4 | Machine order in the panel. | This Mac first (when connected), then the others by name, as today. |

## Behaviour (proposed)

### Machines

- **A machine** is one T3 server: its environment id, its name (from T3), how it is reached, and its credentials.
- **This Mac** is found as today (runtime file, peer check tied to the listener, loopback). It is offered when T3 runs here; it is not required.
- **Another machine** is reached at an https address: one T3 listed for it (local discovery through `peerLinks.list`, when this Mac's T3 is connected), or one the user types. Typed addresses that T3 did not list need the user's confirmation, as in spec 07.
- **Connected** = the app holds an MCP token for that machine. **Linked only** = this Mac's T3 lists the machine but the app has no token for it (read-only rows, M2). **Offline** = connected, but the address does not answer; the group header says so and the last list stays, greyed, for 30 seconds.

### First launch

The panel's "Connect to T3 Code" card offers:

1. **This Mac** (shown when T3 runs here): today's sign-in.
2. **Another machine…**: opens the Machines window on the add flow.

### Adding another machine

1. **Address:** pick one T3 listed, or type a name (`mac-mini.tailnet.ts.net`; `https://` is added). IP addresses are refused.
2. **Check:** the app fetches `/.well-known/t3/environment` (no credentials) and shows the machine's name and id. Nothing secret has been sent.
3. **Sign in:** the app shows the command to run **on that machine**, `t3 auth pairing create --scope orchestration:read --scope orchestration:operate --ttl 10m`, then opens that machine's T3 sign-in page in the browser. The user pastes the pairing code there and picks the access level (usually Auto, spec 13). The redirect comes back to this Mac's loopback listener, as for this Mac.
4. **Stored:** the MCP token goes into the Keychain vault with the machine's id and origin, in one record, as remote approvals already do.
5. **Optional, inline approvals:** "Turn on Allow / Deny" asks for a second pairing code made on that machine (spec 07 flow, unchanged).

### Polling

- One MCP client per connected machine, polled side by side. A failing machine never stops the others.
- Threads are grouped by machine. A thread id seen on two machines is still ignored on the second (spec 12).
- A linked-only machine's threads come through this Mac's T3 as today, read-only.

### The Machines window (menu bar → Settings… → Machines, spec 14)

*As built (spec 14):* this is the Settings window's Machines tab. Each machine shows two feature lines with a state chip and one button: **Connected** (the MCP sign-in: Sign out / Connect…) and **Approve commands from the panel** (inline approvals: Turn on… opens its setup in place, Turn off, Re-pair…). The sign-in level is not shown (MCH-Q1).

One row per machine: name, address, how it is connected (This Mac · Connected · Linked only · Offline · Sign-in expired), its sign-in level when T3 reports it, and two switches: **Answers & messages** (the MCP sign-in) and **Allow / Deny** (inline approvals). Each row has **Sign out**. "Add machine…" at the bottom.

### Signing out

Per machine, from its row: forgets that machine's MCP token (and, separately, its approvals login). The menu's "Sign Out of T3 Code…" (spec 08) becomes "Machines…"; signing out of every machine returns the panel to the Connect card.

## Security and privacy

- **Same guardrails as remote approvals (spec 07):** `RemoteOriginPolicy.production` for every remote address (https, names only, no userinfo, path or query), system certificate trust, no redirects, bounded reads, identity check (`environmentId`) before the sign-in and before a client is (re)built. The token goes only to the origin stored with it.
- **One credential per machine and purpose:** MCP token and approvals login are separate entries in the vault record, each deleted by its own Sign out.
- **This Mac keeps its stronger check:** the peer check tied to the listener applies to the local machine only; remote machines are proved by TLS plus the environment id, which is public, so the user confirms unlisted addresses.
- **Nothing new is sent to a machine before the user sets it up.** Discovery stays read-only.
- **Tools per machine are the same allowed set** (AGENTS.md "Tools the client may call").

## Acceptance criteria (proposed)

| ID | Statement | Tests |
|---|---|---|
| MCH-01 | With no T3 on this Mac, a remote machine can be added and its threads listed, answered and messaged | new, two fakes on loopback with the fixture policy |
| MCH-02 | A remote address is refused unless https and a name; the identity check runs before the sign-in and before each client build | new, `RemoteOriginPolicy` |
| MCH-03 | One machine failing does not stop the others; its group says Offline | new |
| MCH-04 | A linked-only machine is read-only and says how to connect | new |
| MCH-05 | Each machine's token goes only to its own origin; signing out of one keeps the others | new |
| MCH-06 | The existing local token and approvals logins carry over without a new sign-in | new, vault migration |
| MCH-07 | A real sign-in to another Mac's MCP over Tailscale, then an answer and a message | by hand |

## Open questions

- **MCH-Q1:** does T3 report the sign-in's access level, so the row can show it?
- **MCH-Q2:** should a remote machine's threads be openable in T3 Code from here (↗)? The deep link needs that machine to be linked in this Mac's T3 app.
- **MCH-Q3 (answered 2026-11-15):** yes, the remote sign-in page takes the pairing-code decision exactly like this Mac's.

## Sources

`docs/specs/07-inline-approvals-other-machines.md`, `08-connecting-to-t3.md`, `09-linking-other-machines.md`, `13-write-and-send.md`; the unauthenticated metadata checks above.
