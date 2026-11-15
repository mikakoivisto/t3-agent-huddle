import Testing
import Foundation
@testable import HuddleCore
import FakeT3

/// Start a new thread from the panel (spec 16), against the fake.
@Suite("New thread (spec 16)")
@MainActor
struct NewThreadTests {
    func setUp(_ change: ((inout FakeT3Server.Options) -> Void)? = nil, prefs: PreferencesStore? = nil) async throws -> (FakeT3Server, HuddleModel) {
        var o = FakeT3Server.Options(); o.projectTitles = ["proj_demo": "demo-project", "proj_other": "other-project"]
        change?(&o)
        let s = try await startFake(o)
        let m = makeModel(s, prefs: prefs)
        await m.refresh()
        return (s, m)
    }

    /// Waits until the open composer's machine has its project and model lists (loaded in the background), at most 5 s.
    func settle(_ m: HuddleModel) async {
        for _ in 0..<100 {
            if let id = m.newThreadMachine, m.projectsByMachine[id] != nil, m.capabilitiesByMachine[id] != nil { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test func startingOnThisMacSendsOneLaunchWithTheChosenProject() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        #expect(m.canStartThreads)
        m.openNewThread(); await settle(m)
        #expect(m.newThreadOpen && m.newThreadMachine != nil)
        #expect(m.newThreadProject == "proj_demo", "the project with threads in the list comes first")
        m.composer.drafts[HuddleModel.newThreadKey] = "Add a CHANGELOG entry for 2.4\nfrom the merged PRs."
        await m.startNewThread()
        let l = try #require(s.launches.first)
        #expect(s.launches.count == 1)
        #expect(l.args["title"].string == "Add a CHANGELOG entry for 2.4")
        #expect(l.args["message"].string == "Add a CHANGELOG entry for 2.4\nfrom the merged PRs.")
        #expect(l.args["projectId"].string == "proj_demo" && l.args["scratch"].isNull)
        #expect(l.args["runtimeMode"].string == "auto" && l.args["interactionMode"].string == "default")
        #expect(l.args["workspaceStrategy"]["type"].string == "root" && l.args["clientRequestId"].string != nil)
        #expect(l.args["environmentId"].isNull)
        #expect(!m.newThreadOpen && m.composer.drafts[HuddleModel.newThreadKey] == nil)
        #expect(m.state.sessions[l.threadId] != nil, "the new thread is in the list")
        #expect(m.rowToasts[l.threadId]?.hasPrefix("Started on") == true)
        #expect(m.newThreadDefaults.lastProject.values.contains("proj_demo"))
    }

    @Test func optionsReachT3() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        m.openNewThread(); await settle(m)
        m.newThreadModel = ModelChoice(instanceId: "codex", model: "gpt-6.1-sol", label: "gpt-6.1-sol")
        m.newThreadMode = .approvalRequired; m.newThreadWorkspace = .worktree; m.newThreadPlan = true; m.newThreadTitle = "Changelog 2.4"
        m.composer.drafts[HuddleModel.newThreadKey] = "do it"
        await m.startNewThread()
        let a = try #require(s.launches.first?.args)
        #expect(a["modelSelection"]["instanceId"].string == "codex" && a["modelSelection"]["model"].string == "gpt-6.1-sol")
        #expect(a["runtimeMode"].string == "approval-required" && a["interactionMode"].string == "plan")
        #expect(a["workspaceStrategy"]["type"].string == "worktree" && a["title"].string == "Changelog 2.4")
    }

    @Test func scratchHasNoProject() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        var d = m.newThreadDefaults; d.scratch = true; m.setNewThreadDefaults(d)
        m.openNewThread(); await settle(m)
        #expect(m.newThreadProject == nil)
        m.composer.drafts[HuddleModel.newThreadKey] = "try something"
        await m.startNewThread()
        let a = try #require(s.launches.first?.args)
        #expect(a["scratch"].bool == true && a["projectId"].isNull && a["workspaceStrategy"].isNull)
    }

    @Test func aRepeatedStartIsOneThread() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        m.openNewThread(); await settle(m)
        m.composer.drafts[HuddleModel.newThreadKey] = "once"
        async let a: Void = m.startNewThread()
        async let b: Void = m.startNewThread()
        _ = await (a, b)
        #expect(s.launches.count == 1)
    }

    @Test func readOnlyStartsNothing() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        m.openNewThread(); await settle(m)
        m.composer.drafts[HuddleModel.newThreadKey] = "nope"
        m.setReadOnly(true)
        #expect(!m.canStartThreads)
        await m.startNewThread()
        #expect(s.launches.isEmpty)
    }

    @Test func withoutTheToolThereIsNoPlus() async throws {
        let (s, m) = try await setUp { $0.omitTools = ["t3_thread_launch"] }; defer { s.stop() }
        #expect(!m.canStartThreads && m.launchMachines.isEmpty)
    }

    @Test func aRefusalStaysInTheComposerInPlainWords() async throws {
        let (s, m) = try await setUp { $0.modeEscalationDenied = true }; defer { s.stop() }
        m.openNewThread(); await settle(m)
        m.composer.drafts[HuddleModel.newThreadKey] = "keep me"
        await m.startNewThread()
        #expect(m.newThreadState == .error(HuddleModel.modeDeniedMessage))
        #expect(m.newThreadOpen && m.composer.text(HuddleModel.newThreadKey) == "keep me")
    }

    @Test func modelsComeFromTheCatalogAndLimitTheModes() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        m.openNewThread(); await settle(m)
        let machine = try #require(m.newThreadMachine)
        let providers = try #require(m.capabilitiesByMachine[machine])
        #expect(providers.map(\.instanceId) == ["claudeAgent", "codex", "pi"], "disabled providers are left out")
        m.newThreadModel = providers[2].models[0]
        #expect(m.newThreadModes == [.approvalRequired, .autoAcceptEdits], "Pi does not allow Auto; full access is never offered")
        m.composer.drafts[HuddleModel.newThreadKey] = "on pi"
        await m.startNewThread()
        #expect(s.launches.first?.args["runtimeMode"].string == "auto-accept-edits", "a mode the provider refuses is not sent")
    }

    @Test func linkedOnlyMachinesCannotBeStartedOnButConnectedOnesCan() async throws {
        let two = try await startTwoMachines(); defer { two.stop() }
        let linked = makeRemoteModel(two)
        await linked.refresh()
        #expect(!linked.launchMachines.contains(where: { $0.id == "env_remote" }))

        let store = MemoryMachineCredentialStore([MachineCredential(environmentId: "env_remote", origin: "http://127.0.0.1:\(two.remote.port)", token: two.remote.token, label: "Studio Mac")])
        let m = HuddleModel(config: HuddleConfig(source: .fixed(two.local.url), tokenStore: MemoryTokenStore(token: two.local.token),
                                                 remotePolicy: .loopbackFixture, machineStore: store, log: HuddleLog(sink: { _ in })))
        await m.refresh()
        #expect(m.launchMachines.contains(where: { $0.id == "env_remote" }))
        m.openNewThread(); m.selectNewThreadMachine("env_remote"); await settle(m)
        m.composer.drafts[HuddleModel.newThreadKey] = "on the studio"
        await m.startNewThread()
        #expect(two.remote.launches.count == 1 && two.local.launches.isEmpty, "started on that machine's own T3")
        #expect(two.remote.launches.first?.args["environmentId"].isNull == true)
    }

    @Test func titlesComeFromTheFirstLine() {
        #expect(LaunchRequest.title(override: "", message: "Fix the build\nthen deploy") == "Fix the build")
        #expect(LaunchRequest.title(override: " Mine ", message: "x") == "Mine")
        #expect(LaunchRequest.title(override: "", message: "   ") == "New thread")
        let long = String(repeating: "a", count: 80)
        #expect(LaunchRequest.title(override: "", message: long).count == 60)
    }

    @Test func defaultsPersistAndAnOlderPreferencesFileStillLoads() async throws {
        let dir = tempDir()
        try Data(#"{"hiddenIDs":[],"collapsed":false,"muted":false,"readOnly":false,"closeSettles":false}"#.utf8)
            .write(to: dir.appendingPathComponent("preferences.json"))
        let (s, m) = try await setUp(prefs: PreferencesStore(directory: dir)); defer { s.stop() }
        #expect(m.newThreadDefaults == NewThreadDefaults())
        var d = m.newThreadDefaults; d.mode = .approvalRequired; d.plan = true; d.model = ModelChoice(instanceId: "codex", model: "gpt-6.1-sol", label: "Sol")
        m.setNewThreadDefaults(d)
        let again = makeModel(s, prefs: PreferencesStore(directory: dir))
        #expect(again.newThreadDefaults.mode == .approvalRequired && again.newThreadDefaults.plan && again.newThreadDefaults.model?.model == "gpt-6.1-sol")
        await again.refresh()
        again.openNewThread()
        #expect(again.newThreadMode == .approvalRequired && again.newThreadPlan, "the composer opens with the defaults")
    }

    @Test func plusOnACollapsedPanelExpandsIt() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        m.toggleCollapsed()
        #expect(m.collapsed && m.canStartThreads, "the plus shows when collapsed")
        m.openNewThread()
        #expect(!m.collapsed && m.newThreadOpen)
    }

    @Test func pollingNeverStartsAThread() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        m.composer.drafts[HuddleModel.newThreadKey] = "draft"
        for _ in 0..<3 { await m.refresh() }
        #expect(!s.calls.contains { $0.tool == "t3_thread_launch" })
    }
}
