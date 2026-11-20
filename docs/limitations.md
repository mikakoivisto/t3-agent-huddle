# Limitations

- **No messages to threads on another machine.** T3 refuses a message sent through this Mac to a linked machine's thread, so those rows have no message button; open the thread with ↗.
- **A thread running in a broader mode than Agent Huddle's sign-in can't be messaged or answered from the panel**: T3 refuses it, and the panel says so. Sign in at the level your threads use, usually Auto ([Install](install.md)); with an Auto sign-in, only full-access threads are out of reach. This also applies to picking a question's option.
- **Inline Allow / Deny is opt-in and rides on T3's internal `/ws` protocol.** T3's MCP has no approval call, so by default a permission shows the command and **Review in T3 Code**. A T3 update can break the opt-in without notice.
- **Permission detection** uses T3's `approval_request` item (live); when that item is absent it falls back to the newest unfinished command, an inference.
- **Jump uses T3's own thread deep link** `t3code://threads/<environmentId>/<threadId>` (found in the desktop bundle's link parser; `t3 app <path>` opens a *new thread*, so it is not used). A linked machine returns its links as markdown, which the app strips. The landing on the right thread has not been observed.
- **Question/answer shape is assumed** (SPEC Q5): multi-select, several questions and free text show "Type in T3 Code". Sending an answer has not been exercised live.
- **The "waiting on a subagent" state is inferred** from child threads, not from a T3 status. **"Waiting on a background task"** comes from T3's `pendingBackgroundTasks` on T3 0.1.11 and later; a watched PR shows the same words. On an older T3 it is inferred from items: a killed background task that sends no notification stops counting after 2 hours, and the rule is a heuristic (spec 02): an agent that works on for over 2 minutes after a wait and ends its turn while the task still runs shows Done while T3 shows Working, and a task that exits inside a later run keeps the row Waiting until the 2-hour cap.
- **No token, context-window or cost numbers**: T3 exposes none to MCP clients.
- **Approvals only for a complete request**: a command over about 400 characters, or a tool input with more than the one field shown, stays on **Review in T3 Code**.
- **App Sandbox untried** (Q16). Releases are signed and notarized from v0.2.1; a build you make yourself without a Developer ID is not. The real Keychain is not covered by automated tests (a prompt would hang them); the vault and its migration are tested against an in-memory store and were checked once by hand against the real Keychain.
- **Terminal output is assumed append-only** (the pane fetches only new characters via `textOffset`); rewritten output would not refresh.
- **No automated test has clicked the panel or the Settings window.** Hit-testing, hover, focus and resizing were only seen in rendered frames.
- **Polling only** (2 s expanded, 5 s collapsed, 1 s on the open thread; 5 s after a failure and 15 s after three). No push channel found.
- **Apple silicon only**, macOS 14+.
