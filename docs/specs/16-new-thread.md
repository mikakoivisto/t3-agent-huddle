# 16 — Start a new thread from the panel

**Status:** built · **Evidence:** `NewThreadTests` against the fake; stills 56–59. **Not run against the real T3 yet** (a live check would start a real throwaway thread and was not allowed in this session): the `t3_thread_launch` argument shapes (`scratch`, `workspaceStrategy`) come from T3's published schema only. The arguments come from T3's published `t3_thread_launch` schema: `title` (required), `message`, `projectId` or `scratch`, `environmentId`, `modelSelection` (`instanceId`, `model`), `runtimeMode` (`approval-required`, `auto-accept-edits`, `auto`, `full-access`, never broader than the caller's), `interactionMode` (`default`, `plan`), `workspaceStrategy` (`root`, `worktree` from a base, `existing_worktree`), `clientRequestId`.

## Purpose and user value

- **Start work without opening T3 Code:** a "+" in the panel header opens a small composer: pick the machine and project, type the task, Start. The new thread shows up in the list like any other.

## Decisions this spec needs from the maintainer

| # | Decision | Recommendation |
|---|---|---|
| N1 | Allow `t3_thread_launch` (today forbidden) and the read-only `t3_project_list`. | Allow both, launch only from the Start button, one `clientRequestId` per start so a double click starts one thread. Never `t3_thread_interrupt`. |
| N2 | Where the composer opens. | Under the header, above the list, like the message composer; ⤢ opens the same pop-out editor for a long task. |
| N3 | Defaults. | **Configurable in Settings → General → New threads**: Machine (last used, or one machine), Project (last used on that machine, or Scratch), Model (T3's default, or one model), Mode (Auto by default), Workspace (project checkout by default), Plan first (off). |
| N4 | Title. | Taken from the first line of the task (60 characters); editable in Options. |

## Behaviour

- **"+" in the header** (and ⌘N while the panel is key) opens the composer; it is hidden in read-only mode and when no connected machine offers `t3_thread_launch`.
- **Machine:** connected machines only (this Mac and machines connected directly, spec 15); linked-only machines cannot be launched on.
- **Project:** that machine's projects (`t3_project_list`), recent first, plus **Scratch** (no project).
- **Options** (folded by default): Model, Mode (`approval-required` · `auto-accept-edits` · `auto`; `full-access` only if the sign-in allows it), Workspace (project checkout · new worktree from the default branch), Plan first (`interactionMode: plan`), Title.
- **Start:** one `t3_thread_launch`; the composer closes, the new row appears at the top with a lime toast "Started", and ↗ opens it in T3 Code. A refusal (mode too broad, no such project) stays in the composer in plain words with the text kept.
- **Drafts** stay in memory, like messages (spec 13).

## As built

- **Header:** "+" next to the title (⌘N), lime "×" while the composer is open; also shown when collapsed (a click expands the panel); hidden in read-only mode, or when no connected machine offers `t3_thread_launch`.
- **Composer:** machine and project chips (menus), the task field (grows to 6 lines; ⤢ opens a "New thread" window with the same draft), Start / Options / Cancel. Options: Model (T3 default or the catalog), Mode (Approval · Accept edits · Auto; a mode the model's provider does not allow is greyed and never sent), Workspace (project checkout · new worktree; Scratch has none), Plan first, Title (placeholder: the first line).
- **Settings → General → New threads:** Machine (Last used or one machine), Project (Last used on that machine · Scratch), Model, Mode, Workspace, Plan first.
- **After Start:** the composer closes, the list refreshes and the new row carries "Started on <machine>".

## Security and privacy

- Typed by the user, sent on a click (spec 13's rule); nothing starts a thread from polling or from agent text.
- The mode is capped by T3 itself (`runtime_mode_escalation_denied`); the app also never offers a mode broader than its sign-in.
- New tools: `t3_thread_launch` (Start only) and `t3_project_list` (read). The allowed-tools test and AGENTS.md change with them.

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| NEW-01 | Start sends one `t3_thread_launch` with the title from the first line, the task, the project, Auto, the project checkout; the new thread is listed with a toast; last machine and project are remembered | `NewThreadTests.startingOnThisMacSendsOneLaunchWithTheChosenProject` | Fake |
| NEW-02 | Model, mode, worktree, plan and title reach T3; Scratch sends no project and no workspace | `optionsReachT3`, `scratchHasNoProject` | Fake |
| NEW-03 | A double click starts one thread; polling never starts one | `aRepeatedStartIsOneThread`, `pollingNeverStartsAThread` | Fake |
| NEW-04 | Read-only mode, or no `t3_thread_launch`, means no "+" and nothing started | `readOnlyStartsNothing`, `withoutTheToolThereIsNoPlus` | Fake |
| NEW-05 | A refusal stays in the composer in plain words, text kept | `aRefusalStaysInTheComposerInPlainWords` | Fake |
| NEW-06 | Models come from the catalog (disabled providers left out) and limit the modes | `modelsComeFromTheCatalogAndLimitTheModes` | Fake; catalog shape **Live** (read through this session's T3 tools) |
| NEW-07 | Linked-only machines cannot be started on; a connected machine is started on through its own T3 | `linkedOnlyMachinesCannotBeStartedOnButConnectedOnesCan` | Fake |
| NEW-10 | The "+" shows on a collapsed panel and opening the composer expands it | `plusOnACollapsedPanelExpandsIt` | Fake |
| NEW-08 | Defaults persist and an older preferences file loads | `defaultsPersistAndAnOlderPreferencesFileStillLoads` | Fake |
| NEW-09 | A real start on T3 (Scratch and a project, checkout and worktree) | none | **None** |

## Open questions

- **NEW-Q1 (answered):** T3's `orchestrator_capabilities` lists each provider's models, labels and allowed runtime modes, and which providers are disabled. Without that tool the model choice is only "T3 default".
- **NEW-Q2:** attachments (files, screenshots): out of scope for now.
