# Install and connect

## Install

Needs a Mac with **Apple silicon** (the build is arm64 only) and macOS 14 or later.

1. Download **AgentHuddle.dmg** from the [latest release](https://github.com/mikakoivisto/t3-agent-huddle/releases/latest), open it and drag **Agent Huddle** onto **Applications**. (The release also has `AgentHuddle.zip` with the same app.)
2. Open it. Releases from v0.2.1 on are signed with a Developer ID and notarized by Apple, so macOS opens them after the usual "downloaded from the internet" question. Releases up to v0.2.0 were ad-hoc signed: macOS blocks those until you click **Open Anyway** in **System Settings → Privacy & Security**.
3. The menu-bar item appears (no Dock icon). The panel's **Connect to T3 Code** card offers **This Mac** (when T3 runs here) and **Another machine…** ([Other machines](other-machines.md)).
4. To start it at login, add it under System Settings → General → Login Items yourself.

Everything the app stores sits in **one** Keychain item (`app.t3huddle.AgentHuddle` / `vault`). Signed releases keep the same identity from one version to the next, so updating does not ask for Keychain access again. The first signed version (v0.2.1) asks once more, because the app's identity changed from ad-hoc to Developer ID; so does a build you make yourself without a Developer ID, every time. The first launch of a version that has the vault copies the older separate items into it and deletes them; if you decline one of those prompts, that item stays where it is and is tried again on the next launch.

## Connect to T3 Code

A bearer from `t3 auth session issue` is **rejected** on T3's `/mcp` (401), so the app signs in with T3's advertised **OAuth flow** instead, and that works.

1. **T3 Code running** here, then launch the app and click **Connect** next to **This Mac**. The app (all on `127.0.0.1`) verifies the listener, registers one OAuth client named "Agent Huddle" (reused later), and opens your browser at T3's approval page (PKCE S256).
2. **Approve** there with a pairing code (`~/.t3/bin/t3 auth pairing create --label "Agent Huddle" --ttl 10m`, paste the token). **Choose the access level your threads run at, usually "Auto"**: T3 refuses answers and messages to a thread running in a broader mode than the sign-in, so an "approval-required" sign-in can't reach your auto threads. Read-only can't answer or send at all. Pick Full access only if your threads run in full access: it is the widest key to keep in the Keychain, and Agent Huddle only ever calls a short, fixed list of T3 tools. The token is stored in the Keychain.
3. **Other machines:** connect them from **Settings… → Machines** in the menu bar: [Other machines](other-machines.md). This Mac is optional; you can connect only other machines.
4. **Sign out or revoke:** menu bar → **Settings… → Machines** → **Sign out** in a machine's row makes the app forget that sign-in (use it to sign in again at a different access level). T3 keeps the session until you revoke it: `~/.t3/bin/t3 auth session list` / `revoke <sessionId>`. On a 401 the app drops its token and asks you to reconnect; if sign-in fails the panel shows the reason in red. No refresh grant is advertised, so expect to sign in again when the 30-day token expires.
5. "or paste a token" under the button is a fallback only.
