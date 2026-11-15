# Inline approvals (Allow / Deny in the panel)

Optional and off by default. Without it a permission request shows the command and a **Review in T3 Code** button. Everything here is opt-in; T3's MCP has no approval call, so this uses T3's internal WebSocket for one command only.

## Threads on this Mac

Turn it on from the menu-bar item **Inline approvals…**. One window lists this Mac and every linked machine with its own state (On, Off, or Needs re-pair) and sets each one up in its row.

1. In a terminal run `t3 auth pairing create --scope orchestration:read --scope orchestration:operate --label "Agent Huddle approvals" --ttl 10m` (the app's dialog shows it, with a **Copy command** button; if `t3` is not on your PATH, use `~/.t3/bin/t3`). Paste the code it prints into the dialog.
2. Agent Huddle trades the code for a session on T3's own login endpoint (`POST /oauth/token`) and keeps that session token in the Keychain, in a field of its own, separate from the MCP token. The pairing code is single use and is not stored.
3. **Allow** and **Deny** now appear under the exact command, for threads on this Mac (threads on another machine: see [the next section](#threads-on-another-machine)). Neither is a default button. They are disabled in Read-only mode.

**This credential is broader than the MCP one.** Approving goes through T3's internal `/ws` RPC, which has no approvals-only scope: `orchestration:operate` there also covers sending to, launching and interrupting threads. Agent Huddle only ever sends one command, `runtime-request.respond` with accept or decline (a test enforces it), and requests only `orchestration:read` + `orchestration:operate` even if the code you paste carries more. But anyone who got hold of the token could do more than approve.

- **What you approve is what you saw.** A request is shown for a second before Allow works and starts collapsed again if it changes under an open row. A request is only approvable when its text has no repeated JSON keys (two parsers can read those differently), and for tools other than a shell command every field must be the one shown. Details: A command that could be clipped (over about 80 characters, or more than two lines) starts collapsed and **Allow** stays off until you press **Show full command**; **Deny** is always available. Invisible and direction-changing characters in commands, titles and step names are shown as visible escapes such as `⟦U+202E⟧`.
- **Before every decision** the app re-reads that very request and sends only if it is still waiting with the same command text. Only a request the panel shows in full is approvable: a command over about 400 characters, or a tool whose input has more than the one field shown (a Write's content, say), stays on **In T3 Code**.
- **Turn off:** the **Turn off** button on this Mac's row in the window removes the credential from the Keychain at once. T3 does not let a client revoke its own session, so also run `t3 auth session list` and `t3 auth session revoke <id>` for the session labelled "Agent Huddle approvals" (or remove it under Settings → Connections in T3 Code). Until then the token stays valid in T3 for about 30 days.
- **On a rejected token** (revoked or expired) the app switches the feature off and the panel falls back to **Review in T3 Code**.
- **Internal protocol.** `/ws` is T3's private first-party protocol (orchestration protocol 2); a T3 update can break it without notice. Verified live with a Node script on 2026-11-14 (accept and decline on real threads); the Swift client ran one accept live (through `scripts/live-check-remote.sh`, on this Mac's own https address); the rest only against the fake.

## Threads on another machine

**Off by default, and per machine.** This is the one place Agent Huddle talks to something that is not on this Mac, so it is a separate opt-in. It lets **Allow** and **Deny** work for threads that run on a linked machine (for example a headless Mac mini over Tailscale) by sending the decision to *that machine's* own T3 over https.

**Prerequisites**

- The machine is already linked (see [Show threads from other machines](other-machines.md) below), so its threads appear.
- On **that machine**, T3 is reachable over https. With Tailscale: `tailscale serve --bg 3773` there. The certificate must be a normal, trusted one; Agent Huddle uses the system's trust and has no way to skip a check.

**Set up** (menu-bar item **Inline approvals…**, then **Set up…** on the machine's row; a linked machine can have several addresses, and each is checked against the machine you linked before it is offered)

1. Pick the machine.
2. **Address.** It must be the machine's name, not an IP address (a certificate vouches for a name). Agent Huddle can find it for you: **Find address…** asks for a one-time, read-only pairing code made on **this** Mac (`t3 auth pairing create --scope orchestration:read --scope access:read --label "Agent Huddle discovery" --ttl 10m`). T3's normal connection does not share linked machines' addresses; this code can read them through `peerLinks.list` (`access:read` covers only that and the list of sessions, no credentials, nothing that can change anything). It is used once and thrown away. Or skip it and type the https address yourself, like `https://mac-mini.tailnet.ts.net`.
3. **Pairing code.** On **the other machine** run `t3 auth pairing create --scope orchestration:read --scope orchestration:operate --label "Agent Huddle approvals" --ttl 10m` and paste the code.
4. Agent Huddle checks that the address answers with the linked machine's public environment id, and only then sends the code. That answer is **not proof**: any host can repeat a public id. So the window only offers an address that T3 itself linked the machine at (from discovery, or one you saved), and an address you typed needs your explicit confirmation that you trust it. A different machine's id is refused. The resulting session is kept in the Keychain (account `approvals-remote-<environment id>`) together with the address it may be sent to.

**This credential is broader than Agent Huddle's normal one**, exactly like the one for this Mac: on that machine it could also send messages to, launch and interrupt threads. Agent Huddle only ever sends `runtime-request.respond` with accept or decline, but anyone who got hold of the token could do more. It lasts about 30 days.

**What stays the same:** explicit click, no default button, disabled in Read-only mode, only a complete `waiting` request, re-read from T3 right before sending, the exact command shown as plain text. The address is never taken from thread content: only from what discovery returned or what you typed.

**For a thread on a machine with no credential** the panel says so by name ("Inline approvals aren't set up for Studio Mac…") and **Review in T3 Code** still works. This hint only appears once you have turned some inline approvals on; with everything off the panel is unchanged.

**Turn off:** the **Turn off** button on the machine's row removes that machine's credential from the Keychain at once. T3 does not let a client revoke its own session, so on **that machine** run `t3 auth session list`, then `t3 auth session revoke <id>` for the session labelled "Agent Huddle approvals". The same goes for the "Agent Huddle discovery" session on this Mac if you used **Find address…**. A rejected credential (revoked or expired) switches off only that machine.

**Not verified:** this path has run live against this Mac's own https address and against the linked MacBook's public descriptor; a decision to a genuinely separate machine over Tailscale has not been tried end to end.
