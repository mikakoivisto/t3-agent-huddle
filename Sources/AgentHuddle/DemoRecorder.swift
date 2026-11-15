import AppKit
import SwiftUI
import HuddleCore
import FakeT3

/// Records the *real* NSPanel (live NSHostingView → bitmap via `cacheDisplay`, no Screen Recording permission) while a scripted
/// driver exercises the model against the two fake machines. Each frame is composed on a stage with a caption, the menu-bar strip
/// and, for some beats, an inset (the Inline approvals window, the model-icon tooltips, About). Frames → PNG; ffmpeg stitches them.
/// The driver calls the same model methods the buttons call; it does not synthesise mouse events.
@MainActor
final class DemoRecorder {
    private let controller: PanelController
    private let rig: DemoRig
    private var model: HuddleModel { rig.model }
    private var local: FakeT3Server { rig.local }
    private let dir: URL
    private var frame = 0
    private var blank = 0
    private var caption = "", sub = ""
    private var inset = DemoInset.none
    private var lastPanel: NSImage?
    private var stills: URL { dir.appendingPathComponent("stills") }
    private static let tall: CGFloat = 740

    init(controller: PanelController, rig: DemoRig, dir: URL) {
        self.controller = controller; self.rig = rig; self.dir = dir
        for sub in ["frames", "stills"] { try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
    }

    // MARK: Story

    func run() async {
        controller.setMaxHeight(Self.tall)
        DemoScenario.start(local)
        await model.refresh()

        // The list, two machines, the menu-bar robot.
        await beat("Every running T3 thread, in one place", "Grouped by machine: this MacBook Pro and the linked Mac mini. Steps, run time, model and project on each row; the menu-bar robot walks and counts.", seconds: 5.5)

        // A question, answered in the panel.
        await beat("A thread asks a question", "It rises to the top and the row lights up.", seconds: 3) { DemoScenario.addQuestion(self.local); await self.model.refresh() }
        if let q = model.state.sessions[DemoScenario.changelog]?.question {
            await beat("Pick an answer in the panel", seconds: 1.8) { self.model.select(option: q.options[1].label, for: q) }
            await beat("Send answers it through T3’s MCP", "No window switch; the agent carries on.", seconds: 2.2) {
                await self.model.sendAnswer(threadId: DemoScenario.changelog)
                DemoScenario.continueAfterAnswer(self.local); await self.model.refresh()
            }
        }

        // Model icons.
        await beat("One icon per model", "Claude, Codex, Qwen on pi, Grok, a letter badge for the rest. Hover shows the name and the model it really ran on.", inset: .modelIcons, seconds: 4.5)

        // Detail.
        await beat("Open a thread", "Info block, then its steps. The running command’s output advances.", seconds: 2.5, ticks: true) {
            self.model.openDetail(DemoScenario.render); await self.model.refresh()
        }
        await beat("Open a step to read its output", seconds: 2.5, ticks: true) { await self.model.toggleStep(threadId: DemoScenario.render, stepId: "item_2") }
        await beat("A failed step is red, with its error", seconds: 3, ticks: true) { await self.model.toggleStep(threadId: DemoScenario.render, stepId: "item_3") }
        await beat("It can run on a different model than asked", "Asked for Claude Opus 5.5, ran on Claude Sonnet 5.5.", seconds: 2.5) {
            self.model.back(); self.model.openDetail(DemoScenario.docs); await self.model.refresh()
        }

        // Waiting states.
        await beat("Two more threads start", seconds: 1.8) { self.model.back(); DemoScenario.addWaiters(self.local); await self.model.refresh() }
        await beat("T3 says “completed”, the panel keeps them working", "“Waiting on a background task” and “Waiting on a subagent”. The menu-bar count does not drop.", seconds: 5) {
            DemoScenario.startWaiting(self.local); await self.model.refresh(); await self.model.refresh()
        }
        await beat("…until they really finish", seconds: 2.5) { DemoScenario.finishWaiting(self.local); await self.model.refresh(); await self.model.refresh() }

        // Permissions, without inline approvals.
        await beat("Needs permission: the tool and the exact command", "A long command collapses behind “Show full command”. “Review in T3 Code” opens the thread.", seconds: 4.5) {
            DemoScenario.addTriagePermission(self.local); DemoScenario.addCleanupPermission(self.local); await self.model.refresh()
        }

        // Opting in to inline approvals.
        await beat("Opt in to inline approvals", "Menu bar → Inline approvals…. Each machine has its own login, made with a pairing code on that machine.",
                   inset: .approvals(DemoApprovalsData.live(model, open: "this")), seconds: 3.5)
        await beat("This Mac is on", "Allow and Deny appear under the command.", inset: .approvals(DemoApprovalsData.live(model, open: nil)), seconds: 2.5) {
            await self.rig.enableThisMac(); await self.model.refresh()
        }
        await beat("The Mac mini is its own login", "Its thread is on the list, but without a login it only says so.",
                   inset: .approvals(DemoApprovalsData.live(model, open: DemoScenario.miniEnv, found: [DemoApprovalsData.miniAddress])), seconds: 2.5) {
            DemoScenario.addBenchPermission((self.local, self.rig.mini)); await self.model.refresh()
        }
        await beat("Both machines on", inset: .approvals(DemoApprovalsData.live(model, open: nil)), seconds: 2) {
            await self.rig.enableMini(); await self.model.refresh()
        }

        // Decisions: the prompt stays visible for a moment, then the click.
        await beat("Allow on a thread of this MacBook", "An explicit click, no default button. The thread carries on.", seconds: 4, each: { i, _ in
            if i == 15 { await self.decide(DemoScenario.triage, Scenario.permissionRequestId, .accept) }
        })
        await beat("Allow on a thread of the Mac mini", "Through that machine’s own login, after checking it is that machine.", seconds: 4.5, each: { i, _ in
            if i == 18 { await self.decide(DemoScenario.bench, Scenario.remoteRequestId, .accept) }
        }) { self.scroll(1) }   // the Mac mini’s group is below the fold
        await beat("Deny: the command fails and the agent decides what next", seconds: 4, each: { i, _ in
            if i == 15 { await self.decide(DemoScenario.cleanup, DemoScenario.cleanupRequestId, .decline) }
        }) { self.scroll(0) }
        await beat("Every machine at a glance", "On, off, or “needs re-pairing” after a revoked login.", inset: .approvals(DemoApprovalsData.overview(open: nil)), seconds: 3.5)
        await beat("Several addresses? Each one is checked", "The setup steps open inside the machine’s row.", inset: .approvals(DemoApprovalsData.overview(open: "studio")), seconds: 3.5)

        // Closing.
        await beat("First tap on × arms a red Close pill", seconds: 1.8) {
            self.local.update(DemoScenario.shards) { _ in }; await self.model.refresh(); self.model.closeTapped(DemoScenario.shards)
        }
        await beat("Second tap closes it; the count drops", seconds: 2.2) { self.model.closeTapped(DemoScenario.shards) }
        await beat("A closed thread returns when it works again", seconds: 2.5) {
            self.local.update(DemoScenario.shards) { $0.status = "running" }; await self.model.refresh(); await self.model.refresh()
        }

        // Resizing.
        let shrink = 12, grow = 12
        await beat("Drag the bottom edge: the list scrolls", "The panel remembers the height you set.", seconds: 3.5, still: "26-resize-short-scrolling", each: { i, n in
            if i < shrink { self.controller.demoResize(toHeight: Self.tall - (Self.tall - 330) * CGFloat(i + 1) / CGFloat(shrink)) }
            if i == shrink { self.controller.endDemoResize() }
            if i > shrink { self.scroll(Double(i - shrink) / Double(n - shrink - 1)) }
        }) { self.controller.beginDemoResize() }
        await beat("…and drag it taller again", seconds: 2.5, still: "27-resize-taller", each: { i, _ in
            if i < grow { self.controller.demoResize(toHeight: 330 + (Self.tall - 330) * CGFloat(i + 1) / CGFloat(grow)) }
            if i == grow { self.controller.endDemoResize() }
        }) { self.scroll(0); self.controller.beginDemoResize() }

        // About and the icon.
        var about: NSImage?
        var icon: NSImage?
        await beat("About Agent Huddle", "MIT licensed, independent, no third-party code.", seconds: 3) {
            icon = self.appIcon(); about = await self.captureAbout()
            self.inset = .about(about, icon)
            if let about { self.writeStill(about, "28-about-panel") }
        }
        await beat("Agent Huddle", "A native macOS panel for T3 Code. Loopback only. All of this ran on synthetic data.", seconds: 2)
        print("FRAMES=\(frame) blank-panel-frames-reused=\(blank)")
    }

    private func decide(_ threadId: String, _ requestId: String, _ decision: ApprovalDecision) async {
        await model.decideApproval(threadId: threadId, requestId: requestId, summary: model.state.sessions[threadId]?.permission?.summary, decision: decision)
    }

    // MARK: Frames

    private func beat(_ cap: String, _ subtitle: String = "", inset: DemoInset = .none, seconds: Double, ticks: Bool = false,
                      still: String? = nil, each: ((Int, Int) async -> Void)? = nil, _ start: () async -> Void = {}) async {
        caption = cap; sub = subtitle; self.inset = inset
        await start()
        let n = max(2, Int(seconds * 10))
        for i in 0..<n {
            if ticks && i % 8 == 4 { Scenario.advanceRender(local); await model.refresh() }
            await each?(i, n)
            capture()
            if let still, i == n - 1, let lastPanel { writeStill(lastPanel, still, onStage: true) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func panelImage() -> NSImage? {
        controller.fit()
        guard let view = controller.panel.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        // A bitmap taken while SwiftUI is mid-update can come back empty; the middle of the panel is always opaque.
        guard (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 else { return nil }
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func capture() {
        var panel = panelImage()
        if panel == nil { panel = panelImage() }
        if panel == nil { blank += 1; panel = lastPanel }
        lastPanel = panel
        let working = model.sessions.filter(\.isWorking).count
        let canvas = DemoFrameView(panel: panel, model: model, caption: caption, sub: sub, inset: inset, count: working, frame: frame / 3)
            .environment(\.snapshotMode, true)
        let r = ImageRenderer(content: canvas); r.scale = 1.25
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent(String(format: "frames/f%04d.png", frame)))
        frame += 1
    }

    private func writeStill(_ image: NSImage, _ name: String, onStage: Bool = false) {
        let url = stills.appendingPathComponent("\(name).png")
        if onStage {
            let r = ImageRenderer(content: PanelStill(panel: image)); r.scale = 2
            if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { try? png.write(to: url) }
        } else if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    // MARK: Things only the real window shows

    /// The list's own scroll view (the panel shows one when it is shorter than its content). 0 = top, 1 = bottom.
    private func scroll(_ fraction: Double) {
        guard let root = controller.panel.contentView, let sv = Self.findScrollView(in: root), let doc = sv.documentView else { return }
        let clip = sv.contentView
        let range = max(0, doc.frame.height - clip.bounds.height)
        let f = CGFloat(min(1, max(0, fraction)))
        clip.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? range * f : range * (1 - f)))
        sv.reflectScrolledClipView(clip)
    }
    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView { return sv }
        for s in view.subviews { if let hit = findScrollView(in: s) { return hit } }
        return nil
    }

    private func appIcon() -> NSImage? {
        let r = ImageRenderer(content: AppIconView()); r.scale = 0.25
        return r.cgImage.map { NSImage(cgImage: $0, size: NSSize(width: 256, height: 256)) }
    }

    /// The standard About panel is an AppKit window; render it like the floating panel. It stays on screen for a moment only.
    private func captureAbout() async -> NSImage? {
        if let icon = appIcon() { NSApp.applicationIconImage = icon }
        About.show()
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard let w = NSApp.windows.first(where: { $0 !== controller.panel && $0.isVisible && $0.frame.width > 250 }),
              let content = w.contentView else { return nil }
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        defer { w.orderOut(nil) }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
