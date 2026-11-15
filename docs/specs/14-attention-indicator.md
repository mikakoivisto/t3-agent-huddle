# 14 — Attention indicator

**Status:** built (menu-bar option A, header pill D–F, bring-back G off by default, plus a Settings window; all approved from mockups) · **Evidence:** `AttentionTests` against the fake; stills 50–55 (`--snapshot`). The menu-bar badge and the floating Settings window have not been looked at by hand.

## Purpose and user value

- **Notice when you are needed:** a thread that asks a question, needs permission or asks for a secret should be visible even when the panel is hidden (×), collapsed, scrolled, covered by another window, or showing another thread's detail.
- **Today:** such a row is outlined in lime, sorted first and chimes once, which only helps if the panel is open and in view. The menu-bar robot counts working threads and says nothing about attention.

## What counts as "needs you"

The rows in `attention` `.needsPermission`, `.asksQuestion` or `.needsSecret` (spec 02), visible (not closed), on any machine, including read-only linked ones (they still need you, in T3 Code). The count is `HuddleState.attentionCount`.

## Behaviour (proposed; pick options in the mockup)

### Menu bar

- **Badge:** while the count is above 0, an orange badge with the count sits next to the robot. Orange, not lime: lime cannot be read on a light menu bar, and the robot itself must stay a template image so macOS can tint it.
- **The working count** moves to the tooltip while the badge shows ("2 need you · 3 running"); the robot still walks while threads work.
- **Reduce Motion:** no change; the badge never animates.

### Panel

- **Header pill:** "2 need you" (orange) beside the title, in the expanded and the collapsed header. A click expands the panel if collapsed, goes back to the list if a detail is open, scrolls to the first such row and flashes its outline once.
- **Collapsed header:** the pill plus up to three small buddies of the threads that need you.
- **Detail view:** the top bar shows the pill when another thread needs you.

### Optional: bring the panel back

- **Setting "Show the panel when something needs me"** (Settings → General, off by default): when the panel was hidden with × and a new thread starts needing you, the panel comes back, without taking focus from the app you are in.

## Security and privacy

- Nothing new is read or sent: the count comes from the state the panel already has. Titles stay plain text (spec 12).

### Settings window (approved with this spec)

Menu bar → **Settings… (⌘,)**: tabs **General** (Attention: Show the panel when something needs me, Chime when something needs me; Answering: Read-only mode, Close also settles finished threads in T3; Window: Keep this window on top) and **Machines** (the former Machines window, spec 15). On top by default. The menu keeps Show / Hide, Settings…, About and Quit. The panel's speaker button and "Chime" are one setting. "Allow / Deny" is now **Approve commands from the panel**, and "Answers & messages" is **Connected**; both are lines in each machine's row, and the approvals setup opens in place (approved from a mockup), so no separate window opens.

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| ATT-01 | The count is the visible questions, permissions and secret requests; the tooltip gives both numbers | `AttentionTests.theCountIsQuestionsPermissionsAndSecretsThatAreShown`, `theTooltipSaysBothNumbers` | Fake |
| ATT-02 | The header pill opens the list (expands, leaves a detail) and goes to the first thread that needs you, flashing it once; in a detail it points to another one | `thePillOpensTheListAndGoesToTheFirstThreadThatNeedsYou`, `inAThreadThatNeedsYouThePillPointsToAnotherOne`; stills 51–53 | Fake |
| ATT-03 | Closed threads do not count | `theCountIsQuestionsPermissionsAndSecretsThatAreShown` | Fake |
| ATT-04 | With "Show the panel when something needs me" on, a new request brings a hidden panel back once; off by default | `aHiddenPanelComesBackForANewRequestOnlyWhenTurnedOn` | Fake; focus not checked by hand |
| ATT-05 | Settings persist; a preferences file from an earlier version loads with the defaults; Chime and the speaker button are one setting | `settingsPersistAndAnOlderPreferencesFileStillLoads` | Fake |

## Open questions

- Decided: menu-bar variant A (orange count); "Show the panel when something needs me" exists, off by default.

## Sources

`docs/specs/10-menu-bar-item.md`, `01-panel-and-rows.md`, `02-thread-state-model.md`.
