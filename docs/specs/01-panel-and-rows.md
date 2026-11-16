# 01 — Floating panel and rows

**Status:** built · **Evidence:** layout and rules by automated test against the fake; the panel's mouse and focus behaviour never exercised by a test · live list, steps and a linked machine's group seen on T3 Code 0.1.9 (read-only).

## Purpose and user value

- **Glance:** see every working or recently finished T3 thread without bringing T3 Code forward.
- **Triage:** threads that need the user float to the top.
- **Cross a thread off:** Close hides a thread and the count drops.

## Behaviour as built

### Panel window

| Property | Value | Source |
|---|---|---|
| Kind | Borderless floating `NSPanel`, non-activating, movable by its background, never hides on deactivate | `PanelController.swift` |
| Spaces | Joins all Spaces; auxiliary in full-screen apps | `PanelController.swift` |
| Width | Fixed 400 pt | `Theme.width` |
| Height | Fits content; at least 140 pt; at most the saved height (default 640 pt) and at most the screen's visible height − 16 pt | `PanelController.fit` |
| Resize | Drag the bottom or top edge. The new height becomes the saved maximum; the panel still shrinks when content is shorter. List or steps scroll when content is taller | `windowDidEndLiveResize`, `MaybeScroll` |
| Position | Top-right of the main display (16 pt from the right, 8 pt below the top of the visible frame). Dragging saves the top-left point. A saved point is used only if it lies on the main screen | `PanelController.position` |
| Dock | No Dock icon (`.accessory`, `LSUIElement`) | `main.swift`, `build-app.sh` |
| Hide | Header × hides the whole panel for this launch. It is not persisted. The menu-bar item brings it back (spec 10) | `HuddleModel.hideWidget` |
| Collapse | Header chevron collapses to the header only. Persisted. The detail view is not shown while collapsed | `HuddleRootView` |
| Mute | Header speaker toggles the chime that plays once when a thread starts needing attention. Persisted | `HuddleModel.toggleMute` |

### Header

- **Left to right:** status dot (lime when connected, grey otherwise), "Agent Huddle", count, speaker, chevron, ×.
- **Count:** number of **visible** rows (working and done, closed ones excluded). It is not the number of working threads; the menu-bar count is (spec 10).
- **Degraded states** (banner under the header): "Connecting…", "T3 Code not running", "Connect to T3 Code" with a button, "Unsupported T3 Code version: …", or an error line. Detail in spec 08.
- **Empty list:** "No active threads", shown only while connected.

### Rows

Each row, top to bottom:

1. **Buddy avatar.** One of six colours (blue, pink, orange, purple, teal, yellow) chosen by a stable FNV-1a hash of the thread id.
2. **Title.** The T3 thread title, one line, plain text. A thread without a title shows "Untitled".
3. **Status line.** One line (priority in spec 02). Lime and semibold when the thread needs the user.
4. **Info line.** `N steps · run time · model icon · project`, each part dropped when unknown.
5. **Right edge.** Jump arrow (spec 05) and × (Close).
6. **Attention panels** under the row: permission panel (spec 05) and question panel (spec 04).

Row rules:

- **Tap the row body:** opens the detail view (spec 03).
- **Outline:** a lime outline while hovered or while the thread needs the user.
- **Order:** needs-user first, then newest `updatedAt`, then thread id.
- **Grouping:** rows are grouped by machine when more than one machine has rows. Header: upper-case machine label and its row count. This Mac first, then linked machines by label. A machine with no visible rows has no header. With one group there is no header. A row whose environment id is unknown to the link list is grouped under its raw id. A row with no environment id counts as this Mac.

### Info line parts

| Part | Rule |
|---|---|
| Steps | `N step(s)`: count of finished steps among the retained steps (at most 200 kept per thread) |
| Run time | Latest run: `now − start` while the thread is working (ticks every second), `completedAt − start` once it ended. Formats `42s`, `4m 12s`, `1h 02m`. Hidden when T3 gave no start time |
| Model icon | Family by model name first (claude, gpt/codex → OpenAI, grok, qwen, gemini, glm, kimi, composer → cursor, copilot, deepseek, llama, mistral), then by provider (claudeAgent, codex, grok, cursor, pi), else "other". Claude, OpenAI and Grok get a drawn glyph; the rest a letter badge (π for pi). Hover shows model display name, provider, and "Ran on …" only when the executed model differs from the thread's model. A null executed model is "unknown", not "different" |
| Project | `t3_project_read` title, looked up once per (machine, project). A thread with no project ("No project") shows nothing. A failed lookup is not retried |

### Close

- **Arm:** the first tap on × turns it into a red **Close** pill for 3 seconds. Only one row is armed at a time.
- **Confirm:** a second tap on the same row hides it. The id is written to preferences. If the detail view was open on it, it closes.
- **Optional settle:** with "Close also settles finished threads in T3" on, not in Read-only mode, and the thread's T3 status finished, the app also calls `t3_thread_organize {action:"settle"}` (fire and forget; a failure is ignored). Never for an active thread. Never archive, interrupt or delete.
- **A closed thread returns** when any of these happens:
  - **It starts working again:** a thread whose known status was not active becomes active. After an app restart every closed thread that is working shows again, because the session has no earlier state.
  - **A new run starts:** the latest run id changes.
  - **It starts needing the user:** a question or permission appears where there was none.
- **It stays closed** while still working, after it finishes, and after polls that change nothing.
- **Pruning:** closed ids are never removed from preferences.

### Preferences

`~/Library/Application Support/AgentHuddle/preferences.json`: closed thread ids, kept thread ids (rows kept across restarts), panel position, saved max height, collapsed, muted, read-only, close-settles, OAuth client id and redirect port. No thread content (a test asserts the file has no `title`).

## T3 data and tools

| What | Tool and fields | Evidence |
|---|---|---|
| Active threads | `t3_thread_list {allProjects:true, statuses:[preparing,queued,starting,running,waiting], limit:≤100, cursor?}`; reads `threadId, projectId, title, link, status, settled, snoozed, parentThreadId, itemCount, updatedAt, environmentId, providerInstanceId, model, branch`; `nextCursor` is a number | Live (shape, M0 L3); fake (paging) |
| Run time, model, branch | `t3_thread_read {view:"activity", runLimit:1}` → `thread{model, providerInstanceId, branch, runCount}`, `recentRuns[{ordinal, startedAt, completedAt, executedModel}]` | Live (L4, `executedModel` null on pi); fake |
| Project name | `t3_project_read {projectId}` → `title` (or `name`) | Fake only; the "No project" literal is from live notes |
| Machine label | `t3_environment_read {}` → `environmentId, label`; `t3_environment_links {}` → `links[]` | Live (local, empty links); linked rows' shape fake only |

## Security and privacy

- **Plain text only.** Titles, project names, branch and model strings render with `Text(verbatim:)`: no markdown, links or HTML.
- **Memory only.** Titles and steps are never written to disk or logs.

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| PNL-01 | The header count equals the number of visible rows; idle, settled and subagent threads are not rows | `StoreTests.membershipExcludesIdleAndSubagents`; `ModelTests.fourRowsCountAndNoiseExcluded` | Fake |
| PNL-02 | Rows needing the user sort before others; the rest sort by newest `updatedAt` | `StoreTests.orderingAttentionFirstThenRecent`; `ModelTests.questionAndPermissionDetected` | Fake |
| PNL-03 | With more than one machine, rows are grouped under machine labels, this Mac first; with one machine there is no header | `LiveShapeTests.threadsGroupedByEnvironmentWhenLinkedEnvironmentsAreOn`; `LiveShapeTests.linkedEnvironmentsOffMeansLocalOnlyAndNoErrorBanner` | Fake; a linked machine's group seen live per README |
| PNL-04 | The info line shows the finished-step count, a run time that ticks while working and stops at `completedAt`, formatted `42s` / `4m 12s` / `1h 02m` | `RunInfoTests.runInfoComesFromTheNewestRunAndDrivesTheClock`; `RunInfoTests.aFinishedRunStopsTheClockAtItsEnd` | Fake |
| PNL-05 | The model icon family follows the model name, then the provider; the hover names the executed model only when it differs | `RunInfoTests.familyFollowsTheModelThenTheProvider`; `RunInfoTests.displayNamesAreReadable`; `RunInfoTests.hoverMentionsTheExecutedModelOnlyWhenItDiffers` | Fake |
| PNL-06 | The project name is fetched once per project and "No project" is not shown | `DetailModelTests.projectTitleIsFetchedOncePerProjectAndNoProjectIsHidden` | Fake |
| PNL-07 | The first tap on × arms Close; the second hides the row and the count drops; a later poll keeps it hidden; T3 is unchanged | `ModelTests.closeNeedsTwoTapsHidesAndNeverCallsT3WriteTools` | Fake |
| PNL-08 | A closed thread returns when it works again (also after a restart), on a new run, or when it needs the user; it stays closed while running or after finishing | `StoreTests.closedThreadComesBackWhenItIsActiveAgain`; `StoreTests.newRunBringsBackAClosedThread`; `StoreTests.closeHidesAndReappearsOnNewAttention` | Fake |
| PNL-09 | Close never settles an active thread, and settles only when the setting is on | `ModelTests.closeNeverSettlesUnlessSettingOnAndFinished` (active case only) | Fake for the negative; **None** for the positive case (finished thread, setting on) |
| PNL-10 | Closed ids, mute, collapsed and read-only persist under the injected preferences folder and contain no thread content | `ModelTests.hiddenIdsAndTogglesPersistUnderInjectedPrefsDir`; `StoreTests.preferencesRoundTripUnderInjectedDirectory` | Fake |
| PNL-11 | A thread's buddy colour is stable and inside the palette | `StoreTests.buddyColorIsStableAndInPalette` | Fake |
| PNL-12 | A sound plays once per newly attention-needing thread and not while muted | `ModelTests.soundPlaysOncePerNewAttentionAndNotWhenMuted` | Fake |
| PNL-13 | Panel width fixed, height 140 pt to saved max, drag-resize saved, top-right default, all Spaces, non-activating | none | **None** (rendered frames only; no click or focus test, README "Limitations") |

## Open questions

- **PNL-Q1 (owner: maintainer):** closed ids are never pruned, so preferences grow forever. Prune ids not seen for N days?
- **PNL-Q2:** `Preferences.panelMaxHeight` is saved on every live resize; is a reset needed?
- **PNL-Q3:** `doneStepCount` counts only the 200 retained steps, so very long runs show "200 steps" at most. Accept?
- **PNL-Q4:** the positive settle path (finished thread, setting on) has no test and was never run live.

## Sources

`Sources/AgentHuddle/{Views,SessionInfo,PanelController,Theme}.swift`, `Sources/HuddleCore/{Store,HuddleModel,ModelInfo}.swift`, README "What the panel shows", `docs/specs/00-prototype.md` §9.1–9.2, 9.7.
