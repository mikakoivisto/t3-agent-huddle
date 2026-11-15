import Foundation
import HuddleCore

/// Synthetic scenarios. Titles, commands and ids are invented for the demo; none of this is real T3 data.
public enum Scenario {
    public typealias T = FakeT3Server.FakeThread
    public typealias Item = FakeT3Server.FakeItem

    public static func cmd(_ pos: Int, _ command: String, output: String = "", status: String = "completed") -> Item {
        Item(position: pos, itemId: "item_\(pos)", type: "command_execution", status: status,
             title: nil, text: "$ \(command)" + (output.isEmpty ? "" : "\n\(output)"))
    }
    public static func tool(_ pos: Int, _ title: String, status: String = "completed") -> Item {
        Item(position: pos, itemId: "item_\(pos)", type: "dynamic_tool", status: status, title: title, text: "")
    }

    /// Live shape: T3's own request ids contain colons and `%`-escapes; the item id is `turn-item:runtime-request:` + encodeURIComponent(id).
    public static let permissionRequestId = "runtime-request:fake:provider-turn%3Aabc:native-request:0c19ab3d"
    public static func approval(_ pos: Int, requestId: String, command: String, status: String = "waiting") -> Item {
        Item(position: pos, itemId: "turn-item:runtime-request:" + FakeT3Server.encodeURIComponent(requestId), type: "approval_request",
             status: status, title: "Allow bash?", text: "{\n  \"command\": \(JSON.string(command).text())\n}")
    }

    public static let renderThread = "thr_release_notes"
    public static let questionThread = "thr_changelog"
    public static let permissionThread = "thr_triage"
    public static let draftThread = "thr_docs_site"
    /// A permission request on a linked machine ("Studio Mac", `env_remote`). It is added to the local fake (what the MCP lists)
    /// and to the second fake that plays that machine (what its own `/ws` decides).
    public static let remoteApprovalThread = "thr_bench_parser"
    public static let remoteRequestId = "runtime-request:fake:provider-turn%3Aremote:native-request:7f31c2aa"
    public static func addRemoteApproval(_ s: FakeT3Server) {
        s.add(T(id: remoteApprovalThread, title: "Benchmark the parser", status: "waiting", items: [
            cmd(0, "ls out", output: "a.mp4"),
            cmd(1, "cargo bench --bench parser", status: "running"),
            approval(2, requestId: remoteRequestId, command: "cargo bench --bench parser"),
        ], permissionPending: true, environmentId: "env_remote", providerInstanceId: "codex", model: "gpt-6.1-sol", runningFor: 80))
    }

    /// Four active threads (one working, one asking a question, one needing permission, one on another model), plus noise a real T3 returns:
    /// an idle thread, a settled finished thread and a subagent child (all must stay out of the huddle).
    public static func populate(_ s: FakeT3Server) {
        s.add(T(id: renderThread, title: "Render release notes", status: "running", items: [
            cmd(0, "cat RELEASES.md", output: "…"),
            tool(1, "Write style-sheet.md"),
            cmd(2, "node scripts/render-notes.js --format html", output: "done"),
            cmd(3, "node scripts/render-notes.js --format pdf", output: "rendering page 95/139…", status: "running"),
        ], branch: "main", runningFor: 252))
        s.add(T(id: questionThread, title: "Draft changelog", status: "waiting", items: [
            tool(0, "Read transcript.md"),
            Item(position: 1, itemId: "item_1", type: "reasoning", status: "completed", title: nil, text: "thinking…"),
        ], questions: [
            .init(requestId: "req_tone", header: "TONE", question: "Which tone should the changelog use?",
                  options: ["Concise", "Friendly", "Formal"]),
        ], providerInstanceId: "pi", model: "ollama/qwen3.8-pi:latest", runningFor: 42))
        s.add(T(id: permissionThread, title: "Triage open issues", status: "waiting", items: [
            cmd(0, "ls videos | wc -l", output: "140"),
            cmd(1, "gh issue edit 142 --add-label needs-info", status: "running"),
            approval(2, requestId: permissionRequestId, command: "gh issue edit 142 --add-label needs-info"),
        ], permissionPending: true, providerInstanceId: "codex", model: "gpt-6.1-sol", runningFor: 125))
        s.add(T(id: draftThread, title: "Update the docs site", status: "running", items: [
            tool(0, "Read notes.md"), tool(1, "Write draft.md", status: "running"),
        ], model: "claude-opus-5-5", executedModel: "claude-sonnet-5-5", branch: "feat/draft", runningFor: 723))
        s.add(T(id: "thr_idle", title: "Old idle thread", status: "idle"))
        s.add(T(id: "thr_done_settled", title: "Finished and settled", status: "completed", settled: true))
        s.add(T(id: "thr_child", title: "Subagent of Render release notes", status: "running", parentThreadId: renderThread))
    }

    /// Appends the next "rendering page n/139…" line to the running command (append-only, like real output).
    public static func advanceRender(_ s: FakeT3Server) {
        s.update(renderThread) { t in
            guard let i = t.items.lastIndex(where: { $0.status == "running" && $0.type == "command_execution" }) else { return }
            let last = t.items[i].text.components(separatedBy: "\n").last ?? ""
            let cur = Int(last.components(separatedBy: "page ").last?.components(separatedBy: "/").first ?? "95") ?? 95
            let next = min(cur + 4, 139)
            guard next != cur else { return }
            t.items[i].text += "\nrendering page \(next)/139…"
            if next == 139 { t.items[i].status = "completed" }
        }
    }
}

extension FakeT3Server.FakeThread {
    public init(id: String, title: String, status: String, parentThreadId: String? = nil, settled: Bool = false,
                items: [FakeT3Server.FakeItem] = [], questions: [FakeT3Server.FakeQuestion] = [],
                permissionPending: Bool = false, environmentId: String = "env_local",
                providerInstanceId: String = "claudeAgent", model: String = "claude-sonnet-5-5", executedModel: String? = nil,
                branch: String? = nil, runningFor: TimeInterval = 60, projectId: String = "proj_demo") {
        self.init(id: id, projectId: projectId, title: title, status: status, parentThreadId: parentThreadId,
                  settled: settled, items: items, questions: questions, permissionPending: permissionPending,
                  updatedAt: FakeT3Server.iso(Date()), environmentId: environmentId,
                  providerInstanceId: providerInstanceId, model: model, executedModel: executedModel, branch: branch, runningFor: runningFor)
    }
}
