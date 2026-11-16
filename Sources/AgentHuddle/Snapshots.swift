import AppKit
import SwiftUI
import HuddleCore
import FakeT3

/// The two synthetic machines and a model wired to them: "Mika’s MacBook Pro" is this Mac (the panel's MCP), "Mika’s Mac mini" is the
/// linked machine. Loopback only, memory credential stores, nothing real. Used by the stills and by the video recorder.
@MainActor
final class DemoRig {
    let local: FakeT3Server       // this Mac: what the panel connects to; also lists the Mac mini's threads (linked environment)
    let mini: FakeT3Server        // the Mac mini: only answers its own decisions over /ws
    let model: HuddleModel
    let jumper = RecordingJumper()

    static let thisMacCode = "demo-code-macbook", miniCode = "demo-code-macmini"

    static func make(prefs: URL) async -> DemoRig {
        let (local, mini) = DemoScenario.makeFakes()
        try? await local.start(); try? await mini.start()
        return DemoRig(local: local, mini: mini, prefs: prefs)
    }

    private init(local: FakeT3Server, mini: FakeT3Server, prefs: URL) {
        self.local = local; self.mini = mini
        model = HuddleModel(config: HuddleConfig(
            source: .fixed(local.url), tokenStore: MemoryTokenStore(token: local.token),
            approvalStore: MemoryTokenStore(), remoteApprovalStore: MemoryRemoteCredentialStore(), remotePolicy: .loopbackFixture,
            preferences: PreferencesStore(directory: prefs), jumper: jumper))
    }

    /// The same calls the Inline approvals window's "Turn on" buttons make; the pairing codes are the fakes' single-use ones.
    func enableThisMac() async { await refresh(); try? await model.enableInlineApprovals(pairingCode: Self.thisMacCode) }
    func enableMini() async {
        await refresh()   // the linked machine must be known first
        try? await model.enableRemoteApprovals(environmentId: DemoScenario.miniEnv, address: "http://127.0.0.1:\(mini.port)", pairingCode: Self.miniCode, acknowledgeUnlisted: true)
    }
    func stop() { local.stop(); mini.stop() }
    func refresh(_ times: Int = 1) async { for _ in 0..<times { await model.refresh() } }

    /// Everything the story adds, in its final state (approvals off).
    func populateEverything() async {
        DemoScenario.start(local)
        DemoScenario.addQuestion(local)
        DemoScenario.addTriagePermission(local)
        DemoScenario.addCleanupPermission(local)
        DemoScenario.addBenchPermission((local, mini))
        DemoScenario.addWaiters(local)
        await refresh()
        DemoScenario.startWaiting(local)
        await refresh(3)   // the second pass sees the working subagent
    }
}

/// The picture that opens the video and heads the stills: four agents, two per machine. On this Mac one asks a question; on
/// the Mac mini one asks permission, with inline approvals on for that machine so Allow / Deny are there.
@MainActor
enum DemoHero {
    static func makeRig(prefs: URL) async -> DemoRig {
        let rig = await DemoRig.make(prefs: prefs)
        DemoScenario.start(rig.local, only: [DemoScenario.docs, DemoScenario.scripts])
        DemoScenario.addQuestion(rig.local)
        DemoScenario.addBenchPermission((rig.local, rig.mini))
        await rig.enableMini(); await rig.refresh(2)
        return rig
    }
    static func canvas(_ model: HuddleModel) -> some View {
        SnapshotCanvas(model: model, ids: nil, panels: true).environment(\.snapshotMode, true).environment(\.expandCommands, false)
    }
    /// For the splash card. Its own rig, stopped again before the story starts.
    static func image(prefs: URL) async -> NSImage? {
        let rig = await makeRig(prefs: prefs)
        let r = ImageRenderer(content: canvas(rig.model)); r.scale = 2
        let image = r.cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width / 2, height: $0.height / 2)) }
        rig.stop()
        return image
    }
}

/// The Machines tab with an approvals setup open, for the stills and the video. Hostnames are invented (`*.tailnet-demo.ts.net`).
enum DemoApprovalsData {
    static let miniAddress = "https://mac-mini.tailnet-demo.ts.net"
    /// `open` is ApprovalSetup.thisMac or a machine id; a machine's setup shows `address` as typed and checked (display only).
    @MainActor static func setup(_ model: HuddleModel, open: String?, address: String? = nil) -> ApprovalSetup {
        let s = ApprovalSetup(model: model)
        s.open = open
        if let open, let address, open != ApprovalSetup.thisMac {
            s.typed[open] = address; s.trustTyped[open] = true
            s.checks[ApprovalSetup.checkKey(open, address)] = .thisMachine
        }
        return s
    }
}

/// Offscreen renders of each UI state, for demo/stills. Needs no screen-recording permission.
/// The panel's own scrolling, the resize and the About panel come from the recorder (they need the real window).
@MainActor
enum Snapshots {
    static func run(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefs = FileManager.default.temporaryDirectory.appendingPathComponent("agent-huddle-snap-\(ProcessInfo.processInfo.processIdentifier)")

        // A. Approvals off (the default): the list, the detail, the waiting states, the question, the permission prompt.
        let hero = await DemoHero.makeRig(prefs: prefs.appendingPathComponent("hero"))
        write(DemoHero.canvas(hero.model), "01-list-two-machines", dir, scale: 2)
        hero.stop()
        let a = await DemoRig.make(prefs: prefs.appendingPathComponent("a"))
        DemoScenario.start(a.local)
        await a.refresh()
        menuBar(dir)
        await a.populateEverything()
        save(ids: [DemoScenario.render, DemoScenario.docs, DemoScenario.changelog, DemoScenario.triage, DemoScenario.cleanup, DemoScenario.config, DemoScenario.scripts],
             a.model, "03-model-icons-and-tooltip", dir, panels: false, aside: AnyView(ModelIconLegend()))

        let m = a.model
        m.openDetail(DemoScenario.render); await a.refresh()
        save(m, "04-detail-info-and-steps", dir)
        for step in m.state.sessions[DemoScenario.render]?.steps ?? [] where (step.state == .done || step.state == .failed) && step.kind == .terminal {
            await m.toggleStep(threadId: DemoScenario.render, stepId: step.id)
        }
        save(m, "05-detail-command-output-and-error", dir)
        m.openDetail(DemoScenario.docs); await a.refresh()
        save(m, "06-detail-ran-on-another-model", dir)
        m.back()

        save(ids: [DemoScenario.ciWatch, DemoScenario.shards], m, "07-waiting-on-background-task-and-subagent", dir, panels: false)
        DemoScenario.finishWaiting(a.local)
        await a.refresh(2)
        save(ids: [DemoScenario.ciWatch, DemoScenario.shards], m, "08-waiting-threads-finished", dir, panels: false)

        if let q = m.state.sessions[DemoScenario.changelog]?.question { m.select(option: q.options[0].label, for: q) }
        save(ids: [DemoScenario.changelog], m, "09-question-select-and-send", dir)
        save(ids: [DemoScenario.triage], m, "10-permission-review-in-t3", dir)
        save(ids: [DemoScenario.cleanup], m, "11-permission-long-command-collapsed", dir)
        save(ids: [DemoScenario.cleanup], m, "12-permission-long-command-full", dir, expand: true)
        DemoScenario.addSecretRequest(a.local); await a.refresh()
        save(ids: [DemoScenario.secretThread], m, "33-secret-request", dir)
        a.stop()

        // B. Only this Mac set up: the Mac mini's thread says so (and "Review in T3 Code" still works).
        let b = await DemoRig.make(prefs: prefs.appendingPathComponent("b"))
        DemoScenario.addBenchPermission((b.local, b.mini))
        await b.enableThisMac(); await b.refresh()
        save(ids: [DemoScenario.bench], b.model, "16-inline-approvals-machine-not-set-up", dir)
        machinesTab(model: b.model, "21-inline-approvals-window-setup",
                    setup: DemoApprovalsData.setup(b.model, open: DemoScenario.miniEnv, address: DemoApprovalsData.miniAddress), dir)
        b.stop()

        // C. Both machines on: Allow / Deny on each, read-only, a refused decision, and the thread carrying on.
        let c = await DemoRig.make(prefs: prefs.appendingPathComponent("c"))
        DemoScenario.addTriagePermission(c.local); DemoScenario.addCleanupPermission(c.local); DemoScenario.addBenchPermission((c.local, c.mini))
        await c.enableThisMac(); await c.enableMini(); await c.refresh()
        let cm = c.model
        save(ids: [DemoScenario.triage], cm, "13-inline-approvals-this-mac", dir)
        save(ids: [DemoScenario.bench], cm, "14-inline-approvals-other-machine", dir)
        cm.setReadOnly(true)
        save(ids: [DemoScenario.triage], cm, "15-inline-approvals-read-only", dir)
        cm.setReadOnly(false)
        // The command changed after it was shown: nothing is sent, the panel says so.
        c.local.update(DemoScenario.cleanup) { t in
            if let i = t.items.firstIndex(where: { $0.type == "approval_request" }) { t.items[i].text = "{\"command\": \"rm -rf build/tmp\"}" }
        }
        await cm.decideApproval(threadId: DemoScenario.cleanup, requestId: DemoScenario.cleanupRequestId,
                                summary: cm.state.sessions[DemoScenario.cleanup]?.permission?.summary, decision: .decline)
        save(ids: [DemoScenario.cleanup], cm, "17-inline-approvals-refused", dir)
        await cm.decideApproval(threadId: DemoScenario.triage, requestId: Scenario.permissionRequestId,
                                summary: cm.state.sessions[DemoScenario.triage]?.permission?.summary, decision: .accept)
        save(ids: [DemoScenario.triage], cm, "18-inline-approvals-after-allow", dir)
        await cm.decideApproval(threadId: DemoScenario.bench, requestId: Scenario.remoteRequestId,
                                summary: cm.state.sessions[DemoScenario.bench]?.permission?.summary, decision: .decline)
        save(ids: [DemoScenario.bench], cm, "19-inline-approvals-after-deny", dir)
        machinesTab(model: cm, "20-inline-approvals-window", setup: DemoApprovalsData.setup(cm, open: nil), dir)
        c.stop()

        // E. Write and send (spec 13): written answers, the composer, queue / steer, the pop-out editor.
        let e = await DemoRig.make(prefs: prefs.appendingPathComponent("e"))
        DemoScenario.start(e.local); DemoScenario.addQuestion(e.local)
        await e.refresh()
        let em = e.model
        save(ids: [DemoScenario.changelog], em, "34-question-write-answer", dir)
        if let q = em.state.sessions[DemoScenario.changelog]?.question {
            em.startWritingAnswer(q.requestId)
            em.composer.drafts[ComposerStore.answerKey(q.requestId)] = "Friendly, but keep each entry to one line and skip the emoji."
            save(ids: [DemoScenario.changelog], em, "35-question-writing-answer", dir)
            em.stopWritingAnswer()
        }
        // This Mac's threads: a linked machine's rows have no composer (spec 13, capability_denied).
        em.openComposer(DemoScenario.docs)
        em.composer.drafts[ComposerStore.messageKey(DemoScenario.docs)] = "Skip the API pages for now. Do the install guide first."
        save(ids: [DemoScenario.docs], em, "36-message-running-queue", dir)
        em.toggleSendMode(DemoScenario.docs)
        save(ids: [DemoScenario.docs], em, "37-message-running-steer", dir)
        await em.sendMessage(threadId: DemoScenario.docs)
        save(ids: [DemoScenario.docs], em, "38-message-steered", dir)
        e.local.update(DemoScenario.docs) { $0.status = "completed" }
        await e.refresh(2)
        em.openComposer(DemoScenario.docs)
        em.composer.drafts[ComposerStore.messageKey(DemoScenario.docs)] = "Now link the new install page from the README."
        save(ids: [DemoScenario.docs], em, "39-message-finished-send", dir)
        em.closeComposer(DemoScenario.docs)
        // The run ended while the user typed a steer: nothing is sent, the composer says so.
        em.openComposer(DemoScenario.render)
        em.composer.drafts[ComposerStore.messageKey(DemoScenario.render)] = "Attach the PDF to the release draft when it is done."
        em.toggleSendMode(DemoScenario.render)
        e.local.update(DemoScenario.render) { $0.status = "completed" }
        await em.sendMessage(threadId: DemoScenario.render)
        save(ids: [DemoScenario.render], em, "40-message-run-finished", dir)
        em.closeComposer(DemoScenario.render)
        e.local.update(DemoScenario.render) { $0.status = "running" }
        await e.refresh(2)
        em.composer.drafts[ComposerStore.messageKey(DemoScenario.render)] = "When the PDF is done, attach it to the release draft."
        em.openDetail(DemoScenario.render); await e.refresh()
        save(em, "41-detail-composer", dir)
        em.back()
        em.composer.drafts[ComposerStore.messageKey(DemoScenario.render)] = """
        When you're done with the notes, run the full release dry run and post the output here.

        If render-notes.js still calls the old node path, switch it to the one from .nvmrc, and don't touch the PDF step until we've upgraded the renderer, it breaks on the new config.

        Also the changelog step should read RELEASES.md, not CHANGELOG.md, that file is gone since the last release.
        """
        write(ComposeEditorView(model: em, store: em.composer, threadId: DemoScenario.render, close: {})
                .environment(\.snapshotMode, true).frame(width: 620, height: 440), "42-pop-out-editor", dir, scale: 2)
        em.setReadOnly(true)
        em.openComposer(DemoScenario.render)
        save(ids: [DemoScenario.render], em, "43-message-read-only", dir)
        e.stop()

        // F. Machines (spec 15): the Mac mini connected directly, a build box only linked, a studio Mac offline.
        let (fl, fm) = DemoScenario.makeFakes()
        try? await fl.start(); try? await fm.start()
        DemoScenario.start(fl, only: [DemoScenario.docs, DemoScenario.render])
        DemoScenario.start(fm, only: [DemoScenario.config, DemoScenario.scripts])
        DemoScenario.addBuildBox(fl)
        let machines = MemoryMachineCredentialStore([
            MachineCredential(environmentId: DemoScenario.miniEnv, origin: "http://127.0.0.1:\(fm.port)", token: fm.token, label: DemoScenario.macMini),
            MachineCredential(environmentId: "env_studio", origin: "http://127.0.0.1:9", token: "x", label: "Studio Mac"),
        ])
        let mm = HuddleModel(config: HuddleConfig(source: .fixed(fl.url), tokenStore: MemoryTokenStore(token: fl.token),
                                                  remotePolicy: .loopbackFixture, machineStore: machines,
                                                  preferences: PreferencesStore(directory: prefs.appendingPathComponent("f"))))
        await mm.refresh(); await mm.refresh()
        save(mm, "44-machines-panel", dir)
        machinesTab(model: mm, "45-machines-window", setup: ApprovalSetup(model: mm), dir)
        let flow = AddMachineFlow()
        flow.start(address: "http://127.0.0.1:\(fm.port)")
        _ = machines.delete(environmentId: DemoScenario.miniEnv)            // as if the Mac mini were not connected yet
        let addModel = HuddleModel(config: HuddleConfig(source: .fixed(fl.url), tokenStore: MemoryTokenStore(token: fl.token),
                                                        remotePolicy: .loopbackFixture, machineStore: MemoryMachineCredentialStore(),
                                                        preferences: PreferencesStore(directory: prefs.appendingPathComponent("f2"))))
        await addModel.refresh()
        flow.found = try? await addModel.identifyMachine(address: flow.address)
        flow.address = "mikas-mac-mini.tailnet-demo.ts.net"
        write(AddMachineCard(model: addModel, flow: flow).frame(width: 508).padding(16).background(Theme.panel).environment(\.snapshotMode, true),
              "46-machines-add", dir, scale: 2)
        fl.stop(); fm.stop()

        // H. Attention indicator and Settings (spec 14).
        let h = await DemoRig.make(prefs: prefs.appendingPathComponent("h"))
        DemoScenario.start(h.local); DemoScenario.addQuestion(h.local); DemoScenario.addTriagePermission(h.local)
        await h.refresh()
        let hm = h.model
        let bars = HStack(spacing: 18) {
            ForEach([(Color(white: 0.91), Color.black), (Color(white: 0.15), Color.white)], id: \.0) { bg, fg in
                HStack(spacing: 14) {
                    Text(verbatim: "Wi-Fi").font(.system(size: 13)).foregroundStyle(fg.opacity(0.7))
                    MenuBarGlyph(count: 4, frame: 1, size: 18, attention: hm.attentionSessions.count, tint: fg)
                    Text(verbatim: "Sun 14:52").font(.system(size: 13, weight: .medium)).foregroundStyle(fg.opacity(0.8))
                }.padding(.horizontal, 14).frame(height: 30).background(RoundedRectangle(cornerRadius: 7).fill(bg))
            }
        }.padding(16).background(Color(white: 0.06))
        write(bars, "50-attention-menu-bar", dir, scale: 2)
        save(ids: [DemoScenario.render, DemoScenario.docs], hm, "51-attention-header-pill", dir)
        hm.toggleCollapsed()
        save(hm, "52-attention-collapsed", dir)
        hm.toggleCollapsed()
        hm.openDetail(DemoScenario.render); await h.refresh()
        save(hm, "53-attention-detail", dir)
        hm.back()
        let sel = SettingsSelection()
        write(SettingsView(model: hm, selection: sel, flow: AddMachineFlow(), setup: ApprovalSetup(model: hm)).environment(\.snapshotMode, true), "54-settings-general", dir, scale: 2)
        sel.tab = .machines
        write(SettingsView(model: hm, selection: sel, flow: AddMachineFlow(), setup: DemoApprovalsData.setup(hm, open: ApprovalSetup.thisMac)).environment(\.snapshotMode, true), "55-settings-machines", dir, scale: 2)
        h.stop()

        // I. New thread (spec 16): the composer, its options, a started thread, the Settings section.
        let n = await DemoRig.make(prefs: prefs.appendingPathComponent("n"))
        DemoScenario.start(n.local, only: [DemoScenario.docs, DemoScenario.render])
        await n.refresh()
        let nm = n.model
        nm.openNewThread()
        try? await Task.sleep(nanoseconds: 300_000_000)
        nm.composer.drafts[HuddleModel.newThreadKey] = "Add a CHANGELOG entry for 2.4 from the merged PRs, then open a PR."
        save(nm, "56-new-thread", dir)
        nm.newThreadOptions = true
        save(nm, "57-new-thread-options", dir)
        nm.newThreadOptions = false
        await nm.startNewThread()
        save(nm, "58-new-thread-started", dir)
        write(SettingsView(model: nm, selection: SettingsSelection(), flow: AddMachineFlow(), setup: ApprovalSetup(model: nm))
                .environment(\.snapshotMode, true), "59-settings-new-threads", dir, scale: 2)
        n.stop()

        // J. Several questions in one request (spec 04): the first, a written answer, the review.
        let j = await DemoRig.make(prefs: prefs.appendingPathComponent("j"))
        DemoScenario.start(j.local, only: [DemoScenario.docs]); DemoScenario.addQuestion(j.local); DemoScenario.addMultiQuestion(j.local)
        await j.refresh()
        let jm = j.model
        save(ids: [DemoScenario.changelog], jm, "60-questions-first", dir)
        if let q = jm.state.sessions[DemoScenario.changelog]?.question {
            jm.chooseMultiAnswer(q, q.parts[0].options[1].label)
            jm.startWritingMultiAnswer(q)
            jm.composer.drafts[HuddleModel.multiDraftKey(q.requestId, "q1")] = "Own section first, and repeat each one in its feature's entry."
            save(ids: [DemoScenario.changelog], jm, "61-questions-writing", dir)
            jm.useWrittenMultiAnswer(q)
            jm.chooseMultiAnswer(q, q.parts[2].options[0].label)
            save(ids: [DemoScenario.changelog], jm, "62-questions-review", dir)
        }
        j.stop()

        // D. Closing, the collapsed header, a jump that cannot be delivered, and T3 going away.
        let d = await DemoRig.make(prefs: prefs.appendingPathComponent("d"))
        DemoScenario.start(d.local); DemoScenario.addWaiters(d.local)
        await d.refresh()
        DemoScenario.startWaiting(d.local); await d.refresh(2)
        DemoScenario.finishWaiting(d.local); await d.refresh(2)
        let dm = d.model
        dm.closeTapped(DemoScenario.shards)
        save(ids: [DemoScenario.shards], dm, "22-close-armed", dir, panels: false)
        dm.confirmClose(DemoScenario.shards)
        save(dm, "23-closed-count-drops", dir)
        d.local.update(DemoScenario.shards) { $0.status = "running" }   // it works again → it comes back
        await d.refresh(2)
        save(dm, "24-closed-thread-returns", dir)
        dm.toggleCollapsed()
        save(dm, "25-collapsed", dir)
        dm.toggleCollapsed()
        d.jumper.succeeds = false
        await dm.jump(DemoScenario.render)
        save(ids: [DemoScenario.render], dm, "30-jump-toast", dir, panels: false)

        d.local.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)
        await dm.refresh()
        save(dm, "31-t3-not-running", dir)
        let bare = HuddleModel(config: HuddleConfig(source: .fixed(d.local.url), tokenStore: MemoryTokenStore()))
        await bare.refresh()
        save(bare, "32-connect-to-t3", dir)
        d.stop()
        try? FileManager.default.removeItem(at: prefs)
    }

    /// Menu bar: idle, then the four animation frames with the count, on a strip like the real one.
    private static func menuBar(_ dir: URL) {
        let strip = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 22) {
                VStack(spacing: 6) { MenuBarGlyph(count: 0, frame: 0, size: 54); Text(verbatim: "idle: still, no number").font(.system(size: 12)).foregroundStyle(Theme.grey) }
                ForEach(0..<4, id: \.self) { f in
                    VStack(spacing: 6) { MenuBarGlyph(count: 4, frame: f, size: 54); Text(verbatim: "4 working, frame \(f + 1)").font(.system(size: 12)).foregroundStyle(Theme.grey) }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 16).background(Color(white: 0.16))
        }.padding(20).background(Color(white: 0.06))
        write(strip, "02-menu-bar-robot-frames", dir, scale: 2)
    }

    /// The Settings window's Machines tab as a still, with the approvals setup state given.
    @MainActor static func machinesTab(model: HuddleModel, _ name: String, setup: ApprovalSetup, _ dir: URL) {
        write(MachinesView(model: model, flow: AddMachineFlow(), setup: setup).environment(\.snapshotMode, true), name, dir, scale: 2)
    }

    static func write<V: View>(_ view: V, _ name: String, _ dir: URL, scale: CGFloat = 2) {
        let r = ImageRenderer(content: view); r.scale = scale
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { print("render failed: \(name)"); return }
        try? png.write(to: dir.appendingPathComponent("\(name).png")); print("wrote \(name).png")
    }

    /// `ids` renders just those rows (a session subset); nil renders the whole list.
    private static func save(ids: [String]? = nil, _ model: HuddleModel, _ name: String, _ dir: URL,
                             panels: Bool = true, expand: Bool = false, aside: AnyView? = nil) {
        let canvas = SnapshotCanvas(model: model, ids: ids, panels: panels, aside: aside)
            .environment(\.snapshotMode, true).environment(\.expandCommands, expand)
        write(canvas, name, dir, scale: 2)
    }
}

struct SnapshotCanvas: View {
    @ObservedObject var model: HuddleModel
    var ids: [String]?
    var panels = true
    var aside: AnyView?
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.04), Color(red: 0.07, green: 0.08, blue: 0.03)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .top, spacing: 24) {
                Group {
                    if let ids {
                        let rows = ids.compactMap { model.state.sessions[$0] }
                        VStack(spacing: 10) {
                            HeaderBar(model: model)
                            ForEach(rows) { SessionRow(model: model, session: $0, showsPanels: panels) }
                            if let t = model.toast {
                                Text(verbatim: t).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                                    .padding(.horizontal, 12).padding(.vertical, 7).background(Capsule().fill(Theme.lime))
                            }
                        }
                        .padding(14).frame(width: Theme.width)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    } else {
                        HuddleRootView(model: model)
                    }
                }
                if let aside { aside }
            }.padding(28)
        }
        .fixedSize()
    }
}
