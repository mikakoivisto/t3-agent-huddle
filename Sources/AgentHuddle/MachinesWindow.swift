import SwiftUI
import AppKit
import HuddleCore

// Machines (spec 15): T3 on this Mac or on any other machine, each reached through its own MCP. One row per machine with its
// sign-in (answers and messages) and its optional inline approvals; "Add machine" signs in to another machine's T3.
// Nothing here holds a credential: the user makes a pairing code on the machine and pastes it into that machine's T3 page.

/// The Machines window is now the Settings window's Machines tab (spec 14); this keeps the existing call sites.
@MainActor
final class MachinesWindowController {
    static let shared = MachinesWindowController()
    func show(model: HuddleModel, adding address: String? = nil) {
        SettingsWindowController.shared.show(model: model, tab: .machines, adding: address)
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
    @ObservedObject var setup: ApprovalSetup
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Each machine is reached through its own T3 Code. Connect one to answer and message its threads from the panel.")
                .font(.system(size: 12)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
            ThisMacMachineRow(model: model, setup: setup)
            ForEach(model.otherMachineIds, id: \.self) { id in OtherMachineRow(model: model, flow: flow, setup: setup, id: id) }
            if flow.open { AddMachineCard(model: model, flow: flow) }
            if setup.open == ApprovalSetup.discover { FindAddressesCard(setup: setup) }
            HStack(spacing: 8) {
                Spacer()
                if setup.open != ApprovalSetup.discover, !model.linkedMachines.isEmpty {
                    Button { setup.toggle(ApprovalSetup.discover) } label: { Pill(text: "Find addresses…", fill: Color.white.opacity(0.08), fg: Theme.grey) }
                        .buttonStyle(.plain).help("Read the addresses this Mac’s T3 linked each machine at, once")
                }
                if !flow.open {
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

struct ThisMacMachineRow: View {
    @ObservedObject var model: HuddleModel
    @ObservedObject var setup: ApprovalSetup
    var body: some View {
        MachineCard {
            HStack(spacing: 8) {
                Text(verbatim: model.localEnvironmentName ?? "This Mac").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                MachineBadgeView(badge: .thisMac)
                Spacer()
                Text(verbatim: "loopback").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            switch model.state.connection {
            case .connected:
                FeatureLine(icon: "bubble.left.and.bubble.right", title: "Connected", detail: "Answer questions and message its threads.", chip: .on) {
                    Button { confirmSignOutThisMac(model) } label: { Pill(text: "Sign out", fill: Color.white.opacity(0.12), fg: .white) }.buttonStyle(.plain)
                }
            case .unauthorized:
                FeatureLine(icon: "bubble.left.and.bubble.right", title: model.signingIn ? "Connecting…" : "Not connected",
                            detail: model.signingIn ? "Approve Agent Huddle in your browser." : "T3 Code runs here. Connect to see and answer its threads.",
                            chip: model.signingIn ? .settingUp : .off) {
                    if model.signingIn {
                        Button { model.cancelSignIn() } label: { Pill(text: "Cancel", fill: Color.white.opacity(0.12), fg: .white) }.buttonStyle(.plain)
                    } else {
                        Button { model.signIn() } label: { Pill(text: "Connect", fill: Theme.lime) }.buttonStyle(.plain)
                    }
                }
            case .notRunning:
                FeatureLine(icon: "bubble.left.and.bubble.right", title: "Not connected", detail: "T3 Code isn’t running on this Mac.", chip: .off) { EmptyView() }
            default:
                FeatureLine(icon: "bubble.left.and.bubble.right", title: "Not connected", detail: model.state.connection.headline ?? "Connecting…", chip: .off) { EmptyView() }
            }
            if model.state.connection == .connected {
                ApprovalFeature(model: model, setup: setup, machineId: nil, name: model.localEnvironmentName ?? "This Mac")
            }
            if let note = model.connectNote {
                Text(verbatim: note).font(.system(size: 11.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
    }
}

struct OtherMachineRow: View {
    @ObservedObject var model: HuddleModel
    @ObservedObject var flow: AddMachineFlow
    @ObservedObject var setup: ApprovalSetup
    var id: String
    var body: some View {
        let badge = model.machineBadge(id)
        let connected = model.connectedMachineIds.contains(id)
        MachineCard {
            HStack(spacing: 8) {
                Text(verbatim: model.machineLabel(id)).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                MachineBadgeView(badge: badge)
                Spacer()
                if let origin = model.suggestedAddress(id) {
                    Text(verbatim: URL(string: origin)?.host ?? origin).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
                }
            }
            FeatureLine(icon: "bubble.left.and.bubble.right", title: connected ? "Connected" : "Not connected",
                        detail: detail(badge, connected), chip: chip(badge, connected)) {
                if case .waitingForBrowser? = model.machineSignIns[id] {
                    Button { model.cancelMachineSignIn(id) } label: { Pill(text: "Cancel", fill: Color.white.opacity(0.12), fg: .white) }.buttonStyle(.plain)
                } else if connected {
                    Button { _ = model.signOutMachine(id) } label: { Pill(text: "Sign out", fill: Color.white.opacity(0.12), fg: .white) }.buttonStyle(.plain)
                } else {
                    Button { flow.start(address: model.suggestedAddress(id) ?? "") } label: { Pill(text: "Connect…", fill: Theme.lime) }.buttonStyle(.plain)
                }
            }
            if case .failed(let msg)? = model.machineSignIns[id] {
                Text(verbatim: msg).font(.system(size: 11.5)).foregroundStyle(Theme.red).lineLimit(2).padding(.top, 4)
            }
            if model.approvalMachines.contains(where: { $0.id == id }) {
                ApprovalFeature(model: model, setup: setup, machineId: id, name: model.machineLabel(id))
            }
        }
    }

    private func chip(_ badge: MachineBadge, _ connected: Bool) -> FeatureChip {
        if case .waitingForBrowser? = model.machineSignIns[id] { return .settingUp }
        switch badge {
        case .signInExpired, .offline, .unsupported: return .warn
        default: return connected ? .on : .off
        }
    }

    private func detail(_ badge: MachineBadge, _ connected: Bool) -> String {
        if case .waitingForBrowser? = model.machineSignIns[id] { return "Approve it in your browser." }
        switch badge {
        case .signInExpired: return "T3 refused the saved sign-in. Connect again."
        case .offline:
            if case .offline(let why)? = model.machineStatus[id] { return "Signed in, but not reachable. \(why)" }
            return "Signed in, but not reachable."
        case .linkedOnly: return "Its threads are read-only here until you connect it."
        case .unsupported: return "Unsupported T3 Code version."
        default: return connected ? "Answer questions and message its threads." : "Connect to answer and message its threads."
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
