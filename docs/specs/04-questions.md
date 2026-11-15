# 04 — Questions answered in the widget

**Status:** built · **Evidence:** against the fake only. No question was pending on the real T3 during any live check, so the question and answer shapes are **assumed**.

## Purpose and user value

- **Answer without switching apps:** when an agent asks a single-choice question, pick an option and send it from the panel.
- **Fall back safely:** anything the panel cannot answer correctly goes to T3 Code.

## Behaviour as built

### Detection

- A thread is checked when its status is `waiting` or its `pendingRequestCount` is above 0.
- `t3_pending_request {action:"list", threadId}` returns `{requestIds:[…]}`. Each id is read with `{action:"read", threadId, requestId}`.
- Only the **first** question is used.
- A request that cannot be read or decoded is still a question: the panel shows "Answer needed in T3 Code" with only the **Type in T3 Code** button.
- A pending list that fails with a tool error means "unknown": it is never treated as a permission.
- A question is cleared on the next poll when T3 no longer lists it (answered elsewhere).
- For 4 seconds after a successful Send, pending detection is skipped for that thread so the answered question does not flicker back.

### The panel

- **Row:** lime outline, status line "asks a question", sorted first, chime once when it appears (unless muted).
- **Panel contents:** optional lime tag (the question's `header`, upper-cased), the question text, one radio row per option, then buttons.
- **Buttons:** **Send** (lime when an option is selected, grey and disabled when not; "Sending…" while in flight) and **Type in T3 Code** (jumps to the thread, spec 05).
- **Shown only if answerable:** options and Send appear only when the question is answerable in the widget.

### Answerable rule

A question is answerable in the widget only if the read gives **at most one question**, it is **not multi-select**, and it has **at least one option**. Anything else (several questions, multi-select, free text, no options) shows the prompt text and **Type in T3 Code** only.

### Send

1. Needs a selected option. Read-only mode blocks it: the panel shows "Read-only mode — answer in T3 Code" and nothing is sent.
2. Calls `t3_pending_request {action:"respond", threadId, requestId, answers:{<questionId>: <option label>}}`, with `environmentId` for a thread on a linked machine.
3. **Success:** the selection and panel clear, the question is dropped locally, the thread list refreshes.
4. **Failure:** the panel stays, shows a one-line error (first 120 characters), and keeps the selection. Choosing another option clears the error.

### Shapes the decoder accepts

| Part | Accepted | Evidence |
|---|---|---|
| List | `{requestIds:[…]}` (strings or `{requestId}`/`{id}`); fallbacks `requests`, `pending`, `items` | `requestIds`: Live (M0 L6, empty); fallbacks: assumed |
| Read | `{requestId, questions:[{id, header, question, options:[{label, description}], multiSelect}]}`; also a flat shape and plain string options | **Assumed** (SPEC Q5) |
| Respond | `answers: {<questionId>: <label>}` | **Assumed** |

The shape is isolated in `QuestionCodec` (`Models.swift`) and in the fake, so one edit fixes both.

## T3 data and tools

| Tool | Arguments | Scope (assumed) | Evidence |
|---|---|---|---|
| `t3_pending_request` | `action:"list"`, `threadId` | read | Live: list returns `{requestIds:[]}` and omits approvals |
| `t3_pending_request` | `action:"read"`, `threadId`, `requestId` | read | None |
| `t3_pending_request` | `action:"respond"`, `threadId`, `requestId`, `answers` | operate | None (live notes show `respond` rejects a permission id with "The pending user-input request was not found") |

## Security and privacy

- Question text, header and options render as plain text. No links or markdown, so an agent cannot draw a fake button.
- The answer sent is exactly one of the offered option labels.
- Read-only mode blocks Send locally. It does not reduce the token's scopes (see spec 08).
- Question content stays in memory.

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| QST-01 | A waiting thread with a listed question shows "asks a question" with its prompt and sorts first | `ModelTests.questionAndPermissionDetected`; `StoreTests.orderingAttentionFirstThenRecent` | Fake |
| QST-02 | Selecting an option and Send calls `respond`, closes the panel and clears the selection | `ModelTests.sendAnswerSucceedsAndPanelCloses`; `MCPClientTests.questionReadAndRespondRoundTrip` | Fake |
| QST-03 | A failed Send keeps the panel and the selection with an error; the next poll closes a question answered elsewhere | `ModelTests.sendFailureKeepsPanelAndSelection` | Fake |
| QST-04 | Read-only mode sends nothing and shows an error | `ModelTests.readOnlyModeBlocksSend` | Fake |
| QST-05 | A multi-select question is not answerable in the widget | `HardeningTests.multiSelectFallsBackToTypeInT3` | Fake |
| QST-06 | An unreadable question is a question, not a permission, and Send is a no-op | `HardeningTests.unreadableQuestionIsAQuestionNotAPermission` | Fake |
| QST-07 | An alternate (flat) read shape still decodes and answers | `HardeningTests.alternateQuestionShapeStillDecodesAndAnswers` | Fake |
| QST-08 | A failed pending list never produces a permission | `HardeningTests.failedPendingListIsNotInferredAsPermission` | Fake |
| QST-09 | The list decoder reads `requestIds` and the fallback shapes | `CodecTests.listDecodesLiveAndFallbackShapes` | Fake; `requestIds` also Live |
| QST-10 | A question on a linked machine is read and answered with that machine's `environmentId` | `LiveShapeTests.threadsGroupedByEnvironmentWhenLinkedEnvironmentsAreOn` | Fake |
| QST-11 | The chime plays once for a newly attention-needing thread | `ModelTests.soundPlaysOncePerNewAttentionAndNotWhenMuted` | Fake |
| QST-12 | A real T3 question decodes, and an answer reaches the agent | none | **None** |
| QST-13 | The 4-second post-answer suppression | none | **None** |

## Open questions

- **QST-Q1 (owner: maintainer, needs a live pass):** the real question and `answers` shape (SPEC Q5). Create a throwaway thread that asks one question and read it.
- **QST-Q2:** free-text answers and several questions per request are not supported. Is v1 acceptable?
- **QST-Q3:** does `respond` need `orchestration:operate`, and does the OAuth token have it at the access level the user picks (README advises "approval-required")?

## Sources

`Sources/HuddleCore/{Models (QuestionCodec),HuddleModel,MCPClient}.swift`, `Sources/AgentHuddle/Views.swift` (`QuestionPanel`), `docs/specs/00-prototype.md` §9.5.
