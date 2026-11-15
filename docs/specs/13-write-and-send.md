# 13 — Write an answer, send a message, steer a run

**Status:** built · **Evidence:** `SendTests` against the fake, and one live pass on 2026-11-15 (`scripts/live-check.sh --send-check`, the real `HuddleModel` against the real T3, two throwaway threads): a steer reached the running turn, a queued message started the next turn, and a written answer to a question with options reached the agent word for word. The editors themselves (typing, focus, keys) have not been checked by hand. Phase 2 (dictation) is [spec 14](14-dictation.md).

## Purpose and user value

- **Answer in your own words:** a question no longer forces you into T3 Code when the options don't fit. Write the answer in the panel.
- **Talk to any thread:** send a message to a thread without opening T3 Code, for example "also update the changelog" or "use the staging database".
- **Steer a running thread:** while an agent is mid-run, choose to **steer** it now (the message reaches the current turn) instead of **queueing** it for the next turn.

## Decisions this spec needs from the maintainer

These change existing hard rules, so they are listed first.

| # | Decision | Recommendation |
|---|---|---|
| D1 | Allow `t3_thread_send`. Today AGENTS.md, spec 12 (S10) and `ModelTests.clientNeverCallsForbiddenToolsOrIncludeSubagents` forbid it. | Allow it **only** with `mode: "queue"` or `mode: "steer"`, only from the Send button, never from polling. `restart`, `auto` and `freshContext` stay forbidden, as do `t3_thread_launch`, `t3_thread_interrupt` and `t3_queue`. |
| D2 | Allow a free-text answer to a question through `t3_pending_request respond`. | Allow it. The answer is exactly what the user typed. |
| D3 | Where the composer opens. | Inside the panel, under the row or at the bottom of the detail view. The panel can already take keyboard focus without activating the app (the paste-a-token field does). No separate window. |
| D4 | Default mode for a running thread. | **Queue**, with **Steer** one click away on the button itself. Steering changes the current turn, so it is the deliberate choice. |
| D5 | How the send button switches between Queue and Steer (no separate control). | **Decided: a swap toggle (⇄) on the button.** One click flips Queue ↔ Steer; Steer is orange. ⌥⌘↩ steers directly. |
| D6 | The bigger editor for long text. | **Decided: a pop-out window**, resizable and wider than the panel, sharing the draft with the small field. |

## Behaviour (proposed)

### Where you can write

| Thread state | Entry point | What Send does |
|---|---|---|
| Asks a question you can answer (spec 04) | **Write answer** button next to Send. **Type in T3 Code** is removed; the row's ↗ already opens the thread. | Answers the question with your text |
| Asks a question the panel cannot show (several questions, multi-select, unreadable) | none: the prompt and "Answer this one in T3 Code"; the row's ↗ opens it | — |
| Working (T3 status `running`) | **Message** button (speech bubble) on the row and in the detail header | **Queue** (default) or **Steer** |
| Working only by inference (waiting on a background task or a subagent, spec 02) | **Message** | **Send** (T3 reports the turn as completed, so `queue` starts a new turn now; there is no turn to steer). The button is labelled from T3's status, not from the panel's "working". |
| Done, idle or recently finished | **Message** | Starts a new turn (`queue`) |
| On a linked machine | none | Live T3 refuses a send through this Mac to another machine's thread (`capability_denied`, "This work was started from T3 Code - <machine>"). Open it with ↗. |
| Needs permission | none | Permission first: Allow / Deny (specs 06, 07) or Review in T3 Code. A message would only queue behind it. |

### The composer

- **Opens in place:** under the row in the list, or pinned to the bottom of the detail view. One composer at a time; opening another closes the first (its draft is kept, below).
- **Parts:** a multi-line text field (grows to 6 lines, then scrolls) with an **expand** button in its corner, the target line ("To *Render release notes* · Mac mini"), the send button, and **Cancel**.
- **The send button says what it will do:** **Send** when T3 does not report the thread as active, **Queue** when it does. Only while T3 reports it `running` does the button carry the ⇄ toggle that flips it to **Steer** (orange). There is no separate mode control. One short line under the field repeats the effect: "Sent after the current turn finishes." / "Reaches the agent during this turn."
- **Expand:** opens the same draft in a pop-out editor window (resizable, wider than the panel, titled with the thread and machine) with the same send button. Closing it returns to the small field with the text kept.
- **Keys:** ⌘↩ sends with the button's current mode, ⌥⌘↩ steers directly (only while running), Esc cancels, ↩ is a new line. Cut, copy, paste, select all and undo work in both editors.
- **Send is enabled** when the text has a non-space character, is at most 20,000 characters, the thread is still there, and read-only mode is off. A counter appears from 18,000 characters.
- **Focus:** opening the composer makes the panel key so you can type; the app you were in stays active. Cancel or Send ends editing in the panel; click back into your app to type there.
- **Draft:** kept in memory per thread until sent or cancelled with an empty field, so closing the composer by accident loses nothing, and a thread that drops out of the list and comes back still has its text. Never written to disk; gone when the app quits. The hidden Edit menu has no ⌘Q, so a stray ⌘Q in a composer does not quit.

### Sending

1. **Target fixed at open:** the composer holds the thread id and machine it was opened for. If the thread disappears, or a second machine reports the same id (spec 12, per-machine ids), Send is disabled with the reason.
2. **State re-checked at Send:** before a steer, the thread's status is read fresh from T3 (one `t3_thread_read`), and the steer is sent only if it is still `running`. If the turn ended while you typed, nothing is sent; the button changes to **Send** and the composer says "The run finished. Send as a new turn?" so the change is never silent.
3. **One request, one id:** each Send carries a `clientRequestId` tied to the exact thread, mode and text. A retry of the same message reuses it, so a double click or a retry cannot deliver it twice; editing the text or flipping the mode mints a new one, so an edited message is never dropped as a duplicate.
4. **Call:**
   - message: `t3_thread_send {threadId, message, mode: "queue" | "steer", clientRequestId}`, plus `environmentId` for a linked machine.
   - answer: `t3_pending_request {action: "respond", threadId, requestId, answers: {<questionId>: <text>}}`, plus `environmentId` (same codec as spec 04, `QuestionCodec`).
5. **Success:** the composer closes, the draft is cleared, the row shows a lime toast for 3 seconds ("Steered", "Queued" or "Answer sent"), and the list refreshes.
6. **Failure:** the composer stays with the text, shows a one-line error (first 120 characters, cleaned like other server text), and Send becomes **Retry**.

### Read-only mode

The **Message** and **Write answer** buttons still show, but the composer opens disabled with "Read-only mode. Turn it off in the menu to send." Nothing is sent.

## T3 data and tools

| Tool | Arguments | Scope | Evidence |
|---|---|---|---|
| `t3_thread_send` | `threadId`, `message`, `mode` (`queue` or `steer` only), `clientRequestId`, `environmentId` | operate (the OAuth token already requests `orchestration:operate`) | None. Schema only: `queue` = new turn, `steer` = mid-turn update. |
| `t3_pending_request` | `action: "respond"`, free-text value in `answers` | operate | None. Spec 04's answer shape is itself **assumed** (QST-Q1). |

`ContractCheck.required` does not gain `t3_thread_send`: without it the app still works, and the **Message** button is hidden. The button needs the tool **and** its advertised `mode` argument (gated on `tools/list`, like `t3_environment_links`).

## Security and privacy

- **The text is yours, sent only on a click.** No message is ever composed from agent text, and nothing is sent from polling, a timer or a keyboard shortcut outside the composer.
- **Narrow tool use:** only the two modes above. Restart, interrupt and fresh context could throw away an agent's work, so they stay in T3 Code.
- **Agent text stays untrusted:** the target line shows the cleaned title (`DisplayText.clean`). Nothing an agent writes can pre-fill the composer.
- **Not logged:** the message and drafts stay in memory; `HuddleLog` gets the error category only.
- **Same machine rules:** a linked machine's thread is reached through this Mac's T3 MCP with `environmentId`, as reads and answers already are. No new network path.
- **Steer is explicit:** never the default, never automatic, re-checked before sending.

## Live finding: the sign-in's mode caps what can be sent

T3 refuses a send **and a question answer** (picked option or written) to a thread whose runtime mode is broader than the mode Agent Huddle signed in with: `runtime_mode_escalation_denied`, "Child runtime mode auto is broader than …". An "approval-required" sign-in cannot reach threads in **auto** or **full access**; an "auto" sign-in reaches approval-required and auto threads, not full access. **Decided (SND-Q5):** the install guide recommends signing in at the level the threads run at, usually auto, and full access only if the threads use it. The panel says so in plain words (`HuddleModel.modeDeniedMessage`) instead of showing T3's JSON. Threads in approval-required mode work.

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| SND-01 | Send on a running thread calls `t3_thread_send` with `mode:"queue"` by default, and `mode:"steer"` only when flipped or with ⌥⌘↩; a finished thread says Send and never steers | `SendTests.aRunningThreadQueuesByDefaultAndSteersOnlyWhenFlipped`, `optionCommandReturnSteersOnceWithoutTheToggle`, `aFinishedThreadSaysSendAndStartsANewTurn`, `aBackgroundWaitIsLabelledFromT3sStatusNotThePanels` | Fake |
| SND-02 | A thread that stopped running between open and Send sends nothing and offers a new turn | `aRunThatEndedWhileTypingSendsNothingAndOffersANewTurn` | Fake |
| SND-03 | A retry reuses the `clientRequestId`, an edit or a flipped mode mints a new one; a double click sends one request | `aRetryReusesTheRequestIdAndAnEditGetsANewOne`, `aRepeatedRequestIdIsDeliveredOnce` | Fake |
| SND-04 | Read-only mode sends nothing | `readOnlyModeSendsNothing` | Fake |
| SND-05 | The composer's target cannot change: a thread that changes machine or collides disables Send; empty or overlong text is not sent; asking threads get no composer | `theTargetCannotChangeUnderTheComposer`, `emptyOrOverlongTextIsNotSent`, `threadsThatAskForSomethingGetThatFirst` | Fake |
| SND-06 | A free-text answer calls `respond` with the typed text for the question id; multi-select and several questions cannot be written | `aWrittenAnswerIsSentAsTyped`, `multiSelectQuestionsCannotBeWritten` | Fake |
| SND-07 | Messages never reach the log | `messagesNeverReachTheLog` | Fake |
| SND-08 | Only `queue` and `steer` reach T3, never `freshContext`, launch, interrupt or `t3_queue`; one typed call site | `onlyQueueAndSteerEverReachT3`, `theOnlySendCallSiteIsTheTypedOne`, `ModelTests.clientNeverCallsForbiddenToolsOrIncludeSubagents` (polling) | Fake |
| SND-09 | Without `t3_thread_send` or its `mode` argument, there is no Message button and nothing is sent; polling never sends | `withoutTheToolOrItsModeArgumentThereIsNoMessageButton`, `pollingNeverSends` | Fake |
| SND-10 | A real steer and a real queued message reach an agent; a real free-text answer is accepted | `scripts/live-check.sh --send-check` | **Live** (2026-11-15, approval-required threads) |
| SND-13 | Threads on a linked machine have no composer; a `capability_denied` refusal reads in plain words | `aThreadOnAnotherMachineSaysSoInPlainWords` | Fake; refusal **Live** |
| SND-12 | A thread in a broader mode than the sign-in is refused, and the panel says why in plain words (send, written answer and picked option alike) | `aThreadInABroaderModeSaysSoInPlainWords` | Fake; refusal **Live** |
| SND-11 | Typing, focus, ⌘X/C/V/A/Z and the pop-out window work in the built app | none | **None** (by hand) |

Snapshots: stills 34–43 (`--snapshot`).

## Open questions


- **SND-Q1 (needs a live pass):** does T3 accept a free-text answer to a question that has options, and for which harnesses? If not, **Write answer** shows only for questions that allow free text.
- **SND-Q2:** should a queued message be visible on the row ("1 queued") using `t3_queue list`? Out of scope; it would add a read-only tool.
- **SND-Q3 (answered 2026-11-15):** no. A send from the MacBook's app to a thread on the Mac mini was refused with `capability_denied`. Whether a different link access level changes that is unknown; whether a question answer on a linked machine is refused too has not been tried.
- **SND-Q4:** attachments (images, files) are out of scope.

## Sources

`docs/specs/04-questions.md`, `docs/specs/12-non-functional-rules.md` (S10), T3's `t3_thread_send` and `t3_pending_request` tool schemas, AGENTS.md "Tools the client may call".
