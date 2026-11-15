import Foundation

/// A call that failed on a machine connected directly (spec 15). It was recorded for that machine only, so this Mac's
/// error handling (which drops this Mac's token on a 401) never sees it.
struct MachineFailure: Error, LocalizedError, CustomStringConvertible {
    let machine: String
    let underlying: Error
    var description: String { (underlying as? HuddleError)?.description ?? underlying.localizedDescription }
    var errorDescription: String? { description }
}

public enum MachineSignInState: Equatable, Sendable {
    case waitingForBrowser
    case failed(String)
}

/// Machines: connect to T3 on this Mac or on any other machine, each through its own MCP (spec 15).
extension HuddleModel {
    // MARK: Which machine a thread is on

    var localEnvironmentId: String? { environments.first(where: \.isLocal)?.id }

    /// The machine a thread is reached on directly, if it is not this Mac. Taken from the id the app stamped on the row
    /// when it listed that machine itself, never from a server's claim.
    func directMachine(of threadId: String) -> String? {
        guard let e = state.sessions[threadId]?.environmentId, connectedMachineIds.contains(e), e != localEnvironmentId else { return nil }
        return e
    }

    /// Shown through this Mac's T3 only because T3 links to it: readable, but T3 refuses answers and messages sent that way.
    public func isLinkedOnly(_ s: Session) -> Bool {
        // Same rule as `env()`: until this Mac's id is known, nothing is treated as another machine's.
        guard let local = localEnvironmentId, let e = s.environmentId, e != local else { return false }
        return !connectedMachineIds.contains(e)
    }

    /// Transport, identity, sign-in and contract failures are the machine's; a tool error is the call's.
    static func isMachineLevel(_ error: Error) -> Bool {
        if case .toolFailed? = error as? HuddleError { return false }
        return true
    }

    public func canAnswer(_ s: Session) -> Bool { !isLinkedOnly(s) }

    /// Runs `body` with the client and `environmentId` argument for the thread's machine. A failure on a directly connected
    /// machine is recorded for that machine and comes back as `MachineFailure`.
    func onMachine<T>(_ threadId: String, _ body: (MCPClient, String?) async throws -> T) async throws -> T {
        if let m = directMachine(of: threadId) {
            do { return try await body(try await ensureRemoteClient(m), nil) }
            catch {
                // A tool's own refusal (an answered question, a mode T3 will not take) says nothing about the machine.
                if Self.isMachineLevel(error) { noteMachineFailureIfNew(m, error) }
                throw MachineFailure(machine: m, underlying: error)
            }
        }
        let c = try await ensureClient()
        return try await body(c, env(threadId))
    }

    /// The tools a thread's machine offers.
    func tools(for s: Session) -> (names: Set<String>, args: [String: Set<String>]) {
        if let e = s.environmentId, connectedMachineIds.contains(e), e != localEnvironmentId { return machineTools[e] ?? ([], [:]) }
        return (toolNames, toolArguments)
    }

    // MARK: Clients

    /// Built once per machine and reused. The identity check runs before every (re)build; the token goes only to the origin
    /// stored with it, re-validated by the policy.
    func ensureRemoteClient(_ id: String) async throws -> MCPClient {
        if let c = remoteClients[id] { return c }
        if let retry = remoteRetryAfter[id], Date() < retry { throw HuddleError.notRunning }
        guard let cred = config.machineStore.load(environmentId: id) else { throw HuddleError.unauthorized }
        let origin = try config.remotePolicy.validate(cred.origin)
        let verified = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: id)
        let c = try MCPClient(remote: verified, token: cred.token, log: config.log)
        let tools = try await c.toolsList()
        if let reason = ContractCheck.verify(toolsList: tools) { throw HuddleError.unsupportedServer(reason) }
        let list = tools["tools"].array ?? []
        machineTools[id] = (Set(list.compactMap { $0["name"].string }),
                            Dictionary(list.compactMap { t -> (String, Set<String>)? in
                                guard let n = t["name"].string else { return nil }
                                return (n, Set((t["inputSchema"]["properties"].object ?? [:]).keys))
                            }, uniquingKeysWith: { a, _ in a }))
        remoteClients[id] = c
        remoteRetryAfter[id] = nil
        machineStatus[id] = .connected
        return c
    }

    /// One machine's failure, kept to that machine. A 401 deletes only its token.
    func noteMachineFailure(_ id: String, _ error: Error) {
        remoteClients[id] = nil
        let e = (error as? MachineFailure)?.underlying ?? error
        switch e as? HuddleError {
        case .unauthorized?:
            config.machineStore.delete(environmentId: id)
            connectedMachineIds.remove(id)
            machineStatus[id] = .signInExpired
            remoteListCache[id] = nil
        case .unsupportedServer(let reason)?:
            machineStatus[id] = .unsupported(reason)
        default:
            machineStatus[id] = .offline(String(DisplayText.clean((e as? HuddleError)?.description ?? e.localizedDescription).prefix(120)))
            remoteRetryAfter[id] = Date().addingTimeInterval(30)
        }
        config.log.log("machine \(id.prefix(8)): \((e as? HuddleError)?.category ?? "error")")
    }

    /// Active and finished lists of each machine connected directly, fetched side by side (identity check and client set-up
    /// included, so an unreachable machine costs one timeout in parallel, not one per machine), each row stamped with its machine.
    func fetchDirectLists(_ ids: Set<String>) async -> [(String, Result<DirectLists, Error>)] {
        var out: [(String, Result<DirectLists, Error>)] = []
        await withTaskGroup(of: (String, Result<DirectLists, Error>).self) { group in
            for id in ids.sorted() {
                group.addTask { [weak self] in
                    do {
                        guard let self else { throw CancellationError() }
                        let c = try await self.ensureRemoteClient(id)
                        let a = try await c.listThreads(statuses: T3Status.activeStatuses, limit: 100)
                        let f = try await c.listThreadsPage(statuses: T3Status.finishedStatuses, settled: false, limit: 25)
                        func stamp(_ rows: [ThreadSummary]) -> [ThreadSummary] { rows.map { var t = $0; t.environmentId = id; return t } }
                        return (id, .success(DirectLists(active: stamp(a), finished: stamp(f.threads), finishedIsLast: f.isLast)))
                    } catch { return (id, .failure(error)) }
                }
            }
            for await r in group { out.append(r) }
        }
        for (id, r) in out {
            switch r {
            case .failure(let e) where Self.isMachineLevel(e): noteMachineFailureIfNew(id, e)
            case .failure: break
            case .success: machineStatus[id] = .connected
            }
        }
        return out
    }

    /// While a machine waits out its retry delay the same "not reachable" error is not recorded again (a 401 always is).
    func noteMachineFailureIfNew(_ id: String, _ error: Error) {
        if let retry = remoteRetryAfter[id], Date() < retry, ((error as? HuddleError).map { if case .unauthorized = $0 { return false }; return true } ?? true) { return }
        noteMachineFailure(id, error)
    }

    // MARK: Adding and removing machines

    /// Step 1 and 2 of adding a machine: validate the address and ask it what it is. Nothing secret is sent.
    public func identifyMachine(address: String) async throws -> IdentifiedRemote {
        let origin = try config.remotePolicy.validate(address)
        let found = try await RemoteIdentity.identify(origin: origin)
        if found.environmentId == localEnvironmentId { throw HuddleError.approval("That address is this Mac. Connect it with “This Mac” instead.") }
        return found
    }

    /// Step 3: sign in to that machine's T3 in the browser (the user pastes a pairing code made on that machine there).
    public func connectMachine(_ found: IdentifiedRemote) {
        let id = found.environmentId
        guard machineSignInTasks[id] == nil else { return }
        machineSignIns[id] = .waitingForBrowser
        machineSignInTasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.runMachineSignIn(found)
            self.machineSignInTasks[id] = nil
        }
    }

    public func cancelMachineSignIn(_ id: String) {
        machineSignInTasks[id]?.cancel(); machineSignInTasks[id] = nil; machineSignIns[id] = nil
    }

    func runMachineSignIn(_ found: IdentifiedRemote) async {
        let id = found.environmentId
        do {
            let verified = try await RemoteIdentity.verify(origin: found.origin, expectedEnvironmentId: id)
            let previous = config.machineStore.load(environmentId: id)
            let oauth = try OAuthClient(remote: verified, log: config.log, opener: config.openURL)
            let prev = previous.flatMap { p in p.oauthClientId.flatMap { c in p.oauthPort.map { (clientId: c, port: $0) } } }
            let result = try await oauth.authorize(previous: prev)
            config.log.register(secret: result.accessToken)
            try config.machineStore.save(MachineCredential(environmentId: id, origin: found.origin.url.absoluteString, token: result.accessToken,
                                                           label: found.label, oauthClientId: result.clientId, oauthPort: result.port))
            connectedMachineIds.insert(id)
            remoteClients[id] = nil; remoteRetryAfter[id] = nil
            machineStatus[id] = nil
            machineSignIns[id] = nil
            await refresh(force: true)
        } catch is CancellationError {
            machineSignIns[id] = nil
        } catch {
            machineSignIns[id] = .failed(Self.oneLine(error))
        }
    }

    /// Forgets one machine's MCP sign-in. Its inline-approvals login (if any) has its own Turn off.
    @discardableResult public func signOutMachine(_ id: String) -> Bool {
        guard config.machineStore.delete(environmentId: id) else {
            machineSignIns[id] = .failed("The Keychain would not let Agent Huddle remove this sign-in, so it is still connected.")
            return false
        }
        connectedMachineIds.remove(id)
        remoteClients[id] = nil; machineTools[id] = nil; remoteListCache[id] = nil; remoteRetryAfter[id] = nil
        machineStatus[id] = nil
        Task { await refresh(force: true) }
        return true
    }

    public func machineLabel(_ id: String) -> String {
        environments.first { $0.id == id }?.label ?? config.machineStore.load(environmentId: id)?.label ?? "Machine \(id.prefix(8))…"
    }
    public func machineOrigin(_ id: String) -> String? { config.machineStore.load(environmentId: id)?.origin }
}

struct DirectLists: Sendable {
    var active: [ThreadSummary]
    var finished: [ThreadSummary]
    var finishedIsLast: Bool
}

// MARK: - What the panel and the Machines window show

public enum MachineBadge: Equatable, Sendable { case thisMac, connected, linkedOnly, offline, signInExpired, unsupported }

extension HuddleModel {
    /// The badge on a machine's group header and its row in the Machines window.
    public func machineBadge(_ id: String) -> MachineBadge {
        if id == localEnvironmentId { return .thisMac }
        switch machineStatus[id] {
        case .offline?: return .offline
        case .signInExpired?: return .signInExpired
        case .unsupported?: return .unsupported
        default: return connectedMachineIds.contains(id) ? .connected : .linkedOnly
        }
    }

    /// Something can be shown: this Mac is connected, or at least one other machine is.
    public var anyMachineConnected: Bool { state.connection == .connected || !connectedMachineIds.isEmpty }

    /// Every other machine the window lists: connected directly, linked in this Mac's T3, or holding a status to report.
    public var otherMachineIds: [String] {
        var ids = connectedMachineIds.union(machineStatus.keys).union(environments.filter { !$0.isLocal }.map(\.id))
        if let local = localEnvironmentId { ids.remove(local) }
        return ids.sorted { machineLabel($0).localizedCaseInsensitiveCompare(machineLabel($1)) == .orderedAscending }
    }

    /// An address to start from when connecting a machine T3 already knows (discovery, or the approvals login's address).
    public func suggestedAddress(_ id: String) -> String? {
        machineOrigin(id) ?? discoveredUrls[id]?.first ?? discoveredAddresses[id] ?? savedAddress(forEnvironment: id)
    }
}

extension HuddleModel {
    public var localEnvironmentName: String? { environments.first(where: \.isLocal)?.label }
}
