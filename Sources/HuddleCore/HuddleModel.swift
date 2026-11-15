import Foundation
import Combine

public struct JumpTarget: Equatable, Sendable {
    public var threadId: String
    public var title: String
    public var environmentId: String?
    public var link: String?

    /// `t3code://threads/<environmentId>/<threadId>`: T3 Code's own thread deep link (`promptLinkAppPath` in the desktop bundle maps
    /// host `threads` to the `/<env>/<thread>` route). It is built from the row's own two identifiers, each checked and encoded
    /// with the RFC 3986 unreserved set, never from a link string a server supplied: a link can only fill in a missing environment
    /// id. So the URL always has the fixed scheme and host, exactly two path segments, and nothing else.
    public var deepLink: URL? {
        var env = environmentId
        if env == nil, let l = ThreadSummary.bareLink(link), let e = ThreadSummary.environment(fromLink: l) { env = e.removingPercentEncoding ?? e }
        guard let env, Self.isValidIdentifier(env), Self.isValidIdentifier(threadId) else { return nil }
        var c = URLComponents()
        c.scheme = "t3code"; c.host = "threads"
        c.percentEncodedPath = "/" + Self.segment(env) + "/" + Self.segment(threadId)
        return c.url
    }

    static func segment(_ s: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
    /// Not empty, not absurdly long, not a dot segment, no control or hidden characters.
    static func isValidIdentifier(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 512, s != ".", s != ".." else { return false }
        return DisplayText.clean(s) == s
    }
}

/// Jump to a thread in T3 Code. Returns false when it could not be delivered (the model then shows a fallback hint).
public protocol Jumper: Sendable {
    @discardableResult func jump(to target: JumpTarget) -> Bool
}

public final class RecordingJumper: Jumper, @unchecked Sendable {
    private let lock = NSLock()
    private var _targets: [JumpTarget] = []
    private let log: HuddleLog?
    public var succeeds = true
    public init(log: HuddleLog? = nil) { self.log = log }
    public var targets: [JumpTarget] { lock.lock(); defer { lock.unlock() }; return _targets }
    public func jump(to target: JumpTarget) -> Bool {
        lock.lock(); _targets.append(target); lock.unlock()
        log?.log("jump (stub): \(target.deepLink?.absoluteString ?? "no link")")
        return succeeds
    }
}

public struct HuddleConfig: Sendable {
    public enum Source: Sendable { case runtimeFile(Discovery), fixed(URL) }
    public var source: Source
    public var tokenStore: TokenStore
    public var peerVerifier: PeerVerifier
    public var preferences: PreferencesStore?
    public var log: HuddleLog
    public var jumper: Jumper
    public var playSound: @Sendable () -> Void
    /// Opens the authorization page (the app uses the default browser; tests drive it themselves).
    public var openURL: @Sendable (URL) -> Void
    /// Opt-in inline approvals: the separate credential (own Keychain account). Empty by default, so the feature is off.
    public var approvalStore: TokenStore
    /// Opt-in inline approvals for other machines: one credential per linked environment, and the origin rules for them.
    public var remoteApprovalStore: RemoteCredentialStore
    public var remotePolicy: RemoteOriginPolicy
    /// Spec 15: MCP sign-ins of other machines connected directly. Empty by default.
    public var machineStore: MachineCredentialStore

    public init(source: Source, tokenStore: TokenStore, approvalStore: TokenStore = MemoryTokenStore(),
                remoteApprovalStore: RemoteCredentialStore = MemoryRemoteCredentialStore(),
                remotePolicy: RemoteOriginPolicy = .production,
                machineStore: MachineCredentialStore = MemoryMachineCredentialStore(),
                peerVerifier: PeerVerifier = AcceptAnyPeer(),
                preferences: PreferencesStore? = nil, log: HuddleLog = HuddleLog(),
                jumper: Jumper = RecordingJumper(), playSound: @escaping @Sendable () -> Void = {},
                openURL: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.source = source; self.tokenStore = tokenStore; self.approvalStore = approvalStore; self.peerVerifier = peerVerifier
        self.remoteApprovalStore = remoteApprovalStore; self.remotePolicy = remotePolicy; self.machineStore = machineStore
        self.preferences = preferences; self.log = log; self.jumper = jumper; self.playSound = playSound; self.openURL = openURL
    }
}

public enum QuestionUIState: Equatable, Sendable { case pending, sending, error(String) }

/// The one object the views observe. All T3 access goes through `MCPClient`; nothing else.
@MainActor
public final class HuddleModel: ObservableObject {
    @Published public internal(set) var state = HuddleState()
    @Published public var selectedThreadID: String?
    @Published public private(set) var collapsed = false
    @Published public private(set) var muted = false
    @Published public private(set) var widgetHidden = false
    @Published public private(set) var armedCloseID: String?
    @Published public private(set) var toast: String?
    @Published public var selections: [String: String] = [:]          // requestId → option label
    @Published public internal(set) var questionStates: [String: QuestionUIState] = [:]
    @Published public private(set) var readOnly = false
    /// Opt-in (default off): Allow / Deny on permission requests through T3's internal `/ws`. True only while the credential exists.
    @Published public internal(set) var inlineApprovals = false
    @Published public internal(set) var approvalStates: [String: QuestionUIState] = [:]   // threadId → state of the last decision
    /// Linked environments that have an approvals credential (opt-in, per machine). Empty unless the user set one up.
    @Published public internal(set) var remoteApprovalEnvironments: Set<String> = []
    /// Addresses found by `PeerLinkDiscovery` this run (environment id → https origin). Memory only; the setup dialog confirms one.
    @Published public internal(set) var discoveredAddresses: [String: String] = [:]
    /// Every acceptable (https) address `peerLinks.list` gave per machine, in T3's order. Memory only.
    @Published public internal(set) var discoveredUrls: [String: [String]] = [:]
    /// Machines whose saved approvals login T3 refused (revoked or expired). The window shows "Needs re-pair" until set up again.
    @Published public internal(set) var rejectedRemoteApprovals: Set<String> = []
    /// Every environment id with a stored credential, linked or not (the menu can remove an orphan).
    @Published public internal(set) var storedRemoteApprovalIds: [String] = []
    var remoteProbedIds: Set<String> = []
    @Published public private(set) var closeSettles = false
    /// Spec 14: a hidden panel comes back when a thread starts needing the user. Off by default.
    @Published public private(set) var showPanelOnAttention = false
    /// The Settings window floats above other apps while open. On by default.
    @Published public private(set) var settingsOnTop = true
    /// The row the header pill asked to scroll to, and the row whose outline flashes once.
    @Published public var revealThreadId: String?
    @Published public private(set) var flashThreadId: String?
    @Published public private(set) var consecutiveFailures = 0
    /// Why the last connect attempt failed (shown under the Connect button). Never contains the token.
    @Published public private(set) var connectNote: String?
    @Published public private(set) var signingIn = false
    @Published public private(set) var environments: [HuddleEnvironment] = []
    /// `environment|projectId` → project title. Scratch threads ("No project") are left out on purpose.
    @Published public private(set) var projectNames: [String: String] = [:]
    private var projectLookups: Set<String> = []
    /// Steps the user opened or closed by hand; otherwise a running step is open and the rest are closed.
    @Published public private(set) var stepOpen: [String: Bool] = [:]   // key: threadId|stepId
    public var groups: [HuddleState.EnvGroup] { state.groups(environments: environments) }
    var toolNames: Set<String> = []
    /// Argument names each tool advertises (`tools/list`), so an optional feature can check the arguments it needs.
    var toolArguments: [String: Set<String>] = [:]
    private var lastEnvRefresh = Date.distantPast
    private var lastFinishedFetch = Date.distantPast
    private var envBoostUntil = Date.distantPast
    public var canLinkEnvironments: Bool { toolNames.contains("t3_environment_link") }
    private var signInTask: Task<Void, Never>?

    public let config: HuddleConfig
    private var client: MCPClient?
    private var loop: Task<Void, Never>?
    private var lastList = Date.distantPast
    var justAnswered: [String: Date] = [:]
    /// Drafts of written messages and answers, kept apart so typing does not re-render every row (spec 13).
    public let composer = ComposerStore()
    @Published public internal(set) var composingThreadId: String?
    @Published public internal(set) var writingAnswerFor: String?
    @Published public internal(set) var sendModes: [String: SendMode] = [:]
    @Published public internal(set) var composeStates: [String: QuestionUIState] = [:]
    @Published public internal(set) var composeNotices: [String: String] = [:]
    @Published public internal(set) var rowToasts: [String: String] = [:]
    var composeTargets: [String: String] = [:]
    // Spec 15: machines connected directly, each through its own MCP.
    @Published public internal(set) var connectedMachineIds: Set<String> = []
    @Published public internal(set) var machineStatus: [String: MachineStatus] = [:]
    @Published public internal(set) var machineSignIns: [String: MachineSignInState] = [:]
    var remoteClients: [String: MCPClient] = [:]
    var machineTools: [String: (names: Set<String>, args: [String: Set<String>])] = [:]
    var remoteListCache: [String: (active: [ThreadSummary], finished: [ThreadSummary], at: Date)] = [:]
    var remoteRetryAfter: [String: Date] = [:]
    var machineSignInTasks: [String: Task<Void, Never>] = [:]
    var pendingSends: [String: (fingerprint: String, id: String)] = [:]
    private var prefs: Preferences

    public init(config: HuddleConfig) {
        self.config = config
        prefs = config.preferences?.load() ?? Preferences()
        state.hiddenIDs = Set(prefs.hiddenIDs)
        collapsed = prefs.collapsed; muted = prefs.muted
        readOnly = prefs.readOnly; closeSettles = prefs.closeSettles
        showPanelOnAttention = prefs.showPanelOnAttention ?? false
        settingsOnTop = prefs.settingsOnTop ?? true
        inlineApprovals = config.approvalStore.load() != nil
        connectedMachineIds = Set(config.machineStore.environmentIds())
    }

    public var sessions: [Session] { state.visible }
    public var selected: Session? { selectedThreadID.flatMap { state.sessions[$0] } }
    /// Every tool called, on this Mac and on each directly connected machine (tests and the "never writes" checks).
    public var calledTools: [String] { (client?.calledTools ?? []) + remoteClients.keys.sorted().flatMap { remoteClients[$0]?.calledTools ?? [] } }

    // MARK: Lifecycle

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(force: false)
                let wait = PollSchedule.loopInterval(detailOpen: self.selectedThreadID != nil, expanded: !self.collapsed,
                                                     consecutiveFailures: self.consecutiveFailures)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }
    public func stop() { loop?.cancel(); loop = nil }

    // MARK: Polling

    private var refreshInFlight = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    /// One refresh at a time: the poll loop, a sent answer, a decision and a sign-in can all ask for one, and overlapping runs
    /// would apply stale reads over fresh ones. A caller that arrives while one is running waits its turn, then runs its own.
    public func refresh(force: Bool = true) async {
        if refreshInFlight { await withCheckedContinuation { refreshWaiters.append($0) } }
        else { refreshInFlight = true }
        defer { if refreshWaiters.isEmpty { refreshInFlight = false } else { refreshWaiters.removeFirst().resume() } }
        await refreshOnce(force: force)
        pruneCaches()
    }

    /// Everything keyed by a server-supplied id is dropped when its thread or request is gone, so a hostile server cannot make
    /// the app hold on to an unbounded amount of state.
    private func pruneCaches() {
        let live = Set(state.sessions.keys)
        func thread(_ key: String) -> String { String(key.prefix { $0 != "|" }) }
        justAnswered = justAnswered.filter { Date().timeIntervalSince($0.value) < 10 }
        outputCaches = outputCaches.filter { live.contains(thread($0.key)) }
        stepOpen = stepOpen.filter { live.contains(thread($0.key)) }
        approvalStates = approvalStates.filter { live.contains($0.key) }
        let liveRequests = Set(state.sessions.values.compactMap { $0.question?.requestId })
        questionStates = questionStates.filter { liveRequests.contains($0.key) }
        selections = selections.filter { liveRequests.contains($0.key) }
        if projectNames.count > 300 { projectNames.removeAll(); projectLookups.removeAll() }
        pruneComposeState(liveThreads: live, liveRequests: liveRequests)
    }

    private func refreshOnce(force: Bool) async {
        let listDue = force || Date().timeIntervalSince(lastList) >= PollSchedule.listInterval(
            expanded: !collapsed, consecutiveFailures: consecutiveFailures) - 0.05
        // This Mac is optional when other machines are connected directly (spec 15): its failure is handled, then the others go on.
        var local: MCPClient?
        do { local = try await ensureClient() } catch {
            handle(error)
            if connectedMachineIds.isEmpty { return }
        }
        do {
            if listDue { try await refreshList(local: local); lastList = Date() }
            if let id = selectedThreadID, state.sessions[id] != nil {
                do { try await readThread(id: id); try await refreshOutput(id: id) } catch is MachineFailure {}
            }
            if local != nil {
                state.connection = .connected
                consecutiveFailures = 0
                connectNote = nil
            } else if machineStatus.values.contains(.connected) {
                consecutiveFailures = 0     // no T3 here is fine when another machine answers: do not back the poll off
            }
        } catch is MachineFailure {
        } catch { handle(error) }
    }

    /// nil for this machine; the linked environment's id otherwise (T3 rejects `environmentId` on the local one only when links are off).
    func env(_ id: String) -> String? {
        guard let e = state.sessions[id]?.environmentId, let local = environments.first(where: \.isLocal)?.id, e != local else { return nil }
        return e
    }

    private func refreshEnvironments(_ client: MCPClient) async {
        if environments.isEmpty || Date().timeIntervalSince(lastEnvRefresh) > (Date() < envBoostUntil ? 3 : 30) {
            lastEnvRefresh = Date()
            var list: [HuddleEnvironment] = []
            if let local = try? await client.localEnvironment() { list.append(local) }
            list += await client.linkedEnvironments(toolNames: toolNames)
            if !list.isEmpty { environments = list; refreshRemoteApprovalSet() }
        }
    }

    /// Every directly connected machine is in `environments` (named from its sign-in), even with no T3 on this Mac.
    func mergeConnectedMachines() {
        var list = environments
        for id in connectedMachineIds.sorted() where !list.contains(where: { $0.id == id }) {
            let label = config.machineStore.load(environmentId: id)?.label ?? "Machine \(id.prefix(8))…"
            list.append(HuddleEnvironment(id: id, label: label, isLocal: false))
        }
        if list != environments { environments = list; refreshRemoteApprovalSet() }
    }

    public func projectName(for s: Session) -> String? { projectNames[Self.projectKey(s.environmentId, s.projectId)] }
    private static func projectKey(_ env: String?, _ project: String) -> String { "\(env ?? "")|\(project)" }

    private func refreshProjectNames() async {
        for s in state.sessions.values where !s.projectId.isEmpty {
            let key = Self.projectKey(s.environmentId, s.projectId)
            guard !projectLookups.contains(key) else { continue }
            projectLookups.insert(key)   // one attempt per project: a failure is not retried every poll
            if let t = try? await onMachine(s.threadId, { c, env in try await c.projectTitle(projectId: s.projectId, environment: env) }),
               t != "No project" { projectNames[key] = DisplayText.clean(t) }
        }
    }

    public func isExpanded(threadId: String, _ step: Step) -> Bool { stepOpen["\(threadId)|\(step.id)"] ?? (step.state == .running) }

    /// Open or close one step. Opening a command whose full output has not been fetched loads it once.
    public func toggleStep(threadId: String, stepId: String) async {
        guard let step = state.sessions[threadId]?.steps.first(where: { $0.id == stepId }) else { return }
        let open = !isExpanded(threadId: threadId, step)
        stepOpen["\(threadId)|\(stepId)"] = open
        guard open, step.kind == .terminal, !step.outputIsFull else { return }
        if let text = try? await onMachine(threadId, { c, env in try await c.readItemText(threadId: threadId, itemId: stepId, offset: 0, environment: env) }) {
            var body = text
            if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) } else { body = "" }
            state.setOutput(threadId: threadId, itemId: stepId, output: String(body.suffix(20_000)))
        }
    }

    private func refreshList(local: MCPClient?) async throws {
        if let local { await refreshEnvironments(local) }
        mergeConnectedMachines()
        let before = state.sessions
        let attentionBefore = Set(before.values.filter(\.needsAttention).map(\.threadId))
        let localId = environments.first(where: \.isLocal)?.id
        let direct = connectedMachineIds.subtracting(localId.map { [$0] } ?? [])

        // This Mac, and machines it only links to (read through this Mac's T3), skipping any connected directly.
        var active: [ThreadSummary] = []
        var linked: [HuddleEnvironment] = []
        if let local {
            linked = environments.filter { !$0.isLocal && !direct.contains($0.id) }
            active = try await local.listThreads(statuses: T3Status.activeStatuses, limit: 100)
            for r in linked {   // a linked environment failing (offline, capability_denied) never breaks the local list
                if let rows = try? await local.listThreads(statuses: T3Status.activeStatuses, limit: 100, environment: r.id) { active += rows }
            }
        }
        // Machines connected directly, side by side. A failing one keeps its last list for a short while.
        var directFinished: [ThreadSummary] = []
        var directExhaustive = true
        for (id, result) in await fetchDirectLists(direct) {
            switch result {
            case .success(let lists):
                remoteListCache[id] = (lists.active, lists.finished, Date())
                active += lists.active; directFinished += lists.finished; directExhaustive = directExhaustive && lists.finishedIsLast
            case .failure:
                if let c = remoteListCache[id], Date().timeIntervalSince(c.at) < 30 { active += c.active; directFinished += c.finished }
                directExhaustive = false
            }
        }
        state.applyActive(active)
        if state.sessions.values.contains(where: { !$0.t3Status.isActive }) || Date().timeIntervalSince(lastFinishedFetch) > 10 {
            lastFinishedFetch = Date()
            var finished = directFinished
            var exhaustive = directExhaustive
            if let local {
                let page = try await local.listThreadsPage(statuses: T3Status.finishedStatuses, settled: false, limit: 25)
                finished += page.threads; exhaustive = exhaustive && page.isLast
                for r in linked {
                    if let p = try? await local.listThreadsPage(statuses: T3Status.finishedStatuses, settled: false, limit: 25, environment: r.id) {
                        finished += p.threads; exhaustive = exhaustive && p.isLast
                    } else { exhaustive = false }
                }
            }
            state.applyFinished(finished, exhaustive: exhaustive)
        }
        await refreshProjectNames()
        for s in state.sessions.values {
            let p = before[s.threadId]
            // A pending request whose item we have not seen as `waiting` yet is re-read every poll: T3 can flip an item's
            // status without touching the thread's updatedAt or itemCount.
            let approvalUnsettled = (s.pendingRequestCount > 0 && s.approvalRequestId == nil) || s.secretPrompt != nil
            if p == nil || p!.t3Status != s.t3Status || p!.updatedAt != s.updatedAt || p!.itemCount != s.itemCount || approvalUnsettled {
                do { try await readThread(id: s.threadId) } catch is MachineFailure {}
            }
        }
        for s in state.sessions.values { do { try await checkPending(id: s.threadId) } catch is MachineFailure {} }

        let newlyNeeding = state.sessions.values.filter { $0.needsAttention && !attentionBefore.contains($0.threadId) }
        if !newlyNeeding.isEmpty && !muted { config.playSound() }
        if !newlyNeeding.isEmpty && showPanelOnAttention && widgetHidden { widgetHidden = false }   // shown without taking focus
        // Drop selection of a session that vanished.
        if let id = selectedThreadID, state.sessions[id] == nil { selectedThreadID = nil }
    }

    func readThread(id: String) async throws {
        var restarted = false
        for _ in 0..<40 {   // first load of a long run pages from its top; later polls are incremental
            let last = state.sessions[id]?.lastPosition ?? -1
            // Re-read a few positions back so status changes on the newest items are caught (afterPosition must be ≥ 0).
            let after: Int? = last - 3 >= 0 ? last - 3 : nil
            let read = try await onMachine(id) { c, env in try await c.readActivity(threadId: id, afterPosition: after, environment: env) }
            if state.noteRun(threadId: id, latestRunId: read.latestRunId), !restarted {   // new run: start over
                restarted = true
                outputCaches = outputCaches.filter { !$0.key.hasPrefix("\(id)|") }       // the old run's output must not leak into the new one
                continue
            }
            state.applyRead(read)
            if !read.hasMore { break }
            if (state.sessions[id]?.lastPosition ?? -1) <= last { break }              // a page that does not advance would loop
        }
    }

    private func checkPending(id: String) async throws {
        guard let s = state.sessions[id] else { return }
        guard s.t3Status == .waiting || s.pendingRequestCount > 0 else {
            if s.question != nil || s.permission != nil { state.clearPending(threadId: id) }
            return
        }
        if let t = justAnswered[id], Date().timeIntervalSince(t) < 4 { state.clearPending(threadId: id); return }
        var questions: [Question] = []
        var listSucceeded = true
        do {
            for rid in try await onMachine(id, { c, env in try await c.pendingRequestIds(threadId: id, environment: env) }) {
                // A request we cannot read or decode is still *a question*: show it, answerable only in T3 (Q5).
                if let q = try? await onMachine(id, { c, env in try await c.readQuestion(threadId: id, requestId: rid, environment: env) }) { questions.append(q) }
                else { questions.append(Question(requestId: rid, threadId: id, prompt: "Answer needed in T3 Code",
                                                 options: [], answerableInWidget: false)) }
            }
        } catch let f as MachineFailure {
            if case .toolFailed = (f.underlying as? HuddleError) { listSucceeded = false } else { throw f }
        } catch let e as HuddleError {
            if case .toolFailed = e { listSucceeded = false } else { throw e }   // unknown ≠ permission
        }
        state.applyPending(threadId: id, questions: questions, listSucceeded: listSucceeded)
        for q in questions where questionStates[q.requestId] == nil { questionStates[q.requestId] = .pending }
    }

    private struct OutputCache { var consumed = 0; var body = "" }
    private var outputCaches: [String: OutputCache] = [:]       // "threadId|itemId" → raw chars consumed + tail of the body

    /// Detail view: keep the *tail* of the newest command's output. Only new characters are fetched
    /// (`textOffset` = what we already consumed), so long output costs one small read per poll, not a refetch.
    private func refreshOutput(id: String) async throws {
        guard let step = state.sessions[id]?.steps.last(where: { $0.kind == .terminal }) else { return }
        let cacheKey = "\(id)|\(step.id)"   // thread and item together: an item id reused elsewhere must not inherit this output
        var cache = outputCaches[cacheKey] ?? OutputCache()
        let consumed = cache.consumed
        let fresh = try await onMachine(id) { c, env in try await c.readItemText(threadId: id, itemId: step.id, offset: consumed, environment: env) }
        if !fresh.isEmpty {
            var chunk = fresh
            if cache.consumed == 0 {                       // first chunk starts with the `$ command` line
                if let nl = chunk.firstIndex(of: "\n") { chunk = String(chunk[chunk.index(after: nl)...]) } else { chunk = "" }
            }
            cache.consumed += fresh.count
            cache.body += chunk
            if cache.body.count > 20_000 { cache.body = String(cache.body.suffix(20_000)) }
            outputCaches[cacheKey] = cache
        } else if outputCaches[cacheKey] == nil { outputCaches[cacheKey] = cache }
        state.setOutput(threadId: id, itemId: step.id, output: cache.body)
    }

    func resolveEndpoint() throws -> URL {
        switch config.source {
        case .runtimeFile(let d):
            let ep: Endpoint
            do { ep = try d.resolve() } catch HuddleError.runtimeFileMissing { throw HuddleError.notRunning }
            guard config.peerVerifier.verify(pid: ep.pid, port: ep.url.port ?? 0) else { throw HuddleError.peerNotT3 }
            return ep.url
        case .fixed(let u): return try LoopbackGuard.validate(u)
        }
    }

    func ensureClient() async throws -> MCPClient {
        // For the runtime-file source the listener is re-verified on every call: if T3 restarted, or another process took the
        // port, the cached client (and its token) must not keep talking to it.
        if let c = client {
            if case .runtimeFile = config.source {
                let url = try resolveEndpoint()
                if url == c.endpoint { return c }
                client = nil
            } else { return c }
        }
        let url = try resolveEndpoint()
        guard let token = config.tokenStore.load() else { throw HuddleError.unauthorized }
        let c = try MCPClient(endpoint: url, token: token, log: config.log)
        let tools = try await c.toolsList()
        if let reason = ContractCheck.verify(toolsList: tools) { throw HuddleError.unsupportedServer(reason) }
        toolNames = Set((tools["tools"].array ?? []).compactMap { $0["name"].string })
        toolArguments = Dictionary((tools["tools"].array ?? []).compactMap { t -> (String, Set<String>)? in
            guard let n = t["name"].string else { return nil }
            return (n, Set((t["inputSchema"]["properties"].object ?? [:]).keys))
        }, uniquingKeysWith: { a, _ in a })
        environments = []
        client = c
        return c
    }

    private func handle(_ error: Error) {
        let e = (error as? HuddleError) ?? .badResponse(error.localizedDescription)
        config.log.log("poll error: \(e.category)")
        consecutiveFailures += 1
        switch e {
        case .notRunning, .runtimeFileMissing: client = nil; state.connection = .notRunning
        case .unauthorized:
            client = nil
            if config.tokenStore.load() != nil {
                config.tokenStore.delete()   // "On 401, drop the token" (§7.1)
                connectNote = "T3 Code rejected the token (HTTP 401), so it was discarded. A token from `t3 auth session issue` may not be accepted on /mcp — see README."
            }
            state.connection = .unauthorized
        case .unsupportedServer(let m): client = nil; state.connection = .unsupported(m)
        default: state.connection = .error(e.description)
        }
    }

    // MARK: Auth

    /// Paste-a-token path (SPEC §7.1 fallback). The token goes to the store (Keychain) and nowhere else.
    public func submitToken(_ token: String) async {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        config.log.register(secret: t)
        connectNote = nil
        do { try config.tokenStore.save(t) }
        catch { connectNote = "Could not save the token to the Keychain: \((error as? HuddleError)?.description ?? error.localizedDescription)"; return }
        client = nil
        consecutiveFailures = 0
        await refresh(force: true)
    }

    /// Browser sign-in (SPEC §7.1 preferred path). The peer is verified *before* anything is registered or opened.
    /// This is the one T3-side footprint the spec allows: a single OAuth client registration, made when the user clicks Connect.
    public func signIn() {
        guard signInTask == nil else { return }
        signingIn = true; connectNote = nil
        signInTask = Task { [weak self] in
            guard let self else { return }
            await self.runSignIn()
            self.signingIn = false; self.signInTask = nil
        }
    }

    public func cancelSignIn() { signInTask?.cancel(); signInTask = nil; signingIn = false }

    func runSignIn() async {
        do {
            let url = try resolveEndpoint()
            let oauth = try OAuthClient(mcpEndpoint: url, log: config.log, opener: config.openURL)
            let prev = prefs.oauthClientId.flatMap { id in prefs.oauthPort.map { (clientId: id, port: $0) } }
            let result = try await oauth.authorize(previous: prev)
            config.log.register(secret: result.accessToken)
            try config.tokenStore.save(result.accessToken)
            prefs.oauthClientId = result.clientId; prefs.oauthPort = result.port; persist()
            client = nil; consecutiveFailures = 0
            await refresh(force: true)
        } catch is CancellationError {
            connectNote = nil
        } catch {
            let e = (error as? HuddleError) ?? .oauth(error.localizedDescription)
            config.log.log("sign-in failed: \(e.category)")
            connectNote = e.description
            if case .notRunning = e { state.connection = .notRunning }
        }
    }

    /// A token is stored. Read through the Keychain vault, which reads the item once per launch.
    public var isSignedIn: Bool { config.tokenStore.load() != nil }

    /// Menu → Sign Out of T3 Code (spec 08). Forgets the token on this Mac; T3 keeps the session until the user revokes it.
    /// Returns false, changing nothing else, when the Keychain refuses the delete.
    @discardableResult public func signOut() -> Bool {
        cancelSignIn()
        guard config.tokenStore.delete() else {
            connectNote = "The Keychain would not let Agent Huddle remove its sign-in, so it is still signed in."
            return false
        }
        client = nil
        toolNames = []; toolArguments = [:]
        if connectedMachineIds.isEmpty {
            environments = []
            var fresh = HuddleState()
            fresh.hiddenIDs = state.hiddenIDs
            fresh.connection = .unauthorized
            state = fresh
            selectedThreadID = nil
            composingThreadId = nil; writingAnswerFor = nil
        } else {
            // Other machines stay: only this Mac's rows go, on the next list.
            environments = environments.filter { !$0.isLocal }
            state.connection = .unauthorized
            Task { await refresh(force: true) }
        }
        consecutiveFailures = 0
        connectNote = "Signed out. T3 still has the session: run `t3 auth session list`, then `t3 auth session revoke <id>` for Agent Huddle."
        return true
    }

    // MARK: Linking other machines

    /// T3's MCP only sees machines the user linked *to this client* (separate from the T3 app's own connections).
    /// This asks T3 to show its approval card; the machines then appear on the next environment refresh.
    public func linkOtherEnvironments() async {
        guard let client, canLinkEnvironments else {
            showToast("Connect first, and turn on Settings → Labs → Linked environments in T3 Code"); return
        }
        do {
            _ = try await client.requestEnvironmentLink()
            envBoostUntil = Date().addingTimeInterval(180)       // poll the link list every 3 s while the user approves
            lastEnvRefresh = .distantPast
            showToast("Approve the link in T3 Code, then the machine appears here")
        } catch {
            let msg = (error as? HuddleError)?.description ?? error.localizedDescription
            showToast("Couldn’t start linking: \(msg.prefix(100))")
        }
    }

    func showToast(_ text: String) {
        toast = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self?.toast == text { self?.toast = nil }
        }
    }

    // MARK: Actions

    public func openDetail(_ id: String) { selectedThreadID = id }
    public func back() { selectedThreadID = nil }
    public func toggleCollapsed() { collapsed.toggle(); prefs.collapsed = collapsed; persist() }
    public func toggleMute() { muted.toggle(); prefs.muted = muted; persist() }
    public func hideWidget() { widgetHidden = true }
    public func showWidget() { widgetHidden = false }
    public func setReadOnly(_ v: Bool) { readOnly = v; prefs.readOnly = v; persist() }
    public func setCloseSettles(_ v: Bool) { closeSettles = v; prefs.closeSettles = v; persist() }
    public func setShowPanelOnAttention(_ v: Bool) { showPanelOnAttention = v; prefs.showPanelOnAttention = v; persist() }
    public func setSettingsOnTop(_ v: Bool) { settingsOnTop = v; prefs.settingsOnTop = v; persist() }
    /// "Chime when something needs me" (Settings) and the panel's speaker button change the same thing.
    public func setChime(_ on: Bool) { if muted == on { toggleMute() } }

    // MARK: Attention (spec 14)

    /// Visible rows that ask for something: a question, a permission, a secret.
    public var attentionSessions: [Session] { sessions.filter(\.needsAttention) }
    public var workingCount: Int { sessions.filter(\.isWorking).count }
    public var menuBarTooltip: String { Self.tooltip(attention: attentionSessions.count, working: workingCount) }
    public nonisolated static func tooltip(attention a: Int, working w: Int) -> String {
        var parts: [String] = []
        if a > 0 { parts.append("\(a) need\(a == 1 ? "s" : "") you") }
        if w > 0 { parts.append("\(w) running") }
        return parts.isEmpty ? "Agent Huddle" : parts.joined(separator: " · ")
    }

    /// The header pill: open the list, scroll to the first thread that needs you and flash it once.
    public func revealAttention(excluding current: String? = nil) {
        guard let first = attentionSessions.first(where: { $0.threadId != current }) else { return }
        if collapsed { toggleCollapsed() }
        selectedThreadID = nil
        widgetHidden = false
        revealThreadId = first.threadId
        flashThreadId = first.threadId
        let id = first.threadId
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if self?.flashThreadId == id { self?.flashThreadId = nil }
        }
    }
    public func savePanelOrigin(x: Double, y: Double) { prefs.panelX = x; prefs.panelY = y; persist() }
    public var savedPanelMaxHeight: Double? { prefs.panelMaxHeight }
    public func savePanelMaxHeight(_ h: Double?) { prefs.panelMaxHeight = h; persist() }
    public var savedPanelOrigin: (x: Double, y: Double)? {
        if let x = prefs.panelX, let y = prefs.panelY { return (x, y) }; return nil
    }

    /// First tap on × arms a red Close pill for 3 s; the second tap confirms (SPEC §9.7, Q6 default).
    public func closeTapped(_ id: String) {
        if armedCloseID == id { confirmClose(id); return }
        armedCloseID = id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self?.armedCloseID == id { self?.armedCloseID = nil }
        }
    }

    public func confirmClose(_ id: String) {
        armedCloseID = nil
        let session = state.sessions[id]
        state.hide(id)
        if selectedThreadID == id { selectedThreadID = nil }
        // Bounded: ids of threads no longer shown go first when there are very many (a hostile server cannot grow the file).
        var ids = Array(state.hiddenIDs)
        if ids.count > 500 { ids.sort { state.sessions[$0] != nil && state.sessions[$1] == nil }; ids = Array(ids.prefix(500)) }
        prefs.hiddenIDs = ids; persist()
        // Optional setting: settle finished threads in T3 (never an active one; never archive/interrupt).
        if closeSettles, !readOnly, let s = session, s.t3Status.isFinished, !isLinkedOnly(s) {
            Task { _ = try? await self.onMachine(id, { c, env in try await c.settle(threadId: id, environment: env) }) }
        }
    }

    public func select(option: String, for question: Question) {
        selections[question.requestId] = option
        if case .error = questionStates[question.requestId] { questionStates[question.requestId] = .pending }
    }

    public func sendAnswer(threadId: String) async {
        guard let q = state.sessions[threadId]?.question, q.answerableInWidget,
              let choice = selections[q.requestId] else { return }
        guard !readOnly else { questionStates[q.requestId] = .error("Read-only mode — answer in T3 Code"); return }
        guard let s = state.sessions[threadId], canAnswer(s) else { return }
        questionStates[q.requestId] = .sending
        do {
            try await onMachine(threadId) { c, env in try await c.respond(question: q, selection: choice, environment: env) }
            justAnswered[threadId] = Date()
            questionStates[q.requestId] = nil
            selections[q.requestId] = nil
            state.clearPending(threadId: threadId)
            await refresh(force: true)
        } catch {
            questionStates[q.requestId] = .error(Self.oneLine(error))
        }
    }

    public func jump(_ id: String) async {
        guard let s = state.sessions[id] else { return }
        await jump(session: s)
    }

    /// Jumps to the session as it was when the click happened: a refresh between the click and this call cannot swap the target.
    public func jump(session s: Session) async {
        let ok = config.jumper.jump(to: JumpTarget(threadId: s.threadId, title: s.title, environmentId: s.environmentId, link: s.link))
        guard !ok else { return }
        // Only when the deep link could not be delivered: say which thread to click.
        toast = "Couldn’t open “\(s.title)” — pick it in T3 Code"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.toast != nil { self?.toast = nil }
        }
    }

    private func persist() { config.preferences?.save(prefs) }
}
