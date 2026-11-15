# Show threads from other machines

The T3 server on this Mac keeps *links* to other machines and relays tool calls to them. Agent Huddle talks to `127.0.0.1`; T3 makes the cross-machine hop. (The one exception is the opt-in [Allow / Deny for another machine](inline-approvals.md#threads-on-another-machine).) These links are separate from the "Connections" list in the T3 app, so linking is a one-time step per machine.

**1. Turn on Settings → Labs → Linked environments** on this Mac. Without it, other machines return `capability_denied`.

**2. Give both machines a secure address.** T3 refuses to link over plain `http://` (`PeerLinkError: ... is plain http`). Use an `https` address or a Tailscale address. Tailscale is the easy route:

1. **Install it on both Macs:** `brew install --cask tailscale`, or download it from <https://tailscale.com/download>. Open the app.
2. **Sign in on both with the same account.** Both machines then appear in one private network (a tailnet).
3. **On the other machine, expose T3 over https:**
   ```sh
   tailscale serve --bg 3773
   ```
   This gives `https://<machine-name>.<tailnet>.ts.net` with a real certificate, and T3 stays on loopback there. Find the name with `tailscale status`. If it asks for HTTPS certificates, enable them once in the Tailscale admin console under DNS.
4. **Check from this Mac:** `ping <machine-name>.<tailnet>.ts.net`.

**3. Link the machine.**

1. **On the other machine,** create a pairing code (`t3 pair`, or `~/.t3/bin/t3 auth pairing create --label "link" --ttl 10m`).
2. **On this Mac,** run:
   ```sh
   ~/.t3/bin/t3 environment link https://<machine-name>.<tailnet>.ts.net --pairing-code <code> --access approval-required
   ```
   Use `approval-required`, not `full-access`.
3. **Check:** `~/.t3/bin/t3 environment list` should show the machine as `reachable`.

Repeat per machine. To remove one: `~/.t3/bin/t3 environment unlink <environment id>` (this only forgets it here; also revoke the session in that machine's Connections). The link expires after 30 days; link again then.

Verified on 2026-11-14: linking a second Mac over a Tailscale `https` address worked and `t3 environment list` showed it as `reachable`. The panel then showed the remote machine's recently finished thread under its own group (live check).
