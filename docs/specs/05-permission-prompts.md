# 05 — Permission prompts and jump to T3 Code

**Status:** built · **Evidence:** the `approval_request` item shape was seen live (on a `pi` thread, T3 Code 0.1.9); the panel, detection and jump run only against the fake. The jump was handed to macOS but its landing on the right thread was **not observed**.

## Purpose and user value

- **See what is blocked:** a thread waiting for tool approval is flagged, with the exact tool and command it wants to run.
- **Get to the decision in one click:** **Review in T3 Code** opens that thread. (Allow and Deny exist only through the opt-in inline approvals, specs 06 and 07.)

## Behaviour as built

### Detection

A thread is a permission when all hold:

- its status is `waiting` or `pendingRequestCount` is above 0;
- `t3_pending_request list` succeeded and returned no user questions (approvals are never listed there).

The command text comes from the newest `approval_request` activity item (preferred). If none exists it falls back to the newest unfinished command step as `Bash: <command>`.

### Summary text

- **Tool name:** from the item title `Allow <name>?`, first letter upper-cased ("Allow bash?" becomes "Bash"); otherwise "Tool".
- **Detail:** the item's JSON `text`; the first non-empty of `command`, `path`, `file_path`, `url`. Else the raw text, first 400 characters, else the title.
- **Summary** is `Tool: detail`. The badge needs a head of 24 characters or fewer without spaces, braces, quotes or newlines; otherwise the whole summary is the detail.

### The panel

- **Row:** lime outline, status line "needs permission", sorted first, chime once.
- **Tool badge:** the tool name upper-cased on a lime tag, when a tool name was found.
- **Command:** monospaced plain text, **collapsed to 3 lines**. A **Show full command** / **Show less** toggle appears when the command is over 120 characters or over 3 lines.
- **No command known:** "Waiting for approval in T3 Code".
- **Buttons:** **Review in T3 Code** (jump). Allow / Deny appear only after the opt-in (specs 06, 07). With no opt-in there is no disabled Allow button.
- **Cleared:** when the status leaves `waiting` and the pending count reaches 0 (approved or denied in T3 Code), the flag and panel go on the next poll.
- **Closed thread:** returns when it starts needing a permission (spec 01).

### Jump

- **Action:** the arrow on a row or in the detail top bar, and the panel's Review / Type in T3 Code buttons, hand T3 Code its own deep link with `NSWorkspace.open`: `t3code://threads/<environmentId>/<threadId>`.
- **Link source:** the thread's `link`, keeping T3's percent-encoding. Two formats exist: `https://app.t3.codes/threads/<env>/<id>` (this Mac) and `t3-thread://v2/<env>/<id>` (MCP). If there is no link, the id is built from the thread's environment id and the percent-encoded thread id (colons become `%3A`). With neither, there is no link and the jump fails.
- **Markdown-link quirk:** a **linked machine's** T3 returns `link` as `[Title](t3-thread://v2/<env>/<id>)`, not a bare URL. The app strips it to the bare URL (also `<url>`), keeping the last `](`, so a title with parentheses still works. Without this, a trailing `)` ends up in the thread id.
- **Linked machines:** the deep link carries the linked machine's environment id, so T3 Code routes to that machine's thread.
- **Failure:** if the link cannot be delivered, a toast (4 s) says: Couldn't open "<title>" — pick it in T3 Code. A delivered link shows no toast.
- **No T3 call:** jumping makes no MCP request.

## T3 data and tools

| What | Detail | Evidence |
|---|---|---|
| Approval item | activity item `{type:"approval_request", status:"waiting", title:"Allow bash?", text:"{\n  \"command\": \"pwd\"\n}"}`; `t3_pending_request list` → `{requestIds:[]}`; thread `pendingRequestCount:1` | **Live** (one `pi` thread) |
| Status values on the approval item | `waiting` while pending, `completed` after a decision, `cancelled` after an interrupt | Live |
| Item id | `turn-item:runtime-request:<encodeURIComponent(requestId)>` | Live (used by specs 06, 07) |
| Other providers | Claude, Codex, ACP use the same projection in T3's code | None (only `pi` run) |
| Deep link scheme | `t3code://threads/<env>/<thread>` found in the desktop bundle; macOS resolves `t3code://` to T3 Code | Bundle read and LaunchServices resolution checked; **landing not observed** |
| Link list formats | bare URL on this Mac, markdown on a linked machine | Live (commit `c7eca5f`, README) |

## Security and privacy

- **Plain text only.** The command, tool name and title are rendered with `Text(verbatim:)`, so an agent cannot draw a fake button.
- **Agent text is untrusted:** the deep link is built only from T3's own `link` or from environment and thread ids, never from the command text.
- **The command never leaves memory.**

## Acceptance criteria

| ID | Statement | Tests | Evidence |
|---|---|---|---|
| PRM-01 | A waiting thread with no listed question is a permission (not when T3 0.1.11 lists an awaited background task and there is no approval item or pending request: spec 02), with the exact tool and command from its approval item | `StoreTests.permissionInferredWhenWaitingWithNoListedQuestion`; `RunInfoTests.theApprovalItemGivesTheExactCommandAndIsNotAStep`; `ModelTests.questionAndPermissionDetected` | Fake (item shape Live) |
| PRM-02 | The approval item is a prompt, not a step, and wins over an unfinished command | `RunInfoTests.theApprovalItemGivesTheExactCommandAndIsNotAStep` | Fake |
| PRM-03 | The summary splits into tool badge and command; raw JSON has no tool | `RunInfoTests.permissionPromptSplitsToolAndDetail` | Fake |
| PRM-04 | A permission resolved in T3 Code clears the flag on the next poll | `ModelTests.permissionResolvedElsewhereClearsFlag` | Fake |
| PRM-05 | A failed pending list is never read as a permission | `HardeningTests.failedPendingListIsNotInferredAsPermission` | Fake |
| PRM-06 | The jump hands T3 Code `t3code://threads/<env>/<id>`, makes no T3 call, and shows no toast when delivered | `ModelTests.jumpBuildsTheThreadDeepLinkAndShowsNoToastWhenDelivered` | Fake (stub jumper) |
| PRM-07 | The jump shows the "pick it in T3 Code" toast only when delivery fails | `ModelTests.jumpFallsBackToAHintOnlyWhenDeliveryFails` | Fake |
| PRM-08 | Deep links form from a hosted link, a `t3-thread://` link, a markdown link (including parentheses in the title) and from environment plus id (colons encoded); no link, no environment gives none | `DeepLinkTests` (`fromHostedLinkKeepsT3sEncoding`, `fromThreadLinkScheme`, `fromAMarkdownLinkAsLinkedMachinesReturnThem`, `threadSummaryStoresABareLinkAndEnvironmentFromAMarkdownLink`, `remoteSessionJumpsToACleanDeepLink`, `fallbackFromEnvironmentAndIdEncodesColons`, `noLinkNoEnvironmentMeansNoDeepLink`); `LiveShapeTests.environmentIdParsedFromBothLinkFormats` | Fake; markdown shape Live |
| PRM-09 | The panel collapses a long command to 3 lines with a Show full command toggle; the badge shows the tool | none (view code only; stills in `--snapshot` `03-permission`) | **None** |
| PRM-10 | `NSWorkspace.open` lands on the right thread in T3 Code | none | **None** (README: screen was locked) |
| PRM-11 | A permission on Claude, Codex or ACP threads is detected and shows its command | none | **None** |

## Open questions

- **PRM-Q1 (owner: maintainer):** confirm the jump lands on the right thread, on this Mac and on a linked machine.
- **PRM-Q2:** README and SPEC call the button "In T3 Code"; the app labels it **Review in T3 Code** (`Views.swift:286`). Which is the intended name? Docs should follow the code.
- **PRM-Q3:** README "Permission detection is an inference … Unproven live" is stale: detection prefers the `approval_request` item (live-seen shape), and falls back to the inference only when no item exists. Update README after owner agreement.
- **PRM-Q4:** T3 has no MCP approve option; if it adds one, the opt-in inline approvals could be retired.

## Sources

`Sources/HuddleCore/{Store,HuddleModel,Models}.swift`, `Sources/AgentHuddle/{Views,T3Jumper}.swift`, README "Limitations", `docs/specs/00-prototype.md` §9.4, §9.6, §7.5 (jump partly superseded).

## Added after the security review (pass 2)

- **Allow only after the whole command is visible.** A command over 80 characters, or with more than two lines, or with hidden characters starts collapsed (three lines) and **Allow** stays disabled until **Show full command** is pressed; **Deny** is always available. Tests: `DisplayTextTests.aCommandThatCouldBeClippedMustBeExpandedFirst` (the rule); the button gating itself is UI code with no automated test. Evidence: Fake / rendering only.
- **Hidden characters are shown, not interpreted.** Zero-width, direction-control and control characters in commands, titles, step labels, project names and machine names appear as `⟦U+XXXX⟧` (`DisplayText.clean`). Test: `DisplayTextTests`.

## Secret requests (added after a live report)

- **What T3 sends (seen live, 2026-11-15):** a tool call item with no title and JSON text `{"toolName":"mcp__t3-code__request_secret","input":{"label":…}}`, then a `secret_request` item whose title is the label and whose status is `cancelled` after a timeout (the pending status string was not captured; any status that is not finished, cancelled, failed or expired counts as pending).
- **Panel:** status line "asks for a secret", a SECRET badge, the label (cleaned), "Enter it in T3 Code. Agent Huddle never asks for or keeps a secret.", and a jump button. The thread is not treated as a tool permission while a secret is pending. No field for the value exists.
- **Tests:** `ToolAndSecretTests`. **Evidence:** item shape live; the pending state only against the fake.
- **Same fix, wider:** a titleless tool call is labelled from its JSON (`request_secret: Staging deploy token`) instead of its first line, `{`; `checkpoint` items are not steps; `file_change` items are edits named by file.
