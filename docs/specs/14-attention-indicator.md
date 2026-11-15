# 14 — Attention indicator

**Status:** proposed, not built (UI mockup first; built only after the maintainer approves) · **Evidence:** none.

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

- **Menu item "Show the panel when something needs me"** (checkmark, off by default): when the panel was hidden with × and a new thread starts needing you, the panel comes back, without taking focus from the app you are in.

## Security and privacy

- Nothing new is read or sent: the count comes from the state the panel already has. Titles stay plain text (spec 12).

## Acceptance criteria (proposed)

| ID | Statement | Tests |
|---|---|---|
| ATT-01 | The menu bar shows the attention count, and only while it is above 0 | new (count logic) |
| ATT-02 | The header pill shows in expanded, collapsed and detail views, and its click reaches the first row | new + snapshots |
| ATT-03 | Closed threads do not count; linked-only ones do | new |
| ATT-04 | With "Show the panel when something needs me" on, a new attention item brings a hidden panel back once, without activating the app | new (model) + by hand |

## Open questions

- **ATT-Q1:** which menu-bar variant (mockup A, B or C)?
- **ATT-Q2:** should "Show the panel when something needs me" exist, and be on or off by default?

## Sources

`docs/specs/10-menu-bar-item.md`, `01-panel-and-rows.md`, `02-thread-state-model.md`.
