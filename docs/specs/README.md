# Agent Huddle — feature specifications (as built)

These specs describe Agent Huddle **as it is built on `main`**, recovered from the code, tests and documents. They are descriptive: behaviour that no source states stays a candidate or an open question. [`00-prototype.md`](00-prototype.md) is the original product spec the build started from.

- **Product:** a native macOS floating panel and menu-bar item that lists running [T3 Code](https://t3.codes) threads over T3's local MCP endpoint and lets the user answer their questions. Swift and SwiftUI, no third-party dependencies.
- **Where the truth lives:** code and tests win. `docs/specs/00-prototype.md` is the original product spec and is partly superseded.
- **Status at a glance:** [status.md](status.md).

## Specs

| # | Spec | One line |
|---|---|---|
| 01 | [Floating panel and rows](01-panel-and-rows.md) | window, header, machine groups, info line, Close and its return rules, resize |
| 02 | [Thread state model](02-thread-state-model.md) | working, done, background task, subagent, recent window, settled, idle |
| 03 | [Detail view](03-detail-view.md) | info block, expandable steps, output tail, errors as failed steps |
| 04 | [Questions](04-questions.md) | answer a single-choice question in the panel |
| 05 | [Permission prompts and jump](05-permission-prompts.md) | exact command, tool badge, Review in T3 Code, deep links, linked machines |
| 06 | [Inline approvals, this Mac](06-inline-approvals-this-mac.md) | opt-in Allow and Deny over T3's `/ws` |
| 07 | [Inline approvals, other machines](07-inline-approvals-other-machines.md) | opt-in, https only, per-machine credential, discovery, identity check, window |
| 08 | [Connecting to T3](08-connecting-to-t3.md) | OAuth with PKCE, Keychain, loopback guard, read-only mode, contract check |
| 09 | [Linking other machines](09-linking-other-machines.md) | peer links, Labs setting, Tailscale steps |
| 10 | [Menu-bar item](10-menu-bar-item.md) | animated robot with working count, menu items |
| 11 | [Packaging and distribution](11-packaging-and-distribution.md) | build script, icon, About, CI and release, ad-hoc signing |
| 12 | [Cross-cutting rules](12-non-functional-rules.md) | security hard rules, polling, privacy, quality gates |
| 13 | [Write and send](13-write-and-send.md) | written answers, messages to any thread, steer or queue |
| 15 | [Machines](15-machines.md) | connect to T3 on this Mac or any other machine, each through its own MCP; one Machines window |

## How to read a spec

Each spec has the same sections: purpose and user value; behaviour as built; the T3 data and tools it uses; security and privacy; acceptance criteria as testable statements with the covering tests; open questions; sources.

### Evidence labels

| Label | Meaning |
|---|---|
| **Live** | Observed on a real T3 Code 0.1.9 (2026-11-14) during the maintainer's live checks. |
| **Fake** | An automated test in this repository passes against `FakeT3` or as a pure unit test. No real T3 was involved. This is a claim about the app against the fake, not about T3. |
| **None** | No test and no live observation. The statement comes from reading the code or a document. |

A criterion can carry two labels, for example "Fake; shape Live" (the test is against the fake, the data shape was seen live).

### Identifiers

Criteria are numbered per spec: `PNL` panel, `STM` state model, `DET` detail, `QST` questions, `PRM` permission, `AMC` this Mac, `RMT` remote, `CON` connection, `LNK` linking, `MNB` menu bar, `PKG` packaging, `NFR` cross-cutting. Open questions are `<prefix>-Qn`.

Test names are the Swift function names. The suite is the struct in the same file (`swift test --filter <StructName>`).

## Open questions that matter most

Per-spec questions are in each spec. These decide the most:

1. **A live pass is needed for:** a real question and answer (QST-Q1), the jump landing (PRM-Q1), an in-app accept and decline over loopback `ws://` (AMC-Q1), a decision to a separate machine (RMT-Q2), and the real pid-to-bundle peer check (CON-Q2).
2. **Unverified inferences the product relies on:** "waiting on a background task" and "waiting on a subagent" (STM-Q1), `notification` and `error` item shapes (STM-Q2).
