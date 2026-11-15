import SwiftUI
import AppKit
import HuddleCore

// "Approve commands from the panel" (inline approvals, specs 06 and 07), set up inside each machine's row of the Settings
// window's Machines tab. Nothing here creates credentials: the user makes a pairing code on the machine in question.

private enum WarningCopy {
    static func text(_ machine: String) -> String {
        "This needs its own login on \(machine)’s T3. Besides approving, that login could also send to, launch and interrupt threads there. Agent Huddle only ever uses it to Allow or Deny, on your click. It is kept in this Mac’s Keychain."
    }
}

/// The state of the approvals setup in the Machines tab: which row is open, the code being pasted, address checks.
@MainActor
final class ApprovalSetup: ObservableObject {
    static let thisMac = "this"
    static let discover = "discover"

    @Published var open: String?                       // ApprovalSetup.thisMac, a machine id, or ApprovalSetup.discover
    @Published var code = ""
    @Published var busy = false
    @Published var note: String?
    @Published var chosen: [String: String] = [:]      // machine id → chosen address
    @Published var typed: [String: String] = [:]       // machine id → typed address
    @Published var checks: [String: HuddleModel.AddressCheck] = [:]   // "machine id|address" → result
    @Published var trustTyped: [String: Bool] = [:]    // machine id → the user vouches for an address T3 did not list
    @Published var farewell: [String: String] = [:]
    private var checkTasks: [String: Task<Void, Never>] = [:]
    let model: HuddleModel

    init(model: HuddleModel) { self.model = model }

    static func checkKey(_ machineId: String, _ address: String) -> String {
        "\(machineId)|\(address.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func candidates(_ id: String) -> [String] { model.candidateAddresses(forEnvironment: id) }

    func address(_ id: String) -> String {
        let t = typed[id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? (chosen[id] ?? candidates(id).first ?? "") : t
    }

    func isListed(_ id: String, _ address: String) -> Bool {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return candidates(id).contains { norm($0) == norm(address) }
    }

    /// Turn on needs a code, an address that answered as this machine, and either an address T3 listed or the user's confirmation.
    func canTurnOn(_ id: String) -> Bool {
        let a = address(id)
        guard !code.isEmpty, !busy, !a.isEmpty else { return false }
        guard checks[Self.checkKey(id, a)] == .thisMachine else { return false }
        return isListed(id, a) || (trustTyped[id] ?? false)
    }

    func toggle(_ id: String, checkMachine: Bool = false) {
        code = ""; note = nil
        if open == id { open = nil; return }
        open = id
        if checkMachine { Task { for a in candidates(id) { await check(a, id) } } }
    }

    func check(_ address: String, _ machineId: String) async {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        let key = Self.checkKey(machineId, a)
        checks[key] = nil
        let result = await model.checkAddress(a, environmentId: machineId)
        if !Task.isCancelled { checks[key] = result }
    }

    /// Checks a typed address shortly after the user stops typing, replacing any check still running for that machine.
    func scheduleCheck(_ address: String, _ machineId: String) {
        checkTasks[machineId]?.cancel()
        checkTasks[machineId] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { await check(address, machineId) }
        }
    }

    private func fail(_ error: Error) { note = (error as? HuddleError)?.description ?? error.localizedDescription }

    func turnOnThisMac() {
        let c = code; code = ""; busy = true; note = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await model.enableInlineApprovals(pairingCode: c); open = nil; farewell[Self.thisMac] = nil }
            catch { fail(error) }
        }
    }

    func turnOffThisMac() {
        guard model.disableInlineApprovals() else {
            farewell[Self.thisMac] = "The Keychain would not let Agent Huddle remove the login, so it is still on. Try again, or remove the “app.t3huddle.AgentHuddle / vault” item in Keychain Access (that also signs Agent Huddle out)."
            return
        }
        farewell[Self.thisMac] = "Login removed. T3 doesn’t let Agent Huddle revoke its own session, so run `t3 auth session list`, then `t3 auth session revoke <id>` for the one labelled “Agent Huddle approvals”."
    }

    func turnOn(_ id: String) {
        let c = code, addr = address(id); code = ""; busy = true; note = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await model.enableRemoteApprovals(environmentId: id, address: addr, pairingCode: c,
                                                      acknowledgeUnlisted: !isListed(id, addr) && (trustTyped[id] ?? false))
                open = nil; farewell[id] = nil
            } catch { fail(error) }
        }
    }

    func turnOff(_ id: String, name: String) {
        guard model.disableRemoteApprovals(environmentId: id) else {
            farewell[id] = "The Keychain would not let Agent Huddle remove \(name)’s login, so it is still saved. Try again, or remove the “app.t3huddle.AgentHuddle / vault” item in Keychain Access (that also signs Agent Huddle out)."
            return
        }
        farewell[id] = "Login removed. Also revoke the session on \(name): run `t3 auth session list` there, then `t3 auth session revoke <id>` for the one labelled “Agent Huddle approvals”."
    }

    func discover() {
        let c = code; code = ""; busy = true; note = nil
        Task { @MainActor in
            defer { busy = false }
            do { _ = try await model.discoverPeerAddresses(pairingCode: c); open = nil }
            catch { fail(error) }
        }
    }
}

// MARK: - Feature lines

enum FeatureChip { case on, off, warn, settingUp }

/// One feature of a machine: icon, what it is, one line about it, a state chip and one button.
struct FeatureLine<Trailing: View>: View {
    var icon: String
    var title: String
    var detail: String
    var chip: FeatureChip
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 5) {
                FeatureChipView(chip: chip)
                trailing()
            }
        }
        .padding(.top, 9)
        .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1), alignment: .top)
        .padding(.top, 9)
    }
}

struct FeatureChipView: View {
    var chip: FeatureChip
    var body: some View {
        let (text, fg, bg): (String, Color, Color) = {
            switch chip {
            case .on: return ("On", Theme.lime, Theme.lime.opacity(0.14))
            case .off: return ("Off", Theme.grey, Color.white.opacity(0.08))
            case .warn: return ("Needs re-pairing", Theme.steer, Theme.steer.opacity(0.15))
            case .settingUp: return ("Setting up", Theme.grey, Color.white.opacity(0.08))
            }
        }()
        Text(verbatim: text).font(.system(size: 11, weight: .bold)).foregroundStyle(fg).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(bg))
    }
}

/// "Approve commands from the panel" for this Mac (`machineId` nil) or another machine, with its setup opening in place.
struct ApprovalFeature: View {
    @ObservedObject var model: HuddleModel
    @ObservedObject var setup: ApprovalSetup
    var machineId: String?
    var name: String
    @Environment(\.snapshotMode) private var snapshotMode

    private var key: String { machineId ?? ApprovalSetup.thisMac }
    private var status: HuddleModel.MachineApprovalStatus {
        guard let machineId else { return model.inlineApprovals ? .on : .off }
        return model.remoteApprovalStatus(machineId)
    }
    private var isOpen: Bool { setup.open == key && status != .on }

    var body: some View {
        let detail = status == .needsRepair ? "T3 refused the saved approval login (revoked or expired). Pair it again."
            : "Allow or Deny what an agent wants to run, without opening T3 Code."
        VStack(alignment: .leading, spacing: 0) {
            FeatureLine(icon: "hand.raised", title: "Approve commands from the panel", detail: detail,
                        chip: isOpen ? .settingUp : status == .on ? .on : status == .needsRepair ? .warn : .off) {
                if status == .on {
                    Button { if let machineId { setup.turnOff(machineId, name: name) } else { setup.turnOffThisMac() } } label: {
                        Pill(text: "Turn off", fill: Theme.red.opacity(0.2), fg: Color(red: 1, green: 0.62, blue: 0.62))
                    }.buttonStyle(.plain)
                } else if !isOpen {
                    Button { setup.toggle(key, checkMachine: machineId != nil) } label: {
                        Pill(text: status == .needsRepair ? "Re-pair…" : "Turn on…", fill: Color.white.opacity(0.12), fg: .white)
                    }.buttonStyle(.plain)
                }
            }
            if let f = setup.farewell[key] {
                Text(verbatim: f).font(.system(size: 11.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6).padding(.leading, 31)
            }
            if isOpen { setupBody.padding(.top, 8).padding(.leading, 31) }
        }
    }

    @ViewBuilder private var setupBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: WarningCopy.text(machineId == nil ? "this Mac" : name)).font(.system(size: 11))
                .foregroundStyle(Color(red: 0.91, green: 0.75, blue: 0.54)).fixedSize(horizontal: false, vertical: true)
                .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.steer.opacity(0.08)))
            if let machineId {
                step(1, "Address of \(name)’s T3 Code (https)") { addressPicker(machineId) }
                step(2, "On \(name) (not on this Mac), run once:") { commandBox(RemoteApprovalEnrollment.pairingCommand) }
                step(3, "Paste the code it prints") { codeField }
            } else {
                step(1, "On this Mac, run:") { commandBox(ApprovalEnrollment.pairingCommand) }
                step(2, "Paste the code it prints") { codeField }
            }
            if let note = setup.note {
                Text(verbatim: note).font(.system(size: 11.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer()
                Button { setup.toggle(key) } label: { Pill(text: "Cancel", fill: Color.white.opacity(0.12), fg: .white) }.buttonStyle(.plain)
                let enabled = machineId.map { setup.canTurnOn($0) } ?? (!setup.code.isEmpty && !setup.busy)
                Button { if let machineId { setup.turnOn(machineId) } else { setup.turnOnThisMac() } } label: {
                    Pill(text: setup.busy ? "Working…" : "Turn on", fill: Theme.lime)
                }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.125)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder private func addressPicker(_ id: String) -> some View {
        let candidates = setup.candidates(id)
        let current = setup.chosen[id] ?? candidates.first ?? ""
        VStack(alignment: .leading, spacing: 5) {
            ForEach(candidates, id: \.self) { a in
                Button { setup.chosen[id] = a } label: {
                    HStack(spacing: 7) {
                        Circle().strokeBorder(Theme.grey, lineWidth: 1.5)
                            .background(Circle().fill(current == a && setup.typed[id, default: ""].isEmpty ? Theme.lime : .clear)).frame(width: 11, height: 11)
                        Text(verbatim: a).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        checkLabel(setup.checks[ApprovalSetup.checkKey(id, a)])
                    }
                }.buttonStyle(.plain)
            }
            if snapshotMode {
                let typed = setup.typed[id, default: ""]
                Text(verbatim: typed.isEmpty ? (candidates.isEmpty ? "https://machine.tailnet.ts.net" : "Other address…") : typed)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(typed.isEmpty ? Theme.dim : .white)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(7).background(RoundedRectangle(cornerRadius: 6).fill(Theme.terminal))
            } else {
                TextField(candidates.isEmpty ? "https://machine.tailnet.ts.net" : "Other address…",
                          text: Binding(get: { setup.typed[id, default: ""] },
                                        set: { setup.typed[id] = $0; setup.trustTyped[id] = false; setup.scheduleCheck($0, id) }))
                    .textFieldStyle(.plain).font(.system(size: 11.5, design: .monospaced)).padding(7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.terminal))
            }
            let a = setup.address(id)
            if !setup.typed[id, default: ""].isEmpty { checkLabel(setup.checks[ApprovalSetup.checkKey(id, a)]) }
            if !a.isEmpty && !setup.isListed(id, a) {
                Button { setup.trustTyped[id] = !(setup.trustTyped[id] ?? false) } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: (setup.trustTyped[id] ?? false) ? "checkmark.square.fill" : "square").foregroundStyle(Theme.lime)
                        Text(verbatim: "I typed this address myself. T3 did not list it for this machine, and I trust that it is \(name).")
                            .font(.system(size: 11)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    }
                }.buttonStyle(.plain)
            } else if !candidates.isEmpty {
                Text(verbatim: "These are the addresses T3 linked this machine at. A host that answers with the right id is not proof on its own.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func checkLabel(_ c: HuddleModel.AddressCheck?) -> some View {
        switch c {
        case .thisMachine?: Text(verbatim: "✓ answers as \(name)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.lime).lineLimit(1)
        case .otherMachine?: Text(verbatim: "different machine").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.steer)
        case .unreachable?: Text(verbatim: "✗ not reachable").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.steer)
        case .invalid(let why)?: Text(verbatim: String(why.prefix(40))).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.red)
        case nil: Text(verbatim: "checking…").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
        }
    }

    private func step<C: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(n)").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.white).frame(width: 16, height: 16)
                .background(Circle().fill(Color.white.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title).font(.system(size: 11.5)).foregroundStyle(Theme.grey)
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func commandBox(_ cmd: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: cmd).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(white: 0.92))
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(Theme.grey).padding(3)
            }.buttonStyle(.plain).help("Copy")
        }
        .padding(7).background(RoundedRectangle(cornerRadius: 6).fill(Theme.terminal))
    }

    @ViewBuilder private var codeField: some View {
        if snapshotMode {
            Text(verbatim: "pairing code").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(7).background(RoundedRectangle(cornerRadius: 6).fill(Theme.terminal))
        } else {
            SecureField("Pairing code", text: $setup.code).textFieldStyle(.plain).font(.system(size: 11.5, design: .monospaced))
                .padding(7).background(RoundedRectangle(cornerRadius: 6).fill(Theme.terminal)).disabled(setup.busy)
        }
    }
}

/// "Find addresses…": a one-time, read-only code lets the app read the addresses this Mac's T3 linked each machine at.
struct FindAddressesCard: View {
    @ObservedObject var setup: ApprovalSetup
    @Environment(\.snapshotMode) private var snapshotMode
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Find addresses").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            Text(verbatim: "T3 Code doesn’t share linked machines’ addresses with Agent Huddle’s normal connection. A one-time, read-only code from this Mac lets it read the list once. You can also type addresses instead.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: PeerLinkDiscovery.pairingCommand).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(white: 0.92))
                .padding(7).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(Theme.terminal)).textSelection(.enabled)
            if snapshotMode {
                Text(verbatim: "pairing code").font(.system(size: 11.5)).foregroundStyle(Theme.dim).padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(Theme.terminal))
            } else {
                SecureField("Pairing code", text: $setup.code).textFieldStyle(.plain).font(.system(size: 11.5, design: .monospaced))
                    .padding(7).background(RoundedRectangle(cornerRadius: 6).fill(Theme.terminal))
            }
            Text(verbatim: "It can read machine names, addresses and which sessions exist; it cannot send, launch or change anything. Revoke it later with t3 auth session revoke (labelled “\(PeerLinkDiscovery.label)”).")
                .font(.system(size: 10.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
            if let note = setup.note { Text(verbatim: note).font(.system(size: 11.5)).foregroundStyle(Theme.red) }
            HStack(spacing: 6) {
                Spacer()
                Button { setup.toggle(ApprovalSetup.discover) } label: { Pill(text: "Cancel", fill: Color.white.opacity(0.12), fg: .white) }.buttonStyle(.plain)
                Button { setup.discover() } label: { Pill(text: setup.busy ? "Working…" : "Find addresses", fill: Theme.lime) }
                    .buttonStyle(.plain).disabled(setup.code.isEmpty || setup.busy).opacity(setup.code.isEmpty ? 0.4 : 1)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }
}
