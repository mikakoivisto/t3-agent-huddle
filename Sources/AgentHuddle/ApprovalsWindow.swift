import SwiftUI
import AppKit
import HuddleCore

// One window for inline approvals: this Mac and every linked machine, each with its own state and setup.
// Nothing here creates credentials: the user makes a pairing code on the machine in question.

@MainActor
final class ApprovalsWindowController {
    static let shared = ApprovalsWindowController()
    private var window: NSWindow?

    func show(model: HuddleModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Inline approvals"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ApprovalsView(model: model))
            w.contentMinSize = NSSize(width: 540, height: 360)
            w.contentMaxSize = NSSize(width: 540, height: 4000)
            w.backgroundColor = NSColor(Theme.panel)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the window draws. The live window builds it from the model; snapshots pass one in.
struct ApprovalsSnapshotData {
    struct Machine: Identifiable { var id: String; var name: String; var status: HuddleModel.MachineApprovalStatus; var saved: String?; var found: [String] }
    var thisMacName: String
    var thisMacOn: Bool
    var machines: [Machine]
    var open: String?
    var checks: [String: HuddleModel.AddressCheck] = [:]
    var chosen: String?
}

private enum WarningCopy { static let warning = "Besides answering approvals this login could also send messages to, launch and interrupt threads on that machine. Agent Huddle only ever uses it to answer approvals. It is kept in this Mac’s Keychain." }

struct ApprovalsView: View {
    @ObservedObject var model: HuddleModel
    var snapshot: ApprovalsSnapshotData?
    @Environment(\.snapshotMode) private var snapshotMode

    @State private var open: String?                       // "this", a machine id, or "discover"
    @State private var code = ""
    @State private var busy = false
    @State private var note: String?
    @State private var chosen: [String: String] = [:]      // machine id → chosen address
    @State private var typed: [String: String] = [:]       // machine id → typed address
    @State private var checks: [String: HuddleModel.AddressCheck] = [:]   // "machine id|address" → result: a result for one machine says nothing about another
    @State private var trustTyped: [String: Bool] = [:]                    // machine id → the user vouches for an address T3 did not list
    @State private var checkTasks: [String: Task<Void, Never>] = [:]
    @State private var farewell: [String: String] = [:]

    private var thisMacName: String { snapshot?.thisMacName ?? model.environments.first(where: \.isLocal)?.label ?? "This Mac" }
    private var thisMacOn: Bool { snapshot?.thisMacOn ?? model.inlineApprovals }
    private var machines: [ApprovalsSnapshotData.Machine] {
        if let snapshot { return snapshot.machines }
        return model.approvalMachines.map { m in
            ApprovalsSnapshotData.Machine(id: m.id, name: m.label, status: model.remoteApprovalStatus(m.id),
                                          saved: model.savedAddress(forEnvironment: m.id), found: model.discoveredUrls[m.id] ?? [])
        }
    }
    private var openRow: String? { snapshot?.open ?? open }
    private var allChecks: [String: HuddleModel.AddressCheck] { snapshot?.checks ?? checks }

    var body: some View {
        Group { if snapshotMode { inner } else { ScrollView { inner } } }
            .frame(width: 540)
            .background(Theme.panel)
            .preferredColorScheme(.dark)
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Inline approvals").font(.system(size: 20, weight: .heavy)).foregroundStyle(.white)
                Text(verbatim: "Allow and Deny in the panel. Each machine has its own login, so set up each one you want. Without it, a thread there shows “Review in T3 Code”.")
                    .font(.system(size: 13)).foregroundStyle(Theme.grey).padding(.top, 2).padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)

                section("This Mac")
                thisMacRow

                HStack {
                    section("Linked machines")
                    Spacer()
                    if !machines.isEmpty { Button { toggle("discover") } label: { smallPill(openRow == "discover" ? "Cancel" : "Find addresses…") }.buttonStyle(.plain) }
                }
                if openRow == "discover" { discoverCard }
                if machines.isEmpty {
                    Text(verbatim: "No other machine is linked. Link one in T3 Code (Settings → Connections), then it shows up here.")
                        .font(.system(size: 13)).foregroundStyle(Theme.grey).padding(12)
                } else {
                    ForEach(machines) { machineRow($0) }
                }
        }
        .padding(18)
    }

    // MARK: Rows

    private var thisMacRow: some View {
        card {
            header(name: thisMacName, meta: "Threads that run on this Mac", chip: thisMacOn ? .on : .off) {
                if thisMacOn { Button { turnOffThisMac() } label: { smallPill("Turn off", ghost: true) }.buttonStyle(.plain) }
                else { Button { toggle("this") } label: { smallPill(openRow == "this" ? "Cancel" : "Set up…", ghost: openRow == "this") }.buttonStyle(.plain) }
            }
            if let f = farewell["this"] { Text(verbatim: f).font(.system(size: 12)).foregroundStyle(Theme.grey).padding(.top, 8).fixedSize(horizontal: false, vertical: true) }
            if openRow == "this", !thisMacOn {
                divider
                step(1, "In a terminal on this Mac, run:") { commandBox(ApprovalEnrollment.pairingCommand) }
                step(2, "Paste the code it prints") { codeField() }
                warningBox
                errorLine
                HStack { Spacer(); actionButton("Turn on", enabled: !code.isEmpty && !busy) { turnOnThisMac() } }
            }
        }
    }

    private func machineRow(_ m: ApprovalsSnapshotData.Machine) -> some View {
        let meta: String = {
            switch m.status {
            case .on: return (m.saved.map { host($0) } ?? "address saved") + " · login saved"
            case .needsRepair: return "T3 refused the saved login. Pair again."
            case .off: return m.found.isEmpty ? "address not found · type it when you set up"
                                              : "\(m.found.count) address\(m.found.count == 1 ? "" : "es") found · not set up"
            }
        }()
        return card {
            header(name: m.name, meta: meta, chip: m.status == .on ? .on : m.status == .needsRepair ? .warn : .off) {
                if m.status == .on { Button { turnOff(m) } label: { smallPill("Turn off", ghost: true) }.buttonStyle(.plain) }
                else { Button { toggle(m.id, machine: m) } label: { smallPill(openRow == m.id ? "Cancel" : "Set up…", ghost: openRow == m.id) }.buttonStyle(.plain) }
            }
            if let f = farewell[m.id] { Text(verbatim: f).font(.system(size: 12)).foregroundStyle(Theme.grey).padding(.top, 8).fixedSize(horizontal: false, vertical: true) }
            if openRow == m.id, m.status != .on { setupBody(m) }
        }
    }

    @ViewBuilder private func setupBody(_ m: ApprovalsSnapshotData.Machine) -> some View {
        let candidates = candidateList(m)
        let current = snapshot?.chosen ?? chosen[m.id] ?? candidates.first ?? ""
        divider
        step(1, "Address of \(m.name)’s T3 Code (https)") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(candidates, id: \.self) { a in
                    Button { chosen[m.id] = a } label: {
                        HStack(spacing: 8) {
                            Circle().strokeBorder(Theme.grey, lineWidth: 1.5).background(Circle().fill(current == a && typed[m.id, default: ""].isEmpty ? Theme.lime : .clear)).frame(width: 12, height: 12)
                            Text(verbatim: a).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            checkLabel(allChecks[Self.checkKey(m.id, a)])
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7).background(RoundedRectangle(cornerRadius: 9).fill(Theme.cardRaised))
                    }.buttonStyle(.plain)
                }
                otherAddressField(m, hasCandidates: !candidates.isEmpty)
                if !candidates.isEmpty {
                    Text(verbatim: "The addresses in this list are the ones T3 linked this machine at. A host that answers with the right machine id is not proof: any host on your network can repeat that id.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
                }
                if !isListed(m, address(m)) && !address(m).isEmpty {
                    Button { trustTyped[m.id] = !(trustTyped[m.id] ?? false) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: (snapshot == nil ? (trustTyped[m.id] ?? false) : false) ? "checkmark.square.fill" : "square").foregroundStyle(Theme.lime)
                            Text(verbatim: "I typed this address myself. T3 did not list it for this machine, and I trust that it is \(m.name).")
                                .font(.system(size: 12)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        step(2, "On \(m.name) (not on this Mac), run once:") { commandBox(RemoteApprovalEnrollment.pairingCommand) }
        step(3, "Paste the code it prints") { codeField() }
        warningBox
        errorLine
        HStack { Spacer(); actionButton("Turn on", enabled: canTurnOn(m)) { turnOn(m) } }
    }

    /// Turn on needs a code, an address that answered as this machine, and either an address T3 listed or the user's confirmation.
    private func canTurnOn(_ m: ApprovalsSnapshotData.Machine) -> Bool {
        let a = address(m)
        guard !code.isEmpty, !busy, !a.isEmpty else { return false }
        guard checks[Self.checkKey(m.id, a)] == .thisMachine else { return false }
        return isListed(m, a) || (trustTyped[m.id] ?? false)
    }
    private func isListed(_ m: ApprovalsSnapshotData.Machine, _ address: String) -> Bool {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return candidateList(m).contains { norm($0) == norm(address) }
    }
    static func checkKey(_ machineId: String, _ address: String) -> String {
        "\(machineId)|\(address.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private var discoverCard: some View {
        card {
            Text(verbatim: "T3 Code doesn’t share linked machines’ addresses with Agent Huddle’s normal connection. A one-time, read-only code from this Mac lets it read the list once. Skip this and type the addresses instead if you prefer.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
            step(1, "In a terminal on this Mac, run:") { commandBox(PeerLinkDiscovery.pairingCommand) }.padding(.top, 10)
            step(2, "Paste the code it prints") { codeField() }
            Text(verbatim: "It can read the names and addresses of linked machines and which sessions exist. It cannot send, launch or change anything and never sees a credential. T3 doesn’t let a client revoke its own session, so it stays valid for about 30 days: revoke the one labelled “\(PeerLinkDiscovery.label)” with t3 auth session revoke.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            errorLine
            HStack { Spacer(); actionButton("Find addresses", enabled: !code.isEmpty && !busy) { discover() } }
        }
    }

    // MARK: Pieces

    private enum Chip { case on, off, warn }

    private func header<A: View>(name: String, meta: String, chip: Chip, @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(.system(size: 15, weight: .heavy)).foregroundStyle(.white).lineLimit(1)
                Text(verbatim: meta).font(.system(size: 12)).foregroundStyle(Theme.grey).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            chipView(chip)
            action()
        }
    }

    private func chipView(_ c: Chip) -> some View {
        let (text, fg, bg): (String, Color, Color) = {
            switch c {
            case .on: return ("On", Theme.lime, Theme.lime.opacity(0.14))
            case .off: return ("Off", Theme.grey, Color.white.opacity(0.08))
            case .warn: return ("Needs re-pair", Color(red: 0.94, green: 0.66, blue: 0.23), Color(red: 0.94, green: 0.66, blue: 0.23).opacity(0.15))
            }
        }()
        return Text(verbatim: text).font(.system(size: 11, weight: .heavy)).foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(bg))
    }

    private func smallPill(_ t: String, ghost: Bool = false) -> some View {
        Text(verbatim: t).font(.system(size: 12.5, weight: .heavy)).foregroundStyle(ghost ? Color.white : Color.black)
            .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(ghost ? Color.white.opacity(0.10) : Theme.lime))
    }

    private func actionButton(_ t: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { smallPill(busy ? "Working…" : t) }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }

    private func section(_ t: String) -> some View {
        Text(verbatim: t.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Theme.grey).padding(.top, 14).padding(.bottom, 6)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .padding(.bottom, 8)
    }

    private var divider: some View { Divider().overlay(Color.white.opacity(0.10)).padding(.vertical, 10) }

    private func step<C: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(verbatim: "\(n)").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white).frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.12))).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title).font(.system(size: 12.5)).foregroundStyle(Theme.grey)
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.bottom, 10)
    }

    private func commandBox(_ cmd: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: cmd).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color(white: 0.92))
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
            } label: { Text(verbatim: "Copy").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(Color.white.opacity(0.12))) }
                .buttonStyle(.plain)
        }
        .padding(9).background(RoundedRectangle(cornerRadius: 9).fill(Theme.terminal))
    }

    @ViewBuilder private func codeField() -> some View {
        if snapshotMode {
            Text(verbatim: "••••••••••••").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(9).background(RoundedRectangle(cornerRadius: 9).fill(Theme.terminal))
        } else {
            SecureField("Pairing code", text: $code).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                .padding(9).background(RoundedRectangle(cornerRadius: 9).fill(Theme.terminal)).disabled(busy)
        }
    }

    @ViewBuilder private func otherAddressField(_ m: ApprovalsSnapshotData.Machine, hasCandidates: Bool) -> some View {
        if snapshotMode {
            Text(verbatim: hasCandidates ? "Other address…" : "https://machine.tailnet.ts.net").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(9).background(RoundedRectangle(cornerRadius: 9).fill(Theme.terminal))
        } else {
            TextField(hasCandidates ? "Other address…" : "https://machine.tailnet.ts.net",
                      text: Binding(get: { typed[m.id, default: ""] }, set: { typed[m.id] = $0; trustTyped[m.id] = false; scheduleCheck($0, m.id) }))
                .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced)).padding(9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.terminal))
                .onSubmit { Task { await check(typed[m.id, default: ""], m.id) } }
        }
    }

    @ViewBuilder private func checkLabel(_ c: HuddleModel.AddressCheck?) -> some View {
        switch c {
        case .thisMachine?: Text(verbatim: "answers as this machine ✓").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.lime)
        case .otherMachine?: Text(verbatim: "different machine").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(red: 0.94, green: 0.66, blue: 0.23))
        case .unreachable?: Text(verbatim: "not reachable").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(red: 0.94, green: 0.66, blue: 0.23))
        case .invalid(let why)?: Text(verbatim: String(why.prefix(40))).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.red)
        case nil: Text(verbatim: "checking…").font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
    }

    private var warningBox: some View {
        Text(verbatim: "Broader than the normal login: " + WarningCopy.warning)
            .font(.system(size: 11.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05))).padding(.bottom, 10)
    }

    @ViewBuilder private var errorLine: some View {
        if let note { Text(verbatim: note).font(.system(size: 12)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8) }
    }

    // MARK: Logic

    private func host(_ origin: String) -> String { URL(string: origin)?.host ?? origin }

    private func candidateList(_ m: ApprovalsSnapshotData.Machine) -> [String] {
        if snapshot != nil { return m.found }
        return model.candidateAddresses(forEnvironment: m.id)
    }

    private func address(_ m: ApprovalsSnapshotData.Machine) -> String {
        let t = typed[m.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? (chosen[m.id] ?? candidateList(m).first ?? "") : t
    }

    private func toggle(_ id: String, machine: ApprovalsSnapshotData.Machine? = nil) {
        code = ""; note = nil
        if open == id { open = nil; return }
        open = id
        if let m = machine { Task { for a in candidateList(m) { await check(a, m.id) } } }
    }

    private func check(_ address: String, _ machineId: String) async {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        let key = Self.checkKey(machineId, a)
        checks[key] = nil
        let result = await model.checkAddress(a, environmentId: machineId)
        if !Task.isCancelled { checks[key] = result }
    }
    /// Checks a typed address shortly after the user stops typing, replacing any check still running for that machine.
    private func scheduleCheck(_ address: String, _ machineId: String) {
        checkTasks[machineId]?.cancel()
        checkTasks[machineId] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { await check(address, machineId) }
        }
    }

    private func fail(_ error: Error) { note = (error as? HuddleError)?.description ?? error.localizedDescription }

    private func turnOnThisMac() {
        let c = code; code = ""; busy = true; note = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await model.enableInlineApprovals(pairingCode: c); open = nil; farewell["this"] = nil }
            catch { fail(error) }
        }
    }

    private func turnOffThisMac() {
        guard model.disableInlineApprovals() else {
            farewell["this"] = "The Keychain would not let Agent Huddle remove the login, so inline approvals are still on. Try again, or remove the “app.t3huddle.AgentHuddle / vault” item in Keychain Access (that also signs Agent Huddle out)."
            return
        }
        farewell["this"] = "Login removed from this Mac’s Keychain. T3 doesn’t let Agent Huddle revoke its own session, so run `t3 auth session list`, then `t3 auth session revoke <id>` for the one labelled “Agent Huddle approvals”."
    }

    private func turnOn(_ m: ApprovalsSnapshotData.Machine) {
        let c = code, addr = address(m); code = ""; busy = true; note = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await model.enableRemoteApprovals(environmentId: m.id, address: addr, pairingCode: c,
                                                      acknowledgeUnlisted: !isListed(m, addr) && (trustTyped[m.id] ?? false))
                open = nil; farewell[m.id] = nil
            }
            catch { fail(error) }
        }
    }

    private func turnOff(_ m: ApprovalsSnapshotData.Machine) {
        guard model.disableRemoteApprovals(environmentId: m.id) else {
            farewell[m.id] = "The Keychain would not let Agent Huddle remove \(m.name)’s login, so it is still saved. Try again, or remove the “app.t3huddle.AgentHuddle / vault” item in Keychain Access (that also signs Agent Huddle out)."
            return
        }
        farewell[m.id] = "Login removed from this Mac’s Keychain. Also revoke the session on \(m.name): run `t3 auth session list` there, then `t3 auth session revoke <id>` for the one labelled “Agent Huddle approvals”."
    }

    private func discover() {
        let c = code; code = ""; busy = true; note = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let n = try await model.discoverPeerAddresses(pairingCode: c)
                open = nil
                if n == 0 { note = nil }
            } catch { fail(error) }
        }
    }
}
