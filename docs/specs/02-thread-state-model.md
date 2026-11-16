# 02 — Thread state model

**Status:** built · **Evidence:** reducer rules fully unit-tested; T3 status values, list and activity shapes seen live; "waiting on a background task" and "waiting on a subagent" are **inferences from item patterns** and have no official T3 signal.

## Purpose and user value

- **Show what is alive:** the panel lists working threads and recently finished ones, not the backlog (a real T3 holds hundreds of finished or idle threads).
- **Don't call a thread "Done" while it is not:** T3 reports `completed` for a thread that is waiting on a background task or its own subagents.

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
- it is **waiting on a background task** and the thread's `updatedAt` is under **2 hours** old.

### Waiting on a background task (inference)

- **Starts:** an activity item of type `dynamic_tool` whose text, whitespace removed, contains `"toolName":"mcp__t3-code__t3_background_wait"` or `"toolName":"t3_background_wait"`. A tool search that merely mentions the name is not a wait.
- **The wait does not block.** `t3_background_wait` returns at once ("keep this thread in Working while background work runs"), so the agent can go on working while the task runs, and T3 exposes no wait state (checked live: nothing in the thread's fields). While the turn runs T3 says "running" anyway; the inference only matters after the turn ends.
- **Ends:** a later `notification` item (the finished task woke the agent); a wait call with `"waiting": false`; a later `command_execution` or `file_change` item (the agent went on with shell work or edits, so the wait is taken as done: seen live, where a task finished inside the turn, no notification came, and a settled thread kept showing the wait); or a new run. Other tool calls after it (linking a PR, a final message) do not end it.
- **Known gap:** an agent that waits, keeps running commands, and ends its turn while the task still runs shows "Done" until T3 wakes it with a notification (a new run). T3 would need to expose its wait state to fix this.
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

- **Latest run only:** reads use `runLimit:1`; positions restart at 0 for a new run. A changed `latestRunId` drops the steps, resets `lastPosition` and background wait, forgets the old approval request, un-hides the thread, and re-reads from the top.
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
| Background wait item | `dynamic_tool` with `toolName` in its JSON text | None: no recorded live capture or fixture; the code and README assert the pattern, the test uses a synthetic item |

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
| STM-07 | A completed thread waiting on `t3_background_wait` counts as working and shows "Waiting on a background task" until a notification arrives; a mention of the tool in a search is not a wait; a wait older than 2 hours stops counting | `StoreTests.waitingOnABackgroundTaskCountsAsWorkingEvenThoughT3SaysCompleted`; `StoreTests.aToolSearchMentioningBackgroundWaitIsNotAWait`; `StoreTests.staleBackgroundWaitStopsCountingAsWorking` | Fake |
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

- **STM-Q1:** is there an official T3 signal for "waiting on a background task" or "waiting on a subagent"? Today both are patterns that T3 can change.
- **STM-Q2:** `notification` and `error` item shapes were never captured live. Confirm against real items.
- **STM-Q3:** the 30-minute recent window and 2-hour cap are defaults chosen by the prototype (SPEC Q12 proposed "only threads seen running"). Owner to confirm.
- **STM-Q4:** archived threads: the code has no explicit archived check; they are assumed absent from the unsettled finished page. Not verified.
- **STM-Q5:** do MCP reads change T3's unread state (SPEC Q17)? Not checked.

## Sources

`Sources/HuddleCore/{Models,Store,HuddleModel}.swift`, README "What the panel shows", `docs/specs/00-prototype.md` §5.3, §7.3, §8 (§8 membership is superseded).
