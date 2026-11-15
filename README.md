# Agent Huddle

A small floating macOS panel and menu-bar item that shows what your [T3 Code](https://t3.codes) agents are doing, on this Mac and on other machines you have linked: which threads are working, their steps and terminal output, and any question, permission request or secret request waiting for you.

[![Agent Huddle demo: threads on two machines, a question, details](demo/agent-huddle-preview.gif)](demo/agent-huddle-demo.mp4)

*Click for the full 92-second video. Made from a fake T3; [more screenshots](demo/).*

- **Every running thread in one place**, grouped by machine, with steps, run time, model and project.
- **Answer a question** an agent asks without leaving what you are doing, by picking an option or writing your own answer.
- **Message any thread**: queue a message for the next turn, or **steer** a running one now.
- **See exactly what an agent wants to run**, and (optionally) **Allow or Deny it** from the panel, for threads on this Mac and on other machines.
- **A menu-bar robot** that walks while threads are working and counts them.
- **Jump straight to a thread** in T3 Code, resize the panel, close finished threads.

> **Status: working prototype, not published.** It signs in to a real T3 Code and has been used live on one Mac and one linked Mac. Parts of it have only been exercised against a fake T3 server; [`docs/specs/status.md`](docs/specs/status.md) says which. Apple silicon, macOS 14 or later.

## Quick start

1. Get the app (build it with `scripts/build-app.sh`, or take the zip from a release) and open it: [Install and connect](docs/install.md). It is ad-hoc signed, so macOS needs one extra step the first time.
2. Click **Connect to T3 Code** and approve the sign-in in T3.
3. Optional: see threads from your other machines: [Show threads from other machines](docs/other-machines.md).
4. Optional: Allow / Deny in the panel: [Inline approvals](docs/inline-approvals.md).

## Documentation

| | |
|---|---|
| [Install and connect](docs/install.md) | Install, first launch, signing in to T3 Code, revoking |
| [Using the panel](docs/using.md) | What every row, state and control means |
| [Other machines](docs/other-machines.md) | Linking machines, Tailscale setup |
| [Inline approvals](docs/inline-approvals.md) | Allow / Deny in the panel, on this Mac and on other machines |
| [Limitations](docs/limitations.md) | What it does not do, what is inferred, what is unverified |
| [Development](docs/development.md) | Build, test, run against the fake server, live checks, CI and releases, code layout |
| [Feature specs](docs/specs/) | One spec per feature as built; [`00-prototype.md`](docs/specs/00-prototype.md) is the original product spec |
| [Demo](demo/) | A video and screenshots of every feature, made from a fake T3 |

## License

[MIT](LICENSE), © 2026 Mika Koivisto. Independent project, not affiliated with T3 Tools.
