import Foundation
import HuddleCore

/// The demo's story: two synthetic machines, "Mika’s MacBook Pro" (this Mac, `env_local`) and "Mika’s Mac mini" (the linked
/// `env_remote`), with threads on different models. Titles, commands and ids are invented; none of this is real T3 data.
/// The MacBook's fake serves the MCP for both machines; the Mac mini's fake only plays that machine's own `/ws` (decisions).
public enum DemoScenario {
    public typealias T = FakeT3Server.FakeThread
    public static let macBook = "Mika’s MacBook Pro"
    public static let macMini = "Mika’s Mac mini"
    public static let miniEnv = "env_remote"

    // This Mac. The first four are Scenario's main four, so their buddy colours are the same spread (yellow, orange, teal, pink).
    public static let render = Scenario.renderThread
    public static let changelog = Scenario.questionThread
    public static let triage = Scenario.permissionThread
    public static let docs = Scenario.draftThread
    public static let cleanup = "thr_cleanup_4"
    public static let shards = "thr_shards_7"
    public static let shardChild = "thr_shards_7_child"
    // The Mac mini.
    public static let config = "thr_config_loader_3"
    public static let scripts = "thr_build_scripts_6"
    public static let bench = Scenario.remoteApprovalThread
    public static let ciWatch = "thr_ci_watch"

    public static let projects = ["proj_release": "release-tools", "proj_docs": "docs-site", "proj_app": "acme-app", "proj_cli": "cli-tools"]

    /// A command long enough to be collapsed behind "Show full command", still under the 400 characters a request may have.
    public static let longCommand = "find . -name '*.o' -not -path './vendor/*' -mtime +7 -print0 | xargs -0 rm -f && rm -rf build/tmp build/cache dist/staging && npm cache clean --force && echo cleaned"
    public static let benchCommand = "cargo bench --bench parser -- --save-baseline main"
    public static let triageCommand = "gh issue edit 142 --add-label needs-info"

    /// The two fakes. `local` is what the panel connects to; `mini` answers decisions for the Mac mini's own threads.
    public static func makeFakes() -> (local: FakeT3Server, mini: FakeT3Server) {
        var lo = FakeT3Server.Options()
        lo.linkedEnvironments = true
        lo.localEnvironmentLabel = macBook
        lo.linkedEnvironmentLabels = [miniEnv: macMini, buildBoxEnv: "Build box"]
        lo.projectTitles = projects
        lo.pairingCode = "demo-code-macbook"
        var mo = FakeT3Server.Options()
        mo.environmentId = miniEnv; mo.environmentLabel = macMini; mo.pairingCode = "demo-code-macmini"
        mo.localEnvironmentLabel = macMini; mo.projectTitles = projects
        let local = FakeT3Server(options: lo), mini = FakeT3Server(options: mo)
        mini.decisionObserver = { [weak local] t, r, d in local?.mirrorDecision(threadId: t, requestId: r, decision: d) }   // the MacBook lists that thread too
        return (local, mini)
    }

    /// What is running when the video starts: two threads per machine, nothing asking for anything. `only` keeps just those thread ids.
    public static func start(_ s: FakeT3Server, only: Set<String>? = nil) {
        func put(_ t: T) { if only?.contains(t.id) ?? true { s.add(t) } }
        put(T(id: render, title: "Render release notes", status: "running", items: [
            Scenario.cmd(0, "cat RELEASES.md", output: "v2.4.0 — settings sync, faster search\nv2.3.1 — crash fix"),
            Scenario.tool(1, "Write notes-draft.md"),
            Scenario.cmd(2, "node scripts/render-notes.js --format html", output: "wrote out/notes.html (3 pages)"),
            Scenario.cmd(3, "npm test -- notes", output: "FAIL notes.render\n  expected 3 headings, found 2\n1 failing", status: "failed"),
            Scenario.cmd(4, "node scripts/render-notes.js --format pdf", output: "rendering page 95/139…", status: "running"),
        ], branch: "main", runningFor: 252, projectId: "proj_release"))
        put(T(id: docs, title: "Update the docs site", status: "running", items: [
            Scenario.tool(0, "Read docs/index.md"), Scenario.tool(1, "Write docs/guide/install.md", status: "running"),
        ], model: "claude-opus-5-5", executedModel: "claude-sonnet-5-5", branch: "feat/docs-refresh", runningFor: 723, projectId: "proj_docs"))
        put(T(id: config, title: "Refactor the config loader", status: "running", items: [
            Scenario.cmd(0, "rg -n \"load_config\" src", output: "src/config.rs:41\nsrc/main.rs:12"),
            Scenario.tool(1, "Read src/config.rs"), Scenario.tool(2, "Edit src/config.rs", status: "running"),
        ], environmentId: miniEnv, providerInstanceId: "gemini", model: "gemini-3-pro", branch: "feat/config", runningFor: 318, projectId: "proj_cli"))
        put(T(id: scripts, title: "Migrate the build scripts", status: "running", items: [
            Scenario.cmd(0, "ls scripts", output: "build.sh\nrelease.sh\nlint.sh"),
            Scenario.cmd(1, "bash scripts/lint.sh", status: "running"),
        ], environmentId: miniEnv, providerInstanceId: "grok", model: "grok-code-fast-1", runningFor: 96, projectId: "proj_cli"))
    }

    public static let buildBoxEnv = "env_buildbox"
    /// A machine only linked in this Mac's T3 (spec 15: read-only rows): a nightly release that asks a question.
    public static func addBuildBox(_ s: FakeT3Server) {
        s.add(T(id: "thr_nightly", title: "Nightly release", status: "waiting", items: [Scenario.tool(0, "Read RELEASES.md")], questions: [
            .init(requestId: "req_nightly", header: "SHIP", question: "Ship the nightly now?", options: ["Ship", "Wait"]),
        ], environmentId: buildBoxEnv, runningFor: 300, projectId: "proj_release"))
    }

    /// A thread asks a question (a different model, on the pi harness).
    public static func addQuestion(_ s: FakeT3Server) {
        s.add(T(id: changelog, title: "Draft changelog", status: "waiting", items: [
            Scenario.tool(0, "Read RELEASES.md"),
            .init(position: 1, itemId: "item_1", type: "reasoning", status: "completed", title: nil, text: "thinking…"),
        ], questions: [
            .init(requestId: "req_tone", header: "TONE", question: "Which tone should the changelog use?", options: ["Concise", "Friendly", "Formal"]),
        ], providerInstanceId: "pi", model: "ollama/qwen3.8-pi:latest", runningFor: 42, projectId: "proj_release"))
    }

    /// A request with three questions at once (spec 04): a plan the agent wants settled before it writes.
    public static func addMultiQuestion(_ s: FakeT3Server) {
        s.update(changelog) { t in
            t.questions = [.init(requestId: "req_plan", header: "Scope", question: "What goes into the 2.4 notes?",
                                 options: ["Features and fixes", "Everything, grouped", "Highlights only"],
                                 more: [
                .init(id: "q1", header: "Breaking", question: "How should breaking changes be shown?",
                      options: [("Own section first (Recommended)", "Readers see them before anything else."),
                                ("Inline, marked", "Kept next to the feature they belong to.")]),
                .init(id: "q2", header: "Credits", question: "Thank outside contributors by name?",
                      options: [("Yes, at the end (Recommended)", "One line per person, linked to the PR."),
                                ("No", "Keep the notes short.")]),
            ])]
        }
    }

    /// The answer was sent: the agent carries on.
    public static func continueAfterAnswer(_ s: FakeT3Server) {
        s.update(changelog) { t in
            t.items.append(Scenario.cmd(2, "git log --oneline v2.3.1..HEAD", output: "a1b2c3d settings sync\n9f8e7d6 faster search", status: "running"))
        }
    }

    /// Waiting states: both start out working, then T3 reports them `completed` while the agent waits.
    public static func addWaiters(_ s: FakeT3Server) {
        s.add(T(id: shards, title: "Run the test shards", status: "running", items: [
            Scenario.cmd(0, "npm run test:shards -- --count 4", output: "shard 1/4 ok"),
        ], branch: "main", runningFor: 61, projectId: "proj_app"))
        s.add(T(id: ciWatch, title: "Watch CI on the release branch", status: "running", items: [
            Scenario.cmd(0, "gh run watch 8812", output: "queued"),
        ], environmentId: miniEnv, branch: "release/2.4", runningFor: 120, projectId: "proj_cli"))
    }
    public static func startWaiting(_ s: FakeT3Server) {
        s.update(ciWatch) { t in
            t.items.append(.init(position: 1, itemId: "item_bg", type: "dynamic_tool", status: "completed", title: "Wait for background task",
                                 text: "{\"toolName\":\"t3_background_wait\",\"input\":{\"taskId\":\"ci-8812\"}}"))
            t.status = "completed"
        }
        s.add(T(id: shardChild, title: "Shard 3 of 4", status: "running", parentThreadId: shards, runningFor: 30, projectId: "proj_app"))
        s.update(shards) { $0.status = "completed" }
    }
    public static func finishWaiting(_ s: FakeT3Server) {
        s.update(ciWatch) { t in
            t.items.append(.init(position: 2, itemId: "item_note", type: "notification", status: "completed", title: nil, text: "CI finished: success"))
            t.items.append(.init(position: 3, itemId: "item_msg", type: "assistant_message", status: "completed", title: nil, text: "CI is green on release/2.4."))
        }
        s.update(shardChild) { $0.status = "completed" }
    }

    /// Needs permission, on this Mac (a codex model).
    public static func addTriagePermission(_ s: FakeT3Server) {
        s.add(T(id: triage, title: "Triage open issues", status: "waiting", items: [
            Scenario.cmd(0, "gh issue list --state open --limit 50", output: "142  Crash when opening settings\n143  Search is slow on large repos"),
            Scenario.cmd(1, triageCommand, status: "running"),
            Scenario.approval(2, requestId: Scenario.permissionRequestId, command: triageCommand),
        ], permissionPending: true, providerInstanceId: "codex", model: "gpt-6.1-sol", runningFor: 125, projectId: "proj_app"))
    }

    /// The agent asked for a secret (T3's `request_secret`): a tool call with no title, then a `secret_request` item that is still pending.
    public static let secretThread = "thr_secret_5"
    public static func addSecretRequest(_ s: FakeT3Server) {
        s.add(T(id: secretThread, title: "Deploy the staging site", status: "waiting", items: [
            Scenario.cmd(0, "npm run build", output: "built in 41s"),
            Scenario.Item(position: 1, itemId: "item_secret_call", type: "dynamic_tool", status: "completed", title: nil,
                 text: "{\n  \"toolName\": \"mcp__t3-code__request_secret\",\n  \"input\": {\n    \"label\": \"Staging deploy token\",\n    \"reason\": \"The deploy script needs it\"\n  }\n}"),
            Scenario.Item(position: 2, itemId: "item_secret_req", type: "secret_request", status: "pending", title: "Staging deploy token",
                 text: "Waiting for the user: Staging deploy token"),
            Scenario.Item(position: 3, itemId: "item_checkpoint", type: "checkpoint", status: "completed", title: nil, text: "[\n  {\"path\": \"deploy.sh\", \"kind\": \"modified\"}\n]"),
        ], projectId: "proj_app"))
    }

    /// Needs permission with a long command (a grok model).
    public static let cleanupRequestId = "runtime-request:fake:provider-turn%3Aclean:native-request:51ac90de"
    public static func addCleanupPermission(_ s: FakeT3Server) {
        s.add(T(id: cleanup, title: "Clean up build artifacts", status: "waiting", items: [
            Scenario.cmd(0, "du -sh build dist", output: "412M\tbuild\n88M\tdist"),
            Scenario.cmd(1, longCommand, status: "running"),
            Scenario.approval(2, requestId: cleanupRequestId, command: longCommand),
        ], permissionPending: true, providerInstanceId: "grok", model: "grok-code-fast-1", runningFor: 74, projectId: "proj_app"))
    }

    /// Needs permission on the Mac mini. Added to both fakes: the MacBook's lists it, the Mac mini's decides it.
    public static func addBenchPermission(_ fakes: (local: FakeT3Server, mini: FakeT3Server)) {
        for s in [fakes.local, fakes.mini] {
            s.add(T(id: bench, title: "Benchmark the parser", status: "waiting", items: [
                Scenario.cmd(0, "cargo build --release", output: "Finished release in 41s"),
                Scenario.cmd(1, benchCommand, status: "running"),
                Scenario.approval(2, requestId: Scenario.remoteRequestId, command: benchCommand),
            ], permissionPending: true, environmentId: miniEnv, providerInstanceId: "codex", model: "gpt-6.1-sol", runningFor: 80, projectId: "proj_cli"))
        }
    }
}
