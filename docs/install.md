# Install and connect

## Install

Needs a Mac with **Apple silicon** (the build is arm64 only) and macOS 14 or later.

1. Unzip `AgentHuddle.zip` and move **Agent Huddle.app** to Applications. The app is **ad-hoc signed, not notarized**.
2. First launch: macOS blocks it. On macOS 15 and later the old right-click → Open shortcut no longer works for such apps. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or remove the quarantine flag: `xattr -dr com.apple.quarantine "/Applications/Agent Huddle.app"`. (This is how macOS treats unnotarized downloads in general; it has not been tried on a downloaded zip of this app.)
3. The menu-bar item appears (no Dock icon). **Connect to T3 Code** in the panel starts the sign-in below.
4. To start it at login, add it under System Settings → General → Login Items yourself.

Each rebuild changes the ad-hoc signature, so macOS may ask for your Keychain password again after an update.

## Connect to T3 Code

A bearer from `t3 auth session issue` is **rejected** on T3's `/mcp` (401), so the app signs in with T3's advertised **OAuth flow** instead, and that works.

1. **T3 Code running**, then launch the app and click **Connect to T3 Code**. The app (all on `127.0.0.1`) verifies the listener, registers one OAuth client named "Agent Huddle" (reused later), and opens your browser at T3's approval page (PKCE S256).
2. **Approve** there with a pairing code (`~/.t3/bin/t3 auth pairing create --label "Agent Huddle" --ttl 10m`, paste the token). **Choose a read + operate access level such as "approval-required" ("Supervised"), not Full access**: read-only can't answer questions, full access is wider than the huddle needs. The token is stored in the Keychain.
3. **Other machines** show up under their own headers once linked: see [Show threads from other machines](other-machines.md).
4. **Revoke:** `~/.t3/bin/t3 auth session list` / `revoke <sessionId>`. On a 401 the app drops its token and asks you to reconnect; if sign-in fails the panel shows the reason in red. No refresh grant is advertised, so expect to sign in again when the 30-day token expires.
5. "or paste a token" under the button is a fallback only.
