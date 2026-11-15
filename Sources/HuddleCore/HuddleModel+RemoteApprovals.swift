import Foundation

/// Inline approvals for threads on another machine. Opt-in per machine, off by default.
/// The credential, and the one https origin it may be sent to, are kept together (`RemoteApprovalCredential`).
public enum ApprovalRoute: Equatable, Sendable {
    case thisMac
    case machine(String)   // linked environment id
}

extension HuddleModel {
    /// Any approvals feature is on (this Mac's, or at least one other machine's). Off = the panel looks exactly as before.
    public var approvalsOptedIn: Bool { inlineApprovals || !remoteApprovalEnvironments.isEmpty }
    /// Where a decision for this thread would go, or nil when inline approvals are not set up for its machine.
    public func approvalRoute(for s: Session) -> ApprovalRoute? {
        if isLocalThread(s.threadId) { return inlineApprovals ? .thisMac : nil }
        if let e = s.environmentId, remoteApprovalEnvironments.contains(e) { return .machine(e) }
        return nil
    }

    /// The linked machines (not this Mac), as T3's `t3_environment_links` lists them.
    public var linkedMachines: [HuddleEnvironment] { environments.filter { !$0.isLocal } }
    /// Machines that have a credential, for the menu's "Turn off". Includes one whose link is gone: its credential must still be removable.
    public var machinesWithApprovals: [HuddleEnvironment] {
        storedRemoteApprovalIds.map { id in
            environments.first { $0.id == id } ?? HuddleEnvironment(id: id, label: "Unlinked machine (\(id.prefix(8))…)", isLocal: false)
        }
    }

    /// The Allow / Deny area (buttons or hint) is shown at all. A thread on this Mac only follows this Mac's own opt-in, so a
    /// remote-only setup does not change how this Mac's permission rows look.
    public func showsApprovalControls(for s: Session) -> Bool {
        s.permission != nil && (isOnThisMac(s) ? inlineApprovals : approvalsOptedIn)
    }

    public func environmentLabel(_ id: String) -> String { environments.first { $0.id == id }?.label ?? "that machine" }

    /// What the thread's machine is called in T3 (plain text, shown in the hint).
    public func machineName(for s: Session) -> String { s.environmentId.map(environmentLabel) ?? "another machine" }

    func noApprovalRouteMessage(_ threadId: String) -> String {
        guard let s = state.sessions[threadId], !isLocalThread(threadId) else { return "Inline approvals are not set up for this thread. Decide in T3 Code." }
        return "Approving commands from the panel isn’t set up for \(machineName(for: s)). Decide in T3 Code."
    }

    /// Which linked machines have a credential. Keychain is read when the set of linked machines changes (not every poll).
    func refreshRemoteApprovalSet(force: Bool = false) {
        let ids = Set(linkedMachines.map(\.id))
        guard force || ids != remoteProbedIds else { return }
        remoteProbedIds = ids
        let stored = config.remoteApprovalStore.environmentIds()
        if stored != storedRemoteApprovalIds { storedRemoteApprovalIds = stored }
        let have = Set(ids.filter { config.remoteApprovalStore.load(environmentId: $0) != nil })
        if have != remoteApprovalEnvironments { remoteApprovalEnvironments = have }
    }

    /// The address to offer in the setup dialog: the stored one, else one found by discovery this run. The user confirms it.
    public func suggestedAddress(forEnvironment id: String) -> String? {
        config.remoteApprovalStore.load(environmentId: id)?.origin ?? discoveredAddresses[id]
    }

    /// Menu → "Find address…": one read of `peerLinks.list` on THIS Mac's T3 with a throwaway `access:read` session.
    /// Returns how many linked machines got an https address. Nothing is saved to disk.
    @discardableResult
    public func discoverPeerAddresses(pairingCode: String) async throws -> Int {
        let origin = try resolveEndpoint()
        let links = try await PeerLinkDiscovery.discover(pairingCode: pairingCode, origin: origin, log: config.log)
        var found: [String: String] = [:]
        var all: [String: [String]] = [:]
        for l in links {
            let ok = l.urls.compactMap { try? config.remotePolicy.validate($0).url.absoluteString }
            if let first = ok.first { found[l.environmentId] = first; all[l.environmentId] = ok }
        }
        discoveredAddresses = found
        discoveredUrls = all
        return found.count
    }

    /// Inline approvals window → "Set up…" on a machine. `address` is what the user confirmed or typed; `pairingCode`
    /// was created ON that machine. Identity is checked before the code leaves; only the resulting session is kept.
    /// `acknowledgeUnlisted`: the user typed an address that this Mac's T3 does not list for the machine and said they trust it.
    /// The environment-id check is not a proof (any host can repeat a public id), so an address T3 itself linked the machine at,
    /// or one the user already saved, is the trust anchor; anything else needs that explicit acknowledgement.
    public func enableRemoteApprovals(environmentId: String, address: String, pairingCode: String, acknowledgeUnlisted: Bool = false) async throws {
        guard linkedMachines.contains(where: { $0.id == environmentId }) else {
            throw HuddleError.approval("That machine is not linked to this Mac’s T3 Code (anymore).")
        }
        let origin = try config.remotePolicy.validate(address)
        let listed = Set(candidateAddresses(forEnvironment: environmentId).compactMap { try? config.remotePolicy.validate($0).url.absoluteString })
        if !listed.contains(origin.url.absoluteString) && !acknowledgeUnlisted {
            throw HuddleError.approval("T3 did not link this machine at that address. Use one from the list, or confirm that you typed it yourself and trust it.")
        }
        let credential = try await RemoteApprovalEnrollment.enroll(pairingCode: pairingCode, origin: origin, environmentId: environmentId, log: config.log)
        do { try config.remoteApprovalStore.save(credential) }
        catch { throw HuddleError.approval("Could not save the credential to the Keychain: \((error as? HuddleError)?.description ?? error.localizedDescription)") }
        rejectedRemoteApprovals.remove(environmentId)
        refreshRemoteApprovalSet(force: true)
        approvalStates = [:]
    }

    /// Menu → "Turn off inline approvals for another machine…". Forgets that machine's credential here. The session itself
    /// must be revoked on that machine (`t3 auth session revoke <id>`): T3 does not let a client revoke its own session.
    @discardableResult
    public func disableRemoteApprovals(environmentId: String) -> Bool {
        let gone = config.remoteApprovalStore.delete(environmentId: environmentId)
        refreshRemoteApprovalSet(force: true)
        approvalStates = [:]
        return gone
    }

    // MARK: Window state

    public enum MachineApprovalStatus: Equatable, Sendable { case on, off, needsRepair }
    public func remoteApprovalStatus(_ id: String) -> MachineApprovalStatus {
        if storedRemoteApprovalIds.contains(id) { return .on }
        return rejectedRemoteApprovals.contains(id) ? .needsRepair : .off
    }
    /// The address saved with a machine's login (the row's subtitle).
    public func savedAddress(forEnvironment id: String) -> String? { config.remoteApprovalStore.load(environmentId: id)?.origin }
    /// Linked machines plus any machine that still has a login here but is no longer linked (so it can be removed).
    public var approvalMachines: [HuddleEnvironment] {
        let linked = linkedMachines
        let orphans = machinesWithApprovals.filter { m in !linked.contains { $0.id == m.id } }
        return linked + orphans
    }
    /// Addresses to offer for a machine: the saved one first, then what discovery found, without repeats.
    public func candidateAddresses(forEnvironment id: String) -> [String] {
        var out: [String] = []
        for a in [config.remoteApprovalStore.load(environmentId: id)?.origin] + (discoveredUrls[id] ?? []).map(Optional.some) {
            if let a, !out.contains(a) { out.append(a) }
        }
        return out
    }

    public enum AddressCheck: Equatable, Sendable {
        case thisMachine
        case otherMachine
        case unreachable
        case invalid(String)
    }
    /// Asks the address who it is (public, unauthenticated, https only) and compares with the machine you linked.
    /// Nothing secret is sent. Used by the window to show which addresses really are that machine.
    public func checkAddress(_ text: String, environmentId: String) async -> AddressCheck {
        let origin: ValidatedRemoteOrigin
        do { origin = try config.remotePolicy.validate(text) }
        catch { return .invalid((error as? HuddleError)?.description ?? error.localizedDescription) }
        do { _ = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: environmentId); return .thisMachine }
        catch {
            let m = (error as? HuddleError)?.description ?? ""
            if m.contains("different machine") { return .otherMachine }
            return .unreachable
        }
    }
}
