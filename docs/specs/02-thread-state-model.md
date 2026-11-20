# 02 — Thread state model

**Status:** built · **Evidence:** reducer rules fully unit-tested; T3 status values, list and activity shapes seen live; "waiting on a background task" comes from T3's `pendingBackgroundTasks` field (T3 0.1.11 and later) and is an **inference from item patterns** before that; "waiting on a subagent" is an inference with no official T3 signal.

## Purpose and user value

- **Show what is alive:** the panel lists working threads and recently finished ones, not the backlog (a real T3 holds hundreds of finished or idle threads).
- **Don't call a thread "Done" while it is not:** T3 reports `completed` for a thread that is waiting on its own subagents, and (before 0.1.11) on a background task.
- **Don't ask for an approval that does not exist:** T3 0.1.11 reports `waiting` for a thread that waits on a background task or a watched PR.

## Behaviour as built

### T3 status words

| T3 `status` | Active | Finished | Status-line words |
|---|---|---|---|
| `preparing`, `starting` | yes | | Starting |
| `queued` | yes | | Queued |
| `running` | yes | | Running |
| `waiting` | yes | | Waiting |
| `completed` | | yes | Done |
| `failed` | | yes | Failed |
| `interrupted` | | yes | Interrupted |
| `cancelled` | | yes | Cancelled |
| `rolled_back` | | yes | Rolled back (never fetched, see below) |
| `idle` | | | Idle (never listed) |
| anything else | | | Unknown |

### Which threads are rows

1. **Active list** (each poll, this Mac and each linked machine): active statuses, not settled. Each becomes or updates a row.
2. **Subagents are never rows.** A listed thread with `parentThreadId` is dropped. A subagent is never read (reading marks it delivered in T3).
3. **Finished refresh:** statuses `completed, failed, interrupted, cancelled`, `settled:false`, `limit:25`, **one page, no cursor chasing**. It runs when any known row is not active, or at least 10 s after the last run.
   - **Known rows are refreshed.** A known row that is now settled or snoozed leaves. A known, non-active row absent from an exhaustive page leaves (settled, archived or aged out).
   - **A partial page cannot say why a row is missing**, so a known, non-active row absent from it is re-read (at most every 30 s per row); a read that says settled, snoozed or archived removes it (seen live: a settled row stayed while more than 25 unsettled finished threads existed).
   - **Recently finished rows are admitted** even if the app never saw them run: unsettled, not snoozed, no parent, `updatedAt` within **30 minutes**.
   - **Older finished rows are never newly admitted.**
4. **Idle:** a row whose thread read says `idle` is removed. `idle` threads are never requested.
5. **Left the active set without a finished report:** the row's status becomes unknown ("Unknown") until a finished page settles it. On a non-exhaustive page it can stay "Unknown".
6. **Closed rows** (spec 01) are kept in state but filtered from view.

A finished row stays until it is settled, snoozed or archived in T3 (seen in a list or in its own read), closed, or drops out of an exhaustive finished page.

**Kept across restarts** (asked for by the maintainer): the ids of the rows on the list (and their machine) are saved in the preferences as `keptThreads`, ids only. After a restart each one that is not back through the lists is read by id on its own machine and returns as it was, however long ago it finished. It is forgotten when the user closes it, when T3 says it is settled, snoozed or archived, or when T3 cannot read it (deleted). A machine that cannot be reached is tried again (at most every 30 s per row). At most 300 ids are kept.

### Working

`isWorking` is true when any of:

- T3 status is active;
- one or more of its **subagents** is active (`activeChildren > 0`, no time cap);
- it is **waiting on a background task**: T3 lists one (below), or, on a T3 that does not send the field, the inference below says so and the wait is under **2 hours** old.

### Waiting on a background task (T3 0.1.11 and later)

- **T3's field decides.** Every list row and read carries `pendingBackgroundTasks`, an array of `{taskId, kind, description, awaited}` (`[]` when nothing is pending; seen live, 2026-11-21). `kind` is `command` for a background command and `monitor` for a watched PR (`taskId` `pull-request-watch:github.com/<repo>#<n>`). The panel keeps only the count of `awaited: true` entries; `description` is agent text and is not stored or shown.
- **A count above zero:** the thread is working and, unless a question or permission comes first, the status line is "Waiting on a background task" (also for a PR watch). T3 reports such a thread as `waiting` with no active run and `pendingRequestCount: 0`.
- **Not an approval:** `waiting` with no listed question is normally inferred as a permission (spec 05). It is not when T3 lists an awaited task and there is no sign of an approval: no `approval_request` item and `pendingRequestCount` 0. Either sign keeps the permission. Only T3's field can lift the inference, never the item-pattern rule below.
- **A count of zero** overrides the item-pattern rule: the wait has ended, whatever the items say.
- **The field missing** (T3 before 0.1.11): the inference below is used.

### Waiting on a background task (inference, T3 before 0.1.11)

- **Starts:** an activity item of type `dynamic_tool` whose text, whitespace removed, contains `"toolName":"mcp__t3-code__t3_background_wait"` or `"toolName":"t3_background_wait"`. A tool search that merely mentions the name is not a wait. T3 answers `{"matched":[…],"unmatched":[…]}` (seen live); a call that matched no task (`"matched":[]`: the task already ended or never existed) neither starts nor ends a wait. A call whose answer is cut off counts as a wait.
- **The wait does not block.** `t3_background_wait` returns at once, so the agent can go on working while the task runs, and T3 before 0.1.11 exposed no wait state (checked live on 2026-11-19: nothing in the thread's or the list's fields). T3 keeps the thread in Working until the task exits, **across later runs**: seen live, a watched PR's notice started a new run that ran commands and ended, and T3 still showed Working. The rule is a function of the item stream alone, so a cold read of the whole thread and polling agree.
- **Ends:**
  - **T3's notice that the command exited:** a `notification` item with an item id of the form `message:thread:<thread>:…` and the text `Command "<the command's description, or the command cut at about 80 characters>" finished` (both seen live). The id is what counts; the text is a fallback. It starts the run that wakes the agent. Other notifications do not end a wait: a watched PR's (`#420: checks failed`, item id `message:pr-watch:…`) starts a run too, while the task still runs.
  - **A wait call with `"waiting": false`.**
  - **Shell work or edits in the same run, 2 minutes or more after the wait:** a `command_execution` or `file_change` item from the wait's run whose `updatedAt` is at least 2 minutes after the wait's. A task that exits inside the turn leaves no item (seen live), and an agent that goes on working for minutes has usually seen it finish. Quicker work is a peek at a task still running (seen live: `sleep 20; grep … log` 26 seconds after the wait, then the turn ended). Work in a later run says nothing about the task. Other tool calls (linking a PR, a final message) never end it.
- **Known gaps (heuristic):** an agent that keeps working for over 2 minutes after a wait and ends its turn while the task still runs shows "Done" while T3 shows Working, until the task exits and T3's notice starts a new run. A task that exits inside a *later* run (no notice, no item) keeps the row "Waiting" until the cap. T3 0.1.11's `pendingBackgroundTasks` fixes both (above).
- **Cap:** 2 hours from the newest wait call (its item's `updatedAt`; the thread's own `updatedAt` only if the item has none), so a task killed without notification stops counting and a settle does not restart the clock.

### Waiting on a subagent (inference)

- The parent is `completed` while a child with its `parentThreadId` is active. The parent counts as working with the status line "Waiting on a subagent" (or "Waiting on N subagents").
- The child itself is never a row.

### Status line (first match wins)

1. `needs permission`
2. `asks a question`
3. the label of the newest running step, **only while T3 says the thread is active** (a finished thread never shows a stale step)
4. "Waiting on a subagent" / "Waiting on N subagents" (parent not active, children active)
5. "Waiting on a background task" (working but not active)
6. the T3 status words above

### Attention

Permission, then question, then failed, then done (finished and not working), else none. Needs-user is permission or question.

### Activity items and steps

- **Positions are thread-wide** (seen live: `runLimit:1` limits only `recentRuns`, and a read without `afterPosition` starts at the thread's first item). A changed `latestRunId` drops the steps, resets `lastPosition` and the background wait, forgets the old approval request, un-hides the thread, and re-reads from the top, which finds a wait from an earlier run again.
- **Not steps:** `reasoning`, `user_message`, `approval_request`.
- **Steps:** every other item (commands, tool calls, assistant messages, notifications, errors). At most 200 are kept; older ones are dropped.
- **Incremental reads:** each poll re-reads from `lastPosition − 3` (never below 0) so status changes on the newest items are caught.

### Polling schedule

| Situation | Interval |
|---|---|
| List, panel expanded | 2 s |
| List, panel collapsed | 5 s |
| Detail view open | 1 s loop (list still due on its own interval) |
| After 1–2 failures | 5 s, even with detail open |
| After 3 or more failures | 15 s |
| First success | back to normal |

A thread is re-read only when `status`, `updatedAt` or `itemCount` changed, when it is new, or when it has a pending request whose approval item has not yet been seen `waiting`.

## T3 data and tools

| What | Detail | Evidence |
|---|---|---|
| Statuses | `idle, preparing, queued, starting, running, waiting, completed, interrupted, failed, cancelled, rolled_back` from the tool schema | Live (schema); only `completed` and `running`/`waiting` seen on real threads |
| Thread list fields | see spec 01; list rows carry no `pendingRequestCount`, only a read does | Live |
| Subagents come back without `includeSubagents` | `relationshipToParent:"subagent"`, `parentThreadId` | Live (spec research, M0) |
| Activity items | types `user_message, assistant_message, command_execution, dynamic_tool, reasoning`; `approval_request` seen on a waiting `pi` thread; `notification` and `error` items are **assumed** | Live for the first six; `notification`, `error`: None |
| Background wait item | `dynamic_tool` with `toolName` and `input.taskIds` in its JSON text, answer `{"matched":[…],"unmatched":[…]}` | Live (two threads, 2026-11-16 and 2026-11-19); tests use synthetic items of the same shape |
| Wait across the turn end (live check, 2026-11-19) | A throwaway thread ran `sleep 240` in the background, waited on it, peeked with `sleep 20` and ended its turn. With the turn over and the timer running, `main` showed "Done" and this rule "Waiting on a background task" (`scripts/live-check.sh --huddle`, the real `HuddleModel`). When the timer ended, T3's notice started a new run and both showed "Done" | Live |
| `pendingBackgroundTasks` (T3 0.1.11, 2026-11-21) | On every list row and read; `[]` on threads with nothing pending. Three `waiting` threads, each with `pendingRequestCount: 0`, no active run and an empty pending list: one awaited a command (`kind: "command"`), two a PR watch (`kind: "monitor"`). v0.2.2 showed the two PR-watch threads as "needs permission"; this rule shows "Waiting on a background task" (`scripts/live-check.sh --huddle`, the real `HuddleModel`). A real approval on a thread that also awaits a task was not observed | Live |
| Task-exit and PR notices | `notification`: `Command "…" finished` (id `message:thread:…`) and `#N: checks failed` (id `message:pr-watch:…`) | Live (2026-11-16 and 2026-11-19) |

## Security and privacy

- Never read a subagent thread; never pass `includeSubagents` (asserted by test).
- Item text stays in memory; step detail is capped at 1,500 characters, command output at 20,000.

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| STM-01 | Idle threads and subagents are not rows; a subagent thread is never read | `StoreTests.membershipExcludesIdleAndSubagents`; `ModelTests.fourRowsCountAndNoiseExcluded` | Fake |
| STM-02 | A thread whose read resolves to `idle` leaves the panel | `HardeningTests.threadThatResolvesToIdleLeavesTheHuddle` | Fake |
| STM-03 | Status line priority: permission, question, running step, status words | `StoreTests.statusLinePriority` | Fake |
| STM-04 | A finished thread ignores a stale running step and shows "Done" | `FinishedStatusTests.finishedThreadIgnoresAStaleRunningStep`; `StoreTests.failedStatusLine` | Fake |
| STM-05 | A finished thread stays until settled, then leaves; finished rows older than 30 minutes are not admitted; settled ones never are | `StoreTests.finishedSessionsStayUntilSettledThenLeave`; `StoreTests.finishedRowsAreNeverNewlyAdmitted`; `StoreTests.recentlyFinishedThreadIsAdmittedButOldOnesAreNot` | Fake |
| STM-06 | The finished refresh is one page of 25 with no cursor, and an old backlog is never admitted | `HardeningTests.finishedRefreshIsOnePageWithNoCursorChasing` | Fake |
| STM-07 | A completed thread waiting on `t3_background_wait` counts as working and shows "Waiting on a background task" until T3's command notice arrives; a quick peek, a PR notice or a later run does not end it, and a cold read agrees with polling; a call that matched no task is not a wait; shell work 2 minutes after the wait in the same run ends it; a mention of the tool in a search is not a wait; a wait older than 2 hours stops counting | `StoreTests.waitingOnABackgroundTaskCountsAsWorkingEvenThoughT3SaysCompleted`; `StoreTests.aWaitOutlivesAQuickPeekAPRNoticeAndALaterRun`; `StoreTests.aWaitThatMatchedNoTaskNeitherStartsNorEndsAWait`; `StoreTests.onlyT3sCommandNoticeEndsAWait`; `StoreTests.aWaitFollowedByMoreShellWorkIsTakenAsDone`; `StoreTests.aToolSearchMentioningBackgroundWaitIsNotAWait`; `StoreTests.staleBackgroundWaitStopsCountingAsWorking` | Fake (shapes from live) |
| STM-07a | T3's `pendingBackgroundTasks` decides the wait when present: an awaited task on a `waiting` thread with no approval sign is "Waiting on a background task", not a permission; an approval item or a pending request count keeps the permission; without the field, or with no awaited task, `waiting` is still a permission; an empty list ends a wait the item pattern still sees | `StoreTests.waitingOnABackgroundTaskIsNotAnApproval`; `StoreTests.anApprovalWhileATaskIsAwaitedStillNeedsPermission`; `StoreTests.waitingWithoutTheFieldOrWithNoAwaitedTaskIsStillAnApproval`; `StoreTests.t3sEmptyTaskListOverridesTheWaitHeuristic` | Fake (shape from live) |
| STM-07b | A wait ends when the agent goes on with shell work or edits, or clears it (`waiting: false`), not on other tool calls; the cap counts from the wait; a settled finished row leaves on its own read, also behind a partial finished page | `StoreTests.aWaitFollowedByMoreShellWorkIsTakenAsDone`; `StoreTests.otherToolCallsAfterTheWaitDoNotEndIt`; `StoreTests.theWaitCapCountsFromTheWaitNotFromASettle`; `StoreTests.aSettledThreadLeavesWhenItsReadSaysSo`; `SettledBehindAFullPageTests.aSettledRowLeavesEvenWhenTheFinishedListIsPartial` | Fake; both cases seen live |
| STM-07c | A done row comes back after a restart until closed; a closed row stays closed; a settled or deleted one is forgotten; only ids are stored | `KeptAcrossRestartsTests` | Fake |
| STM-08 | A completed parent with active subagents counts as working and shows "Waiting on a subagent" / "Waiting on 2 subagents"; the child is not a row; it returns to "Done" when the children finish | `RunInfoTests.aWorkingSubagentKeepsACompletedParentWorking` | Fake |
| STM-09 | Reasoning and user messages are not steps; approval items are prompts, not steps; error items become failed steps | `StoreTests.reasoningItemsAreNotSteps`; `LiveShapeTests.userMessagesAreNotStepsAndPathsAreShortened`; `RunInfoTests.theApprovalItemGivesTheExactCommandAndIsNotAStep`; `RunInfoTests.stepsKeepADetailAndErrorsFail` | Fake |
| STM-10 | Activity is read for the latest run only, `afterPosition` is never negative, a new run restarts the steps from the top | `LiveShapeTests.activityReadsOnlyTheLatestRunAndNeverSendsNegativeAfterPosition`; `LiveShapeTests.newRunRestartsStepsFromTheTop` | Fake; the constraints themselves were found live |
| STM-11 | A numeric `nextCursor` is kept and sent back as a number | `LiveShapeTests.numericNextCursorIsKeptAndSentBackAsANumber` | Fake; shape found live |
| STM-12 | List interval 2 s expanded, 5 s collapsed, 5 s after a failure, 15 s from the third; detail loop 1 s; retries never faster than back-off | `StoreTests.pollScheduleAndBackoff`; `HardeningTests.retryNeverFasterThanBackoffEvenWithDetailOpen` | Fake |
| STM-13 | A thread is re-read only when status, `updatedAt` or `itemCount` changed | `StoreTests.needsReadOnlyWhenChanged` | Fake |
| STM-14 | A row left unreported after leaving the active set shows "Unknown" on a non-exhaustive page | none | **None** |
| STM-15 | `rolled_back` threads are never listed | none (code: `T3Status.finishedStatuses` omits it) | **None** |

## Open questions

- **STM-Q1:** is there an official T3 signal for "waiting on a subagent"? `blockedOnThreadWait` (seen live, always `false` so far) may be it; not used until seen `true`. The background-task wait has one since 0.1.11 (`pendingBackgroundTasks`).
- **STM-Q4:** a watched PR reads "Waiting on a background task". Should it say something PR-specific? A new label is new UI, so it waits for the owner.
- **STM-Q2:** `notification` and `error` item shapes were never captured live. Confirm against real items.
- **STM-Q3:** the 30-minute recent window and 2-hour cap are defaults chosen by the prototype (SPEC Q12 proposed "only threads seen running"). Owner to confirm.
- **STM-Q4:** archived threads: the code has no explicit archived check; they are assumed absent from the unsettled finished page. Not verified.
- **STM-Q5:** do MCP reads change T3's unread state (SPEC Q17)? Not checked.

## Sources

`Sources/HuddleCore/{Models,Store,HuddleModel}.swift`, README "What the panel shows", `docs/specs/00-prototype.md` §5.3, §7.3, §8 (§8 membership is superseded).
