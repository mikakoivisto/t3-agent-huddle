# Demo

A short video and one screenshot per feature. Everything here ran against **two fake T3 machines** (`Sources/FakeT3`), on `127.0.0.1` only. No real T3 Code, no token, no Keychain, nothing under `~/.t3`. All thread titles, commands, ids and model names are invented.

The two machines are **Mika’s MacBook Pro** (plays "this Mac") and **Mika’s Mac mini** (plays a linked machine). Their names are labels set on the fakes; no real machine is involved. Hostnames in the Inline approvals window (`*.tailnet-demo.ts.net`) are invented too.

## Video

[`agent-huddle-demo.mp4`](agent-huddle-demo.mp4): about 89 s, 1300×1000, H.264. The real floating panel on a stage with captions. [`agent-huddle-preview.gif`](agent-huddle-preview.gif) is its first 30 s, used inline in the README.

## Stills

`stills/`, numbered. Rendered with `ImageRenderer` unless noted.

| File | Shows |
|---|---|
| `01-list-two-machines` | The list grouped under the two machines, info line on each row |
| `02-menu-bar-robot-frames` | The menu-bar buddy: idle, then its four animation frames with the count (**drawn on a strip**, not a screenshot of the menu bar) |
| `03-model-icons-and-tooltip` | Rows on Claude, Codex, Qwen on pi, Grok and a letter badge, with the hover text (**the tooltips are drawn callouts**: a hover cannot be captured offscreen) |
| `04-detail-info-and-steps` | Detail: project, branch, run time, model, steps; the running command's output |
| `05-detail-command-output-and-error` | Steps opened: a command's output and a failed step |
| `06-detail-ran-on-another-model` | "→ ran on" a different model than requested |
| `07-waiting-on-background-task-and-subagent` | Threads T3 reports as completed, still working |
| `08-waiting-threads-finished` | The same two once they really finished |
| `09-question-select-and-send` | A question with an option selected, Send enabled |
| `10-permission-review-in-t3` | A permission prompt: tool badge, exact command, Review in T3 Code (inline approvals off) |
| `11-permission-long-command-collapsed` / `12-…-full` | A long command collapsed with "Show full command", and drawn as if that were tapped |
| `13-inline-approvals-this-mac` | Allow / Deny on a thread of this Mac |
| `14-inline-approvals-other-machine` | Allow / Deny on a thread of the Mac mini (its own login) |
| `15-inline-approvals-read-only` | Read-only mode: buttons disabled, with the reason |
| `16-inline-approvals-machine-not-set-up` | A thread on a machine without a login says so |
| `17-inline-approvals-refused` | The command changed after it was shown: nothing is sent, the panel says so |
| `18-inline-approvals-after-allow` / `19-…-after-deny` | The thread carrying on after Allow, and after Deny |
| `20-inline-approvals-window` | The window: this Mac on, Mac mini on, one machine needing re-pair, two off |
| `21-inline-approvals-window-setup` | A machine with two addresses (each checked) and its setup steps open |
| `22-close-armed` / `23-closed-count-drops` / `24-closed-thread-returns` | Two-tap Close, the count dropping, the thread back when it works again |
| `25-collapsed` | The collapsed header |
| `26-resize-short-scrolling` / `27-resize-taller` | The real panel dragged short (the list scrolls) and taller (**live window, not `ImageRenderer`**) |
| `28-about-panel` | The About panel (**the live AppKit window; see below**) |
| `29-app-icon` | The app icon, 512 px |
| `30-jump-toast` | The toast when a deep link could not be delivered |
| `31-t3-not-running` / `32-connect-to-t3` | The degraded states |

## What is fake or approximate

- **Data:** two fake servers, synthetic threads. The Mac mini's fake only answers its own decisions; the MacBook's fake serves the list for both machines, like T3's linked environments do.
- **Credentials:** the "pairing codes" are the fakes' single-use ones; credentials sit in memory. Origins use the loopback test policy, so the window shows invented https addresses while the app talks to `127.0.0.1`.
- **No mouse:** the driver calls the same model methods the buttons call (including Allow, Deny, Send and the two taps on ×); it does not synthesise clicks. "Show full command" is view state, so the video shows it collapsed and a still shows it open.
- **Composites:** the menu-bar strip, the tooltip callouts, and the stage around the panel are drawn by the demo, not by the app.
- **About panel:** captured from the real AppKit window, which in a development build has the generic app icon and clips its credits text; the icon beside it is the app's own. The credits are the app's own text.

## How it was made

`scripts/make-demo.sh` regenerates all of it (needs `swift` and `ffmpeg`, no Screen Recording permission, about 2.5 minutes):

1. **Stills:** `AgentHuddle --snapshot demo/stills` starts the two fakes, drives the model through each state and renders the SwiftUI views with `ImageRenderer`.
2. **Video:** `AgentHuddle --record DIR` shows the real floating panel, runs the scripted driver and snapshots the panel's live `NSHostingView` at 10 fps with `cacheDisplay`, composed onto the stage. `ffmpeg` stitches the frames into H.264. The stills that need the real window (resize, About) are written by the same run.
3. **Icon:** `AgentHuddle --icon` renders it, `ffmpeg` scales it.

Why not `screencapture`: window capture was refused without Screen Recording permission (not requested). Rendering the app's own views needs no permission and cannot capture anything else on the desktop.
