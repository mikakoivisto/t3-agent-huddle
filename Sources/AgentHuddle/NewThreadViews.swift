import SwiftUI
import AppKit
import HuddleCore

// Start a new thread from the panel (spec 16): the "+" in the header opens this composer under it.

/// A chip that opens a menu. Snapshots draw the chip only (ImageRenderer cannot draw an NSMenu-backed control).
struct MenuChip<Content: View>: View {
    var icon: String
    var label: String
    var highlighted = false
    @ViewBuilder var content: () -> Content
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let chip = HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(Theme.grey)
            Text(verbatim: label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.grey)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.115)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(highlighted ? Theme.lime : Color.white.opacity(0.2), lineWidth: 1))
        if snapshot { chip }
        else { Menu { content() } label: { chip }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize() }
    }
}

/// A small segmented control drawn in SwiftUI, so snapshots render it.
struct Segments<T: Hashable>: View {
    var items: [(String, T)]
    var selection: T
    var enabled: (T) -> Bool = { _ in true }
    var pick: (T) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let (label, value) = items[i]
                let on = value == selection
                Button { pick(value) } label: {
                    Text(verbatim: label).font(.system(size: 11, weight: .semibold)).foregroundStyle(on ? .white : Theme.grey)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.white.opacity(0.2) : .clear))
                }.buttonStyle(.plain).disabled(!enabled(value)).opacity(enabled(value) ? 1 : 0.35)
            }
        }
        .padding(2).background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.105)))
    }
}

struct NewThreadComposer: View {
    @ObservedObject var model: HuddleModel
    @ObservedObject var store: ComposerStore
    var large = false
    var close: (() -> Void)? = nil
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let key = HuddleModel.newThreadKey
        let text = store.text(key)
        let ui = model.newThreadState
        let enabled = !model.readOnly && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.count <= HuddleModel.maxMessageLength && ui != .sending && model.newThreadMachine != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                machineChip
                projectChip
                Spacer(minLength: 0)
            }
            if large {
                GeometryReader { geo in
                    ComposeField(text: Binding(get: { store.text(key) }, set: { store.drafts[key] = $0 }),
                                 placeholder: "What should the agent do?", fixedHeight: max(140, geo.size.height))
                }
            } else {
                ComposeField(text: Binding(get: { store.text(key) }, set: { store.drafts[key] = $0 }),
                             placeholder: "What should the agent do?", maxLines: 6, minHeight: 48,
                             onExpand: { NewThreadWindowController.shared.show(model: model) })
            }
            if model.newThreadOptions { options }
            if case .error(let msg) = ui {
                Text(verbatim: msg).font(.system(size: 11.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 7) {
                Button { Task { await model.startNewThread(); if !model.newThreadOpen { close?() } } } label: {
                    Pill(text: ui == .sending ? "Starting…" : (ui.map { if case .error = $0 { return "Retry" }; return "Start" } ?? "Start"),
                         fill: enabled ? Theme.lime : Theme.dim)
                }.buttonStyle(.plain).disabled(!enabled).keyboardShortcut(.return, modifiers: .command)
                Button { model.newThreadOptions.toggle() } label: {
                    Pill(text: model.newThreadOptions ? "Hide options" : "Options", fill: Color.white.opacity(0.12), fg: .white)
                }.buttonStyle(.plain)
                Button { model.closeNewThread(); close?() } label: { Pill(text: "Cancel", fill: Color.white.opacity(0.12), fg: .white) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                Spacer(minLength: 4)
                Text(verbatim: "⌘↩").font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(1).layoutPriority(-1)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.cardRaised))
    }

    private var machineChip: some View {
        let id = model.newThreadMachine
        return MenuChip(icon: "desktopcomputer", label: id.map(model.machineName(forLaunch:)) ?? "No machine") {
            ForEach(model.launchMachines, id: \.id) { m in
                Button(model.machineName(forLaunch: m.id)) { model.selectNewThreadMachine(m.id) }
            }
        }
    }

    private var projectChip: some View {
        let machine = model.newThreadMachine ?? ""
        let projects = model.projectsByMachine[machine] ?? []
        let recent = model.recentProjectIds(machine)
        let label = model.newThreadProject.flatMap { p in projects.first { $0.id == p }?.title } ?? (model.newThreadProject == nil ? "Scratch" : "Project")
        return MenuChip(icon: "folder", label: label) {
            let r = projects.filter { recent.contains($0.id) }, o = projects.filter { !recent.contains($0.id) }
            if !r.isEmpty { Section("Recent") { ForEach(r) { p in Button(p.title) { model.newThreadProject = p.id } } } }
            Section(r.isEmpty ? "Projects" : "Other") {
                ForEach(o) { p in Button(p.title) { model.newThreadProject = p.id } }
                Button("Scratch (no project)") { model.newThreadProject = nil }
            }
        }
    }

    private var options: some View {
        let machine = model.newThreadMachine ?? ""
        let providers = model.capabilitiesByMachine[machine] ?? []
        return VStack(alignment: .leading, spacing: 7) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            optionRow("Model") {
                MenuChip(icon: "cpu", label: model.newThreadModel?.label ?? "T3 default") {
                    Button("T3 default") { model.newThreadModel = nil }
                    ForEach(providers, id: \.instanceId) { p in
                        Section(p.name) { ForEach(p.models, id: \.self) { m in Button(m.label) { model.newThreadModel = m } } }
                    }
                }
            }
            optionRow("Mode") {
                Segments(items: LaunchMode.allCases.map { ($0.label, $0) }, selection: model.newThreadMode,
                         enabled: { model.newThreadModes.contains($0) }) { model.newThreadMode = $0 }
            }
            optionRow("Workspace") {
                Segments(items: LaunchWorkspace.allCases.map { ($0.label, $0) }, selection: model.newThreadWorkspace,
                         enabled: { _ in model.newThreadProject != nil }) { model.newThreadWorkspace = $0 }
            }
            optionRow("Plan first") {
                Segments(items: [("No", false), ("Yes", true)], selection: model.newThreadPlan) { model.newThreadPlan = $0 }
            }
            optionRow("Title") {
                if snapshot {
                    Text(verbatim: model.newThreadTitle.isEmpty ? model.newThreadTitlePreview : model.newThreadTitle).font(.system(size: 11.5))
                        .foregroundStyle(model.newThreadTitle.isEmpty ? Theme.grey : .white).lineLimit(1).padding(.horizontal, 7).padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.105)))
                } else {
                    TextField(model.newThreadTitlePreview, text: $model.newThreadTitle).textFieldStyle(.roundedBorder).font(.system(size: 11.5))
                }
            }
        }
    }

    private func optionRow<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: label).font(.system(size: 11.5)).foregroundStyle(Theme.grey).frame(width: 68, alignment: .trailing)
            c()
            Spacer(minLength: 0)
        }
    }
}

/// ⤢: the same composer in a bigger window, sharing the draft.
@MainActor
final class NewThreadWindowController {
    static let shared = NewThreadWindowController()
    private var window: NSWindow?
    func show(model: HuddleModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "New thread"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 460, height: 300)
            w.backgroundColor = NSColor(Theme.panel)
            w.contentView = NSHostingView(rootView: NewThreadComposer(model: model, store: model.composer, large: true,
                                                                      close: { [weak self] in self?.window?.close() })
                .padding(12).frame(minWidth: 460, minHeight: 300).background(Theme.panel).preferredColorScheme(.dark))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Settings → General → New threads.
struct NewThreadDefaultsSection: View {
    @ObservedObject var model: HuddleModel
    var body: some View {
        let d = model.newThreadDefaults
        let machines = model.launchMachines
        let providers = machines.compactMap { model.capabilitiesByMachine[$0.id] }.first ?? []
        VStack(spacing: 0) {
            row("Machine") {
                MenuChip(icon: "desktopcomputer", label: d.machine.map(model.machineName(forLaunch:)) ?? "Last used") {
                    Button("Last used") { set { $0.machine = nil } }
                    ForEach(machines, id: \.id) { m in Button(model.machineName(forLaunch: m.id)) { set { $0.machine = m.id } } }
                }
            }
            divider
            row("Project") {
                Segments(items: [("Last used on that machine", false), ("Scratch", true)], selection: d.scratch) { v in set { $0.scratch = v } }
            }
            divider
            row("Model") {
                MenuChip(icon: "cpu", label: d.model?.label ?? "T3 default") {
                    Button("T3 default") { set { $0.model = nil } }
                    ForEach(providers, id: \.instanceId) { p in
                        Section(p.name) { ForEach(p.models, id: \.self) { m in Button(m.label) { set { $0.model = m } } } }
                    }
                }
            }
            divider
            row("Mode") { Segments(items: LaunchMode.allCases.map { ($0.label, $0) }, selection: d.mode) { v in set { $0.mode = v } } }
            divider
            row("Workspace") { Segments(items: LaunchWorkspace.allCases.map { ($0.label, $0) }, selection: d.workspace) { v in set { $0.workspace = v } } }
            divider
            row("Plan first") { Segments(items: [("No", false), ("Yes", true)], selection: d.plan) { v in set { $0.plan = v } } }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .task { for m in machines where model.capabilitiesByMachine[m.id] == nil { await model.loadLaunchListsForSettings(m.id) } }
    }

    private func set(_ change: (inout NewThreadDefaults) -> Void) { var d = model.newThreadDefaults; change(&d); model.setNewThreadDefaults(d) }
    private var divider: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: label).font(.system(size: 13)).foregroundStyle(.white).frame(width: 90, alignment: .leading)
            c()
            Spacer(minLength: 0)
        }.padding(.horizontal, 12).padding(.vertical, 9)
    }
}
