# Status per feature

State on `main`. The automated tests (`swift test`) run against a fake T3 only.

**Live** = seen on real T3 Code 0.1.9 (2026-11-14). **Fake** = automated test against the fake or a pure unit test only. Labels are defined in the [index](README.md).

| # | Feature | Built | Verified live | Only against the fake | Known gaps |
|---|---|---|---|---|---|
| 01 | [Panel and rows](01-panel-and-rows.md) | yes | list, run time, model, steps, a linked machine's finished thread in its own group | grouping, info line, order, Close and its return rules, preferences, chime | settle-on-Close positive path untested; no click, hover or focus test; closed ids never pruned |
| 02 | [Thread state model](02-thread-state-model.md) | yes | statuses, list and activity shapes, `runLimit:1`, numeric cursor | membership, 30-minute window, settled, idle, subagent and background-task waits, back-off | the two "waiting" states are inferences; `notification` and `error` items never captured; `rolled_back` never listed |
| 03 | [Detail view](03-detail-view.md) | yes | item types and long-text fields | step rules, expand rules, output tail and paging | running-command partial output never seen; layout untested; output cache never evicted |
| 04 | [Questions](04-questions.md) | yes | list returns `{requestIds:[]}` | read and respond, error and answered-elsewhere states, fallbacks, read-only | **question and answer shape assumed**; no real question ever answered |
| 05 | [Permission prompts and jump](05-permission-prompts.md) | yes | the `approval_request` item (one `pi` thread); markdown link from a linked machine | detection, summary, badge logic, jump hand-off, deep-link forms | jump landing not observed; Claude, Codex, ACP approvals not run; label mismatch with README |
| 06 | [Inline approvals, this Mac](06-inline-approvals-this-mac.md) | yes (opt-in) | `/ws` protocol: accept and decline (Node), one accept (Swift, https path), token exchange with `scope=` | setup, guards, re-read check, error mapping, one-command scans | in-app loopback route and Swift decline never run live; Keychain store and setup window never run |
| 07 | [Inline approvals, other machines](07-inline-approvals-other-machines.md) | yes (opt-in) | origin policy, identity check, exchange and one accept over `wss` on this Mac's own https address; `peerLinks.list`; a linked MacBook's descriptor | all guards, redirects, per-machine states, window state, scans | no decision to a separate machine; no live decline; window, Keychain and built `.app` never run |
| 08 | [Connecting to T3](08-connecting-to-t3.md) | yes | OAuth flow (approved by pairing code), contract check, 401, CLI token rejected, full tool set | PKCE, state, foreign host, drift, redirects, log scrubbing, read-only | browser approval page, sign-in button, Keychain, real peer check never run; read-only is app-side only |
| 09 | [Linking other machines](09-linking-other-machines.md) | display yes; linking is a CLI step | one Tailscale https link: `reachable`, recent thread shown | grouping, Labs-off path, link rows, kept link action | no link UI by design; running and waiting rows of a linked machine never seen; expiry unhandled |
| 10 | [Menu-bar item](10-menu-bar-item.md) | yes | none | persistence inputs only | menu, icon, animation, About never driven by a test |
| 11 | [Packaging and distribution](11-packaging-and-distribution.md) | yes | none | `swift test` only | build script and both workflows never run here; no notarization; release workflow versus "no publishing" |
| 12 | [Cross-cutting rules](12-non-functional-rules.md) | yes | none | loopback, redirects, scans, tool set, log scrubbing, polling schedule | plain-text rule has no scan; request budget never measured |
| 13 | [Write and send](13-write-and-send.md) | yes (phase 1) | steer mid-turn, queue to the next turn, written answer, real question shape, the mode refusal | send, queue, steer, the stale-steer check, retries and ids, written answers, read-only, target and collision checks, tool gating (`SendTests`) | steer, queue and a written answer verified **live** (approval-required threads); threads in auto or full access refuse sends and answers from the recommended sign-in; the editors, focus and edit keys are unchecked by hand |
| 14 | [Dictation](14-dictation.md) | no (proposed, phase 2) | none | none | starts after 13 is verified |

## What blocks calling the prototype verified

1. **A real question and answer** (spec 04): shape unknown.
2. **The jump landing** (spec 05).
3. **In-app decisions**: loopback accept and decline, and one to a separate machine (specs 06, 07).
4. **The `.app` on a clean Mac**: Gatekeeper, Keychain prompts, peer check (specs 08, 11).
