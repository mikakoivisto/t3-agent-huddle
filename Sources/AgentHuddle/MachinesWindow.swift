import SwiftUI
import AppKit
import HuddleCore

// Machines (spec 15): T3 on this Mac or on any other machine, each reached through its own MCP. One row per machine with its
// sign-in (answers and messages) and its optional inline approvals; "Add machine" signs in to another machine's T3.
// Nothing here holds a credential: the user makes a pairing code on the machine and pastes it into that machine's T3 page.

@MainActor
final class MachinesWindowController {
    static let shared = MachinesWindowController()
    private var window: NSWindow?
    private let flow = AddMachineFlow()

    func show(model: HuddleModel, adding address: String? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Machines"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MachinesView(model: model, flow: flow))
            w.contentMinSize = NSSize(width: 540, height: 360)
            w.contentMaxSize = NSSize(width: 540, height: 4000)
            w.backgroundColor = NSColor(Theme.panel)
            w.center()
            window = w
        }
        if let address { flow.start(address: address) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The add-a-machine steps: address → what it says it is → sign in on its page.
@MainActor
final class AddMachineFlow: ObservableObject {
    @Published var open = false
    @Published var address = ""
    @Published var checking = false
    @Published var found: IdentifiedRemote?
    @Published var error: String?

    func start(address: String = "") { open = true; self.address = address; found = nil; error = nil }
    func reset() { open = false; address = ""; found = nil; error = nil; checking = false }

    func check(_ model: HuddleModel) {
        checking = true; error = nil; found = nil
        let typed = address
        Task {
            do { found = try await model.identifyMachine(address: typed) }
            catch { self.error = (error as? HuddleError)?.description ?? error.localizedDescription }
            checking = false
        }
    }
}

struct MachinesView: View {
    @ObservedObject var model: HuddleModel
    @ObservedObject var flow: AddMachineFlow
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Each machine is reached through its own T3 Code. Connect one to answer and message its threads from the panel.")
                .font(.system(size: 12)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
            ThisMacMachineRow(model: model)
            ForEach(model.otherMachineIds, id: \.self) { id in OtherMachineRow(model: model, flow: flow, id: id) }
            if flow.open { AddMachineCard(model: model, flow: flow) }
            else {
                HStack { Spacer()
                    Button { flow.start() } label: { Pill(text: "Add machine…", fill: Color.white.opacity(0.12), fg: .white) }.buttonStyle(.plain)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        Group {
            if snapshot { content } else { ScrollView { content } }
        }
        .frame(width: 540).background(Theme.panel).preferredColorScheme(.dark)
    }
}

struct MachineBadgeView: View {
    var badge: MachineBadge
    var body: some View {
        let (text, fg, bg): (String, Color, Color) = {
            switch badge {
            case .thisMac: return ("THIS MAC", Theme.lime, Theme.lime.opacity(0.15))
            case .connected: return ("CONNECTED", Theme.lime, Theme.lime.opacity(0.15))
            case .linkedOnly: return ("LINKED ONLY", Color(white: 0.75), Color.white.opacity(0.1))
            case .offline: return ("OFFLINE", Color(red: 1, green: 0.55, blue: 0.55), Theme.red.opacity(0.15))
            case .signInExpired: return ("SIGN-IN EXPIRED", Theme.steer, Theme.steer.opacity(0.15))
            case .unsupported: return ("UNSUPPORTED", Color(red: 1, green: 0.55, blue: 0.55), Theme.red.opacity(0.15))
            }
        }()
        Text(verbatim: text).font(.system(size: 9.5, weight: .heavy)).foregroundStyle(fg)
            .padding(.horizontal, 5).padding(.vertical, 1.5).background(RoundedRectangle(cornerRadius: 4).fill(bg))
    }
}

private struct MachineCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }
}

private struct SwitchLine: View {
    var on: Bool
    var title: String
    var detail: String?
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(on ? Theme.lime : Color.white.opacity(0.25)).frame(width: 8, height: 8)
            Text(verbatim: title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
            if let detail { Text(verbatim: "· \(detail)").font(.system(size: 11.5)).foregroundStyle(Theme.grey).lineLimit(1) }
        }
    }
}

struct ThisMacMachineRow: View {
    @ObservedObject var model: HuddleModel
    var body: some View {
        MachineCard {
            HStack(spacing: 8) {
                Text(verbatim: model.localEnvironmentName ?? "This Mac").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                MachineBadgeView(badge: .thisMac)
                Spacer()
                Text(verbatim: "loopback").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            HStack {
                switch model.state.connection {
                case .connected:
                    SwitchLine(on: true, title: "Answers & messages", detail: "signed in")
                    Spacer()
                    Button { confirmSignOutThisMac(model) } label: { Pill(text: "Sign out", fill: Color.white.opacity(0.12), fg: .white) }.buttonStyle(.plain)
                case .unauthorized:
                    SwitchLine(on: false, title: "Answers & messages", detail: model.signingIn ? "approve in your browser…" : "not signed in")
                    Spacer()
                    if model.signingIn {
                        Button { model.cancelSignIn() } label: { Pill(text: "Cancel", fill: Color.white.opacity(0.12), fg: .white) }.buttonStyle(.plain)
                    } else {
                        Button { model.signIn() } label: { Pill(text: "Connect", fill: Theme.lime) }.buttonStyle(.plain)
                    }
                case .notRunning:
                    SwitchLine(on: false, title: "T3 Code isn’t running on this Mac", detail: nil)
                default:
                    SwitchLine(on: false, title: model.state.connection.headline ?? "Connecting…", detail: nil)
                }
            }
            HStack {
                SwitchLine(on: model.inlineApprovals, title: "Allow / Deny", detail: model.inlineApprovals ? "on" : "off")
                Spacer()
                Button { ApprovalsWindowController.shared.show(model: model) } label: {
                    Pill(text: model.inlineApprovals ? "Manage…" : "Set up…", fill: Color.white.opacity(0.12), fg: .white)
                }.buttonStyle(.plain)
            }
            if let note = model.connectNote {
                Text(verbatim: note).font(.system(size: 11.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct OtherMachineRow: View {
    @ObservedObject var model: HuddleModel
    @ObservedObject var flow: AddMachineFlow
    var id: String
    var body: some View {
        let badge = model.machineBadge(id)
        let connected = model.connectedMachineIds.contains(id)
        let approvals = model.remoteApprovalStatus(id)
        MachineCard {
            HStack(spacing: 8) {
                Text(verbatim: model.machineLabel(id)).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                MachineBadgeView(badge: badge)
                Spacer()
                if let origin = model.suggestedAddress(id) {
                    Text(verbatim: URL(string: origin)?.host ?? origin).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack {
                SwitchLine(on: connected, title: "Answers & messages", detail: detail(badge, connected))
                Spacer()
                if case .waitingForBrowser? = model.machineSignIns[id] {
                    Button { model.cancelMachineSignIn(id) } label: { Pill(text: "Cancel", fill: Color.white.opacity(0.12), fg: .white) }.buttonStyle(.plain)
                } else if connected {
                    Button { _ = model.signOutMachine(id) } label: { Pill(text: "Sign out", fill: Color.white.opacity(0.12), fg: .white) }.buttonStyle(.plain)
                } else {
                    Button { flow.start(address: model.suggestedAddress(id) ?? "") } label: { Pill(text: "Connect…", fill: Theme.lime) }.buttonStyle(.plain)
                }
            }
            if case .failed(let msg)? = model.machineSignIns[id] {
                Text(verbatim: msg).font(.system(size: 11.5)).foregroundStyle(Theme.red).lineLimit(2)
            }
            if case .offline(let why)? = model.machineStatus[id] {
                Text(verbatim: why).font(.system(size: 11.5)).foregroundStyle(Theme.grey).lineLimit(2)
            }
            HStack {
                SwitchLine(on: approvals == .on, title: "Allow / Deny",
                           detail: approvals == .on ? "on" : approvals == .needsRepair ? "needs re-pairing" : "off · needs its own pairing code")
                Spacer()
                Button { ApprovalsWindowController.shared.show(model: model) } label: {
                    Pill(text: approvals == .off ? "Set up…" : "Manage…", fill: Color.white.opacity(0.12), fg: .white)
                }.buttonStyle(.plain)
            }
        }
    }

    private func detail(_ badge: MachineBadge, _ connected: Bool) -> String {
        if case .waitingForBrowser? = model.machineSignIns[id] { return "approve in your browser…" }
        switch badge {
        case .signInExpired: return "sign in again"
        case .offline: return "signed in, not reachable"
        case .linkedOnly: return "read-only through this Mac"
        case .unsupported: return "unsupported T3 Code version"
        default: return connected ? "signed in" : "not connected"
        }
    }
}

struct AddMachineCard: View {
    @ObservedObject var model: HuddleModel
    @ObservedObject var flow: AddMachineFlow
    @Environment(\.snapshotMode) private var snapshot
    static let pairingCommand = "t3 auth pairing create --scope orchestration:read --scope orchestration:operate --ttl 10m"

    var body: some View {
        MachineCard {
            HStack {
                Text(verbatim: "Add machine").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Button { flow.reset() } label: { Image(systemName: "xmark").foregroundStyle(Theme.grey) }.buttonStyle(.plain)
            }
            step(1, done: flow.found != nil, "Its address") {
                HStack {
                    if snapshot {   // ImageRenderer cannot draw an NSTextField
                        Text(verbatim: flow.address).font(.system(size: 12)).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 5).fill(Theme.terminal))
                    } else {
                        TextField("mac-mini.your-tailnet.ts.net", text: $flow.address)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12)).onSubmit { flow.check(model) }
                    }
                    Button { flow.check(model) } label: {
                        Pill(text: flow.checking ? "Checking…" : "Check", fill: flow.address.isEmpty ? Theme.dim : Theme.lime)
                    }.buttonStyle(.plain).disabled(flow.address.isEmpty || flow.checking)
                }
                if let error = flow.error {
                    Text(verbatim: error).font(.system(size: 11.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let found = flow.found {
                step(2, done: true, "It answers as") {
                    Text(verbatim: "\(found.label ?? "a T3 Code machine") · \(found.environmentId.prefix(8))… at \(found.origin.host)")
                        .font(.system(size: 12)).foregroundStyle(Color(red: 0.65, green: 0.89, blue: 0.42))
                    Text(verbatim: "Anyone can repeat a machine’s id, so check the name is the machine you mean.")
                        .font(.system(size: 11)).foregroundStyle(Theme.grey)
                }
                step(3, done: model.connectedMachineIds.contains(found.environmentId), "Sign in on that machine") {
                    Text(verbatim: "On \(found.label ?? "that machine"), run:").font(.system(size: 11.5)).foregroundStyle(Theme.grey)
                    HStack(alignment: .top) {
                        Text(verbatim: Self.pairingCommand).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.terminal)).textSelection(.enabled)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Self.pairingCommand, forType: .string) } label: {
                            Image(systemName: "doc.on.doc").foregroundStyle(Theme.grey).padding(6)
                        }.buttonStyle(.plain).help("Copy")
                    }
                    Text(verbatim: "Then open its sign-in page, paste the code there and choose the access level your threads use (usually Auto).")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
                    if model.connectedMachineIds.contains(found.environmentId) {
                        HStack { Text(verbatim: "Connected.").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.lime); Spacer()
                            Button { flow.reset() } label: { Pill(text: "Done", fill: Theme.lime) }.buttonStyle(.plain) }
                    } else if case .waitingForBrowser? = model.machineSignIns[found.environmentId] {
                        HStack { Spinner(size: 14); Text(verbatim: "Approve it in your browser…").font(.system(size: 12)).foregroundStyle(Theme.grey); Spacer()
                            Button { model.cancelMachineSignIn(found.environmentId) } label: { Pill(text: "Cancel", fill: Color.white.opacity(0.12), fg: .white) }.buttonStyle(.plain) }
                    } else {
                        if case .failed(let msg)? = model.machineSignIns[found.environmentId] {
                            Text(verbatim: msg).font(.system(size: 11.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                        }
                        Button { model.connectMachine(found) } label: { Pill(text: "Open sign-in page", fill: Theme.lime) }.buttonStyle(.plain)
                    }
                }
                step(4, done: model.remoteApprovalStatus(found.environmentId) == .on, "Allow / Deny too? (optional)") {
                    Text(verbatim: "Needs a second pairing code from that machine. Set it up in the machine’s row.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.grey)
                }
            }
        }
    }

    @ViewBuilder private func step<C: View>(_ n: Int, done: Bool, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(verbatim: done ? "✓" : "\(n)").font(.system(size: 10.5, weight: .heavy)).foregroundStyle(done ? .black : .white)
                .frame(width: 18, height: 18).background(Circle().fill(done ? Theme.lime : Color.white.opacity(0.15)))
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                content()
            }
        }
    }
}

/// Menu-bar and Machines window: forget this Mac's sign-in, after saying what that does.
@MainActor func confirmSignOutThisMac(_ model: HuddleModel) {
    let alert = NSAlert()
    alert.messageText = "Sign out of T3 Code on this Mac?"
    alert.informativeText = "Agent Huddle forgets its sign-in on this Mac, so you can sign in again at a different access level. "
        + "T3 keeps the session until you revoke it (t3 auth session list, then t3 auth session revoke <id>). Other machines and inline approvals are not affected."
    alert.addButton(withTitle: "Sign Out")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    model.signOut()
}
