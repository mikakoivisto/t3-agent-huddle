# Other machines

Agent Huddle can connect to T3 Code on **any** machine, not just this Mac: a headless Mac mini, a build box. Each connected machine is reached through **its own** T3, so you can answer, message and steer its threads from the panel. You don't need T3 running on the Mac where the panel runs.

There are two ways a machine can show up:

- **Connected** (recommended): the app signs in to that machine's T3 directly. Everything works.
- **Linked only**: this Mac's T3 links to the machine, and its threads come through that link. They are **read-only**: T3 refuses answers and messages sent that way. The panel says "Connect *machine* to answer here".

## 1. Give the machine an https address

T3 has to be reachable over https with a real certificate; the app refuses plain http and IP addresses for another machine. Tailscale is the easy route:

1. **Install it on both Macs:** `brew install --cask tailscale`, or download it from <https://tailscale.com/download>. Open the app.
2. **Sign in on both with the same account.** Both machines then appear in one private network (a tailnet).
3. **On the other machine, expose T3 over https:**
   ```sh
   tailscale serve --bg 3773
   ```
   This gives `https://<machine-name>.<tailnet>.ts.net` with a real certificate, and T3 stays on loopback there. Find the name with `tailscale status`. If it asks for HTTPS certificates, enable them once in the Tailscale admin console under DNS.
4. **Check from this Mac:** `curl -s https://<machine-name>.<tailnet>.ts.net/.well-known/t3/environment` shows the machine's name.

## 2. Connect it

1. Menu bar → **Settings…** → **Machines** → **Add machine…** (or **Another machine…** on the panel's Connect card).
2. Type the address (`<machine-name>.<tailnet>.ts.net`) and click **Check**. The app asks the machine what it is, sending nothing secret, and shows its name. Check it is the machine you mean.
3. **On that machine**, run the pairing command the window shows (`t3 auth pairing create --scope orchestration:read --scope orchestration:operate --ttl 10m`).
4. Click **Open sign-in page**. Your browser opens that machine's T3 page: paste the code and choose the access level its threads run at (usually **Auto**; see [Install](install.md#connect-to-t3-code)).
5. The machine's threads appear under its own header.

To disconnect, click **Sign out** in its row. T3 on that machine keeps the session until you revoke it there (`t3 auth session list`, then `t3 auth session revoke <id>`).

**Allow / Deny** for that machine's threads is a separate, optional login with its own pairing code: **Set up…** in the machine's row ([Inline approvals](inline-approvals.md#threads-on-another-machine)).

## Linking (optional)

Linking a machine in this Mac's T3 (Settings → Labs → Linked environments, then `t3 environment link https://<machine>… --pairing-code <code> --access approval-required`) lets its threads show up read-only without connecting it. The Machines window lists linked machines with a **Connect…** button.

Verified on 2026-11-15: signing in to another Mac's T3 over its Tailscale https address, listing its threads, steering a running thread, queueing a message and sending a written answer all worked (live check with throwaway threads).
