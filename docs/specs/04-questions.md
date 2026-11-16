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
- A request that cannot be read or decoded is still a question: the panel shows "Answer needed in T3 Code" and a hint that the row's ↗ opens it.
- A pending list that fails with a tool error means "unknown": it is never treated as a permission.
- A question is cleared on the next poll when T3 no longer lists it (answered elsewhere).
- For 4 seconds after a successful Send, pending detection is skipped for that thread so the answered question does not flicker back.

### The panel

- **Row:** lime outline, status line "asks a question", sorted first, chime once when it appears (unless muted).
- **Panel contents:** optional lime tag (the question's `header`, upper-cased), the question text, one radio row per option, then buttons.
- **Buttons:** **Send** (lime when an option is selected, grey and disabled when not; "Sending…" while in flight) and **Write answer** (spec 13). **Type in T3 Code** was removed: the row's ↗ opens the thread.
- **Shown only if answerable:** options and Send appear only when the question is answerable in the widget.

### Answerable rule

A single question with **at least one option** is answerable in the widget, multi-select or not. A single question with no options can still be answered with **Write answer** (spec 13). **Several questions in one request** (T3 asks up to four) are answerable when their ids are distinct (the answers are one map keyed by id). Anything else (repeated ids, an unreadable request) shows the prompt and "Answer this one in T3 Code: ↗ opens it."

### Multi-select (asked for by the maintainer)

- **Checkboxes** (square, ticked) instead of round marks, with "Pick one or more" under the question ("Pick one or more, then Next" among several).
- **A tick never moves on:** Send (a single question) or Next / Review answers (among several) is enabled once a box is ticked; unticking every box removes the answer.
- **The answer is one text:** the ticked labels in the order the question lists them, joined with ", " (the form Claude Code's question tool uses). T3 takes any text as an answer: a written answer to a multi-select question was accepted live. Whether T3's own UI joins picks the same way is not confirmed.
- **Write answer** works on a multi-select question too and replaces any ticked boxes.

### Several questions in one request (asked for by the maintainer)

- **One at a time:** the question's tag, "n of N" and one dot per question (lime when answered, ringed when shown; a dot goes to that question), the question, and its options with their descriptions in grey.
- **An option moves on** to the next unanswered question; after the last, to the review.
- **Write answer** on every question: a field replaces the options; **Use this answer** takes the text as that question's answer and moves on; **Back to options** returns. A written answer is shown like a chosen option ("Your answer").
- **Back**, and **Next** (or **Review answers**) once the shown question has an answer.
- **Review:** "Your answers", each question's tag and answer (a line goes back to that question), **Back** and **Send N answers**. Nothing is sent before the review, and Send needs every question answered.
- **Send:** one `respond` with `answers: {<question id>: <label or written text>, …}` for all of them. Success clears the request and shows "N answers sent"; a failure keeps every answer with a one-line error. Read-only mode sends nothing. Answers and drafts stay in memory.

### Send

1. Needs a selected option. Read-only mode blocks it: the panel shows "Read-only mode — answer in T3 Code" and nothing is sent.
2. Calls `t3_pending_request {action:"respond", threadId, requestId, answers:{<questionId>: <option label>}}`, with `environmentId` for a thread on a linked machine.
3. **Success:** the selection and panel clear, the question is dropped locally, the thread list refreshes.
4. **Failure:** the panel stays, shows a one-line error (first 120 characters), and keeps the selection. Choosing another option clears the error.

### Shapes the decoder accepts

| Part | Accepted | Evidence |
|---|---|---|
| List | `{requestIds:[…]}` (strings or `{requestId}`/`{id}`); fallbacks `requests`, `pending`, `items` | `requestIds`: Live (M0 L6, empty); fallbacks: assumed |
| Read | `{requestId, questions:[{id, header, question, options:[{label, description}], multiSelect}]}`; also a flat shape and plain string options | **Live** (a four-question request read through T3's tools; each `id` was the question's text) |
| Respond | `answers: {<questionId>: <label or text>}`, one entry per question | **Live** for the shape (T3 handed the agent exactly this map after the user answered four questions in T3 Code); not yet sent from the panel |

The shape is isolated in `QuestionCodec` (`Models.swift`) and in the fake, so one edit fixes both.

## T3 data and tools

| Tool | Arguments | Scope (assumed) | Evidence |
|---|---|---|---|
| `t3_pending_request` | `action:"list"`, `threadId` | read | Live: list returns `{requestIds:[]}` and omits approvals |
| `t3_pending_request` | `action:"read"`, `threadId`, `requestId` | read | None |
| `t3_pending_request` | `action:"respond"`, `threadId`, `requestId`, `answers` | operate | None (live notes show `respond` rejects a permission id with "The pending user-input request was not found") |

## Security and privacy

- Question text, header and options render as plain text. No links or markdown, so an agent cannot draw a fake button.
- The answer sent is exactly one of the offered option labels, or exactly the text the user wrote (spec 13).
- Read-only mode blocks Send locally. It does not reduce the token's scopes (see spec 08).
- Question content stays in memory.

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| QST-01 | A waiting thread with a listed question shows "asks a question" with its prompt and sorts first | `ModelTests.questionAndPermissionDetected`; `StoreTests.orderingAttentionFirstThenRecent` | Fake |
| QST-02 | Selecting an option and Send calls `respond`, closes the panel and clears the selection | `ModelTests.sendAnswerSucceedsAndPanelCloses`; `MCPClientTests.questionReadAndRespondRoundTrip` | Fake |
| QST-03 | A failed Send keeps the panel and the selection with an error; the next poll closes a question answered elsewhere | `ModelTests.sendFailureKeepsPanelAndSelection` | Fake |
| QST-04 | Read-only mode sends nothing and shows an error | `ModelTests.readOnlyModeBlocksSend` | Fake |
| QST-05 | A multi-select question is answered with checkboxes; the picks go as one text in the question's order; among several questions a tick does not move on | `HardeningTests.multiSelectIsAnsweredWithCheckboxesAsOneText`; `MultiQuestionTests.aMultiSelectQuestionAmongSeveralTicksBoxesAndDoesNotMoveOn`; still 63 | Fake; a written answer to a multi-select question Live |
| QST-06 | An unreadable question is a question, not a permission, and Send is a no-op | `HardeningTests.unreadableQuestionIsAQuestionNotAPermission` | Fake |
| QST-07 | An alternate (flat) read shape still decodes and answers | `HardeningTests.alternateQuestionShapeStillDecodesAndAnswers` | Fake |
| QST-08 | A failed pending list never produces a permission | `HardeningTests.failedPendingListIsNotInferredAsPermission` | Fake |
| QST-10 | Several questions: read with descriptions, an option moves on, a written answer counts, the review shows all, one `respond` sends every answer keyed by id; partial answers send nothing; read-only sends nothing; repeated ids stay in T3 | `MultiQuestionTests`; stills 60–62 | Fake; shapes Live |
| QST-09 | The list decoder reads `requestIds` and the fallback shapes | `CodecTests.listDecodesLiveAndFallbackShapes` | Fake; `requestIds` also Live |
| QST-10 | A question on a linked machine is read and answered with that machine's `environmentId` | `LiveShapeTests.threadsGroupedByEnvironmentWhenLinkedEnvironmentsAreOn` | Fake |
| QST-11 | The chime plays once for a newly attention-needing thread | `ModelTests.soundPlaysOncePerNewAttentionAndNotWhenMuted` | Fake |
| QST-12 | A real T3 question decodes, and an answer reaches the agent | none | **None** |
| QST-13 | The 4-second post-answer suppression | none | **None** |

## Open questions

- **QST-Q1 (partly answered 2026-11-15):** a real Claude question (header, two options, single choice) decoded with the assumed shape, and a written answer through `respond` reached the agent word for word (spec 13 live check). A picked option has not been sent live. A thread in a broader runtime mode than the sign-in refuses answers (spec 13).
- **QST-Q2 (answered):** free-text answers (spec 13), several questions per request and multi-select are supported.
- **QST-Q3:** how T3 Code's own UI joins several picks is not confirmed; the panel sends `"A, B"`.
- **QST-Q3:** does `respond` need `orchestration:operate`, and does the OAuth token have it at the access level the user picks (README advises "approval-required")?

## Sources

`Sources/HuddleCore/{Models (QuestionCodec),HuddleModel,MCPClient}.swift`, `Sources/AgentHuddle/Views.swift` (`QuestionPanel`), `docs/specs/00-prototype.md` §9.5.
