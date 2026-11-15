# 10 — Menu-bar item

**Status:** built · **Evidence:** the count logic runs against the fake; the menu, the icon drawing, the animation and the About panel were never driven by a test.

## Purpose and user value

- **Always reachable:** the app has no Dock icon. The menu-bar item brings the panel back after ×, quits the app, and holds the settings.
- **Glance:** an animated robot with the number of working threads, with the panel hidden.

## Behaviour as built

### The icon

- **Glyph:** an 18 pt template image (so macOS tints it for light, dark and highlighted states): a rounded square with two eyes and a mouth cut out, and two feet.
- **Idle** (no working visible thread): a still glyph with no number, square item width, tooltip "Agent Huddle" (set when the count returns to 0; none at launch, because the tooltip is only written when the count changes).
- **Working** (at least one): the item widens, shows `" N"` in a monospaced-digit 12 pt semibold font, tooltip "N running", and animates four frames at 0.25 s: the body hops on odd frames, the feet alternate, the eyes look side to side.
- **Reduce Motion:** with the system setting on, the first frame is shown and no timer runs.
- **N** counts visible (not closed) sessions that are working: T3-active, waiting on a subagent, or waiting on a background task (spec 02). It differs from the header count, which counts every visible row including done ones.

### The menu

In order:

1. **Show / Hide Agent Huddle:** toggles the panel for this launch. The label does not change.
2. separator
3. **Read-only mode (no answering):** checkmark; persisted. Blocks Send, Allow, Deny and settle (spec 08).
4. **Close also settles finished threads in T3:** checkmark; persisted; off by default (spec 01).
5. **Inline approvals…:** opens the Inline approvals window (specs 06, 07).
6. separator
7. **About Agent Huddle:** the standard About panel with the app name, copyright "© 2026 Mika Koivisto — MIT License", a short description ("independent project, not affiliated with or endorsed by T3 Tools") and the full MIT licence text as credits.
8. **Quit Agent Huddle** (⌘Q).

Checkmarks are refreshed each time the menu opens.

### Removed items

The menu has no "Link other T3 machines…" item (removed in commit `da19dd1`) and none of the earlier per-machine approval items (replaced by the window).

## T3 data and tools

None directly. The count derives from the same polling as the panel (spec 02).

## Security and privacy

- The About panel and menu contain no thread content.
- The toggles persist only booleans (spec 12).

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| MNB-01 | A working row counts toward the menu-bar number; a hidden row does not | none directly; counted from `HuddleState.visible` and `Session.isWorking` (tested in `StoreTests.waitingOnABackgroundTaskCountsAsWorkingEvenThoughT3SaysCompleted`, `RunInfoTests.aWorkingSubagentKeepsACompletedParentWorking`, `StoreTests.closeHidesAndReappearsOnNewAttention`) | Fake for the inputs; **None** for the menu-bar view |
| MNB-02 | Read-only and Close-also-settles persist across a restart | `ModelTests.hiddenIdsAndTogglesPersistUnderInjectedPrefsDir` (mute, collapsed, ids); `StoreTests.preferencesRoundTripUnderInjectedDirectory` | Fake (`readOnly` and `closeSettles` fields round-trip through `Preferences`, not asserted individually) |
| MNB-03 | Show / Hide brings the panel back after × | none | **None** |
| MNB-04 | The menu items and their order | none (`--snapshot` renders `12-menu-bar-frames` for the icon only) | **None** |
| MNB-05 | The animation runs only while threads work and respects Reduce Motion | none | **None** |
| MNB-06 | About shows the MIT licence | none | **None** |

## Open questions

- **MNB-Q1 (owner: maintainer):** SPEC Q11 proposed a minimal menu (show/hide, quit) and wanted confirmation; the menu now has five more items. Confirm.
- **MNB-Q2:** the Quit item is the only way to stop the app. Start at login (SPEC Q13) stays unprovided by design; the README tells the user to add it by hand.
- **MNB-Q3:** `StatusItem.swift:5` still describes the item as "show/hide and quit". Update the comment.

## Sources

`Sources/AgentHuddle/{StatusItem,About}.swift`, `Sources/HuddleCore/HuddleModel.swift`, `docs/specs/00-prototype.md` Q8, Q11.
