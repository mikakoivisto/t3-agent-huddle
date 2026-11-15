# 03 — Detail view

**Status:** built · **Evidence:** logic and fetch strategy against the fake; item and output shapes (commands, tool calls, long text paging) seen live; the UI layout never clicked by a test.

## Purpose and user value

- **Inspect one thread:** what it ran, what it is running, and the tail of a command's output, without opening T3 Code.
- **See failures:** an error item shows as a failed step, in red.

## Behaviour as built

### Entering and leaving

- **Open:** tap a row body. **Back:** the chevron in the top bar. Closing the thread or its disappearance from the list also leaves the detail view.
- **Not shown while collapsed.**
- **Polling:** while open, that thread is read every 1 s (loop interval), and its newest command's output is refreshed (below).

### Layout (top to bottom)

1. **Top bar:** back, the thread's buddy pill (only the selected thread's), jump arrow, mute, collapse, hide.
2. **Header card:** buddy, title (one line), status line.
3. **Attention panels:** the permission and question panels (specs 04, 05).
4. **Info block** (parts omitted when unknown):

   | Line | Content |
   |---|---|
   | Project | project title, plus `· branch` when known; without a project name a **Branch** line |
   | Running / Took | "Running" while working, "Took" after; the run time and `· run N` |
   | Model | icon and display name (for example "Claude Sonnet 5.5") |
   | (blank label) | `→ ran on <model>` in lime when the run executed on a different model than the thread's |

5. **Steps:** a scrolling list, or "No steps yet".

### Steps

- **Row:** disclosure chevron, state icon, kind icon, label (one line).
- **State icon:** done = grey check; running = spinner; failed = red cross (label red); pending = empty circle.
- **Kind icon:** pencil for edits, terminal for commands, wrench for everything else.
- **Kind rule:** `command_execution` is a command. `dynamic_tool` is an edit when its title starts with write, edit, multiedit, update, create, apply or patch (case-insensitive), else a tool. Every other item type is a message.
- **Label:** the item's title, with absolute paths shortened to file names ("Read /a/b/SPEC.md" becomes "Read SPEC.md"); for a command the command line after `$ `; else the first line of the text; else the type.
- **State rule:** T3 `status` completed, complete, done, success = done; running, in_progress, inprogress, started = running; failed, error, declined = failed; anything else = pending. An item of type `error` is always failed, labelled with its text.
- **Open and closed:** a running step is open until the user closes it; finished steps start closed. The user's choice is kept for the session (memory only).

### Expanded step body

- **Command:** `$ <command>` in lime (three lines at most), then the **last 20 lines** of the output in monospace. A running command with no output yet shows a spinner and "waiting for output".
- **Other steps:** the start of the item's text (tool input, path, message), up to 1,500 characters and 10 lines, or "No details".
- **Output fetch strategy:**
  - **List reads** carry only the first 400 characters of each item.
  - **Opening a finished command** fetches its full text once (4,000-character pages, up to 60 pages, capped at 200,000 characters) and keeps the last 20,000.
  - **The newest command of the open thread** is refreshed each second by reading only new characters (`textOffset` = characters already consumed). The cache keeps the last 20,000 characters and never flickers back to the 400-character head.
  - **Assumption:** output is append-only; rewritten output would not refresh.

### Errors

- An `error` item is a failed step. No other error surface exists in this view.

## T3 data and tools

| What | Tool and fields | Evidence |
|---|---|---|
| Steps | `t3_thread_read {threadId, view:"activity", runLimit:1, limit:50, maxCharsPerItem:400, afterPosition?}` → `items[{position, itemId, type, status, title, text, textTruncated, nextTextOffset, updatedAt, runId}]`, `hasMore`, `thread{latestRunId, activeRunId, pendingRequestCount, status}` | Live (L4, L5) |
| Full output | same tool with `itemId`, `textOffset`, `maxCharsPerItem:4000` | Live (long-text continuation fields seen); the fetch loop fake only |
| Item types | `command_execution` (text `$ <cmd>\n<output>`), `dynamic_tool` (title `Read /abs/path`, text JSON), `assistant_message`, `reasoning`, `user_message` | Live |
| Running item status | `running` with growing `text` (SPEC Q15) | None: only `completed` was seen live |
| `error` item | type `error`, text = message | None |

## Security and privacy

- All step text is plain (`Text(verbatim:)`).
- Output, details and commands stay in memory, capped as above.
- Reading only the user's own listed threads; never a subagent.

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| DET-01 | Steps list commands, edits and tools in order; reasoning is hidden; the step counts match | `StoreTests.reasoningItemsAreNotSteps` | Fake |
| DET-02 | File paths in step labels shorten to file names; user messages are not steps | `LiveShapeTests.userMessagesAreNotStepsAndPathsAreShortened` | Fake |
| DET-03 | A running step is open by default, finished steps open on tap, a hand-closed running step stays closed; opening a finished command loads its full output | `DetailModelTests.aRunningStepIsOpenByDefaultAndTheRestOpenOnTap` | Fake |
| DET-04 | The terminal tail is the last 20 lines with the `$` prompt stripped | `StoreTests.terminalPaneTailsOutputAndStripsPrompt` | Fake |
| DET-05 | Live output advances in the open detail view | `ModelTests.detailViewShowsLiveTerminalOutput` | Fake |
| DET-06 | Long output keeps the tail, fetches only new text (`textOffset` past 20,000), and does not flicker back to the head | `HardeningTests.longOutputKeepsTheTailAndFetchesOnlyNewText` | Fake |
| DET-07 | An `error` item is a failed step labelled with its text; steps keep a detail except commands | `RunInfoTests.stepsKeepADetailAndErrorsFail` | Fake |
| DET-08 | The info block shows project, branch, run time and run number, model, and "ran on" only when the executed model differs; a null executed model is not "different" | `RunInfoTests.runInfoComesFromTheNewestRunAndDrivesTheClock`; `RunInfoTests.aFinishedRunStopsTheClockAtItsEnd`; `RunInfoTests.hoverMentionsTheExecutedModelOnlyWhenItDiffers` | Fake (view layout: None) |
| DET-09 | Detail polling is 1 s and never faster than the back-off after failures | `HardeningTests.retryNeverFasterThanBackoffEvenWithDetailOpen` | Fake |
| DET-10 | Layout, disclosure animation, scrolling and the 10-line cap | none | **None** (snapshot renders only, `--snapshot`) |

## Open questions

- **DET-Q1:** SPEC §9.3 describes a separate "Terminal" pane. It no longer exists; the tail lives in the expanded step. `Session.terminal` remains for tests only. Remove it, or keep it?
- **DET-Q2:** a running command's partial output (SPEC Q15) is assumed, never seen live.
- **DET-Q3:** `outputCaches` is keyed by item id and never evicted (memory only, 20,000 characters each) — grows over a long app session.
- **DET-Q4:** T3 exposes no token or context numbers, so none are shown.

## Sources

`Sources/AgentHuddle/{Views,SessionInfo}.swift`, `Sources/HuddleCore/{Store,HuddleModel,MCPClient}.swift`, README "What the panel shows", `docs/specs/00-prototype.md` §9.3 (partly superseded).
