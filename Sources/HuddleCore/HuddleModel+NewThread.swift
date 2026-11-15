import Foundation

/// Start a new thread from the panel (spec 16): pick a connected machine and a project, type the task, Start.
extension HuddleModel {
    public static let newThreadKey = "n|new"
    static let thisMacKey = "this-mac"

    // MARK: Machines and tools

    /// Machines a thread can be started on: this Mac (when connected) and machines connected directly, never linked-only ones.
    public var launchMachines: [HuddleEnvironment] {
        var list: [HuddleEnvironment] = []
        if state.connection == .connected {
            list.append(environments.first(where: \.isLocal) ?? HuddleEnvironment(id: Self.thisMacKey, label: "This Mac", isLocal: true))
        }
        for id in connectedMachineIds.sorted() where id != localEnvironmentId && machineStatus[id] != .signInExpired {
            list.append(HuddleEnvironment(id: id, label: machineLabel(id), isLocal: false))
        }
        return list.filter { tools(forMachine: $0.id).names.contains("t3_thread_launch") }
    }

    /// The "+" in the header: some connected machine offers `t3_thread_launch`, and read-only mode is off.
    public var canStartThreads: Bool { !readOnly && !launchMachines.isEmpty }

    func isThisMac(_ id: String) -> Bool { id == Self.thisMacKey || id == localEnvironmentId }

    func tools(forMachine id: String) -> (names: Set<String>, args: [String: Set<String>]) {
        isThisMac(id) ? (toolNames, toolArguments) : (machineTools[id] ?? ([], [:]))
    }

    /// The client for a machine. A machine-level failure on another machine stays that machine's (spec 15).
    func client(forMachine id: String) async throws -> MCPClient {
        if isThisMac(id) { return try await ensureClient() }
        do { return try await ensureRemoteClient(id) }
        catch { if Self.isMachineLevel(error) { noteMachineFailureIfNew(id, error) }; throw MachineFailure(machine: id, underlying: error) }
    }

    public func machineName(forLaunch id: String) -> String {
        isThisMac(id) ? (localEnvironmentName ?? "This Mac") : machineLabel(id)
    }

    // MARK: Composer

    public func openNewThread() {
        guard canStartThreads else { return }
        if collapsed { toggleCollapsed() }   // the composer lives in the expanded panel
        let d = newThreadDefaults
        let machines = launchMachines
        let wanted = d.machine ?? d.lastMachine
        let machine = machines.first(where: { $0.id == wanted }) ?? machines.first
        newThreadMode = d.mode; newThreadWorkspace = d.workspace; newThreadPlan = d.plan; newThreadModel = d.model
        newThreadTitle = ""; newThreadState = nil; newThreadOptions = false
        newThreadOpen = true
        if let machine { selectNewThreadMachine(machine.id) }
    }

    public func closeNewThread() {
        newThreadOpen = false
        if composer.text(Self.newThreadKey).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { composer.drafts[Self.newThreadKey] = nil }
        if case .error = newThreadState { newThreadState = nil }
    }

    /// Picks the machine, then its project per the defaults (last used there, or Scratch), and loads its lists.
    public func selectNewThreadMachine(_ id: String) {
        newThreadMachine = id
        let last = newThreadDefaults.lastProject[id]
        newThreadProject = newThreadDefaults.scratch ? nil : (last == "" ? nil : last)
        Task { await loadLaunchLists(id) }
    }

    /// The machine's projects (recent first: those with threads in the list, then pinned, then by update) and models.
    func loadLaunchLists(_ id: String) async {
        let env: String? = nil   // each machine is asked through its own client, so no environmentId
        if let c = try? await client(forMachine: id) {
            if tools(forMachine: id).names.contains("t3_project_list"), let projects = try? await c.projects(environment: env) {
                projectsByMachine[id] = sortProjects(projects, machine: id)
                if newThreadMachine == id, let p = newThreadProject, !projects.contains(where: { $0.id == p }) {
                    newThreadProject = projectsByMachine[id]?.first?.id
                } else if newThreadMachine == id, newThreadProject == nil, !newThreadDefaults.scratch, newThreadDefaults.lastProject[id] == nil {
                    newThreadProject = projectsByMachine[id]?.first?.id
                }
            }
            if tools(forMachine: id).names.contains("orchestrator_capabilities"), let caps = try? await c.capabilities(environment: env) {
                capabilitiesByMachine[id] = caps
            }
        }
    }

    func sortProjects(_ projects: [ProjectSummary], machine id: String) -> [ProjectSummary] {
        var lastActivity: [String: String] = [:]
        for s in state.sessions.values where (s.environmentId ?? Self.thisMacKey) == id || (isThisMac(id) && (s.environmentId == nil || s.environmentId == localEnvironmentId)) {
            if s.updatedAt > lastActivity[s.projectId, default: ""] { lastActivity[s.projectId] = s.updatedAt }
        }
        return projects.sorted { a, b in
            let la = lastActivity[a.id], lb = lastActivity[b.id]
            if (la != nil) != (lb != nil) { return la != nil }
            if let la, let lb, la != lb { return la > lb }
            if a.pinned != b.pinned { return a.pinned }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// Projects that had threads in the list recently (shown under "Recent").
    public func recentProjectIds(_ id: String) -> Set<String> {
        Set(state.sessions.values.filter { (s) in
            isThisMac(id) ? (s.environmentId == nil || s.environmentId == localEnvironmentId) : s.environmentId == id
        }.map(\.projectId))
    }

    /// Modes the chosen model's provider allows (all three when T3 does not say).
    public var newThreadModes: [LaunchMode] {
        guard let m = newThreadModel, let machine = newThreadMachine,
              let allowed = capabilitiesByMachine[machine]?.first(where: { $0.instanceId == m.instanceId })?.runtimeModes else { return LaunchMode.allCases }
        return LaunchMode.allCases.filter { allowed.contains($0.rawValue) }
    }

    public var newThreadTitlePreview: String {
        LaunchRequest.title(override: newThreadTitle, message: composer.text(Self.newThreadKey))
    }

    // MARK: Start

    public func startNewThread() async {
        guard newThreadState != .sending else { return }
        guard !readOnly else { newThreadState = .error("Read-only mode. Turn it off in Settings to start threads."); return }
        let text = composer.text(Self.newThreadKey)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= Self.maxMessageLength,
              let machine = newThreadMachine, launchMachines.contains(where: { $0.id == machine }) else { return }
        newThreadState = .sending
        let mode = newThreadModes.contains(newThreadMode) ? newThreadMode : (newThreadModes.last ?? .approvalRequired)
        let fingerprint = [machine, newThreadProject ?? "", text, newThreadModel?.model ?? "", mode.rawValue, newThreadWorkspace.rawValue, "\(newThreadPlan)", newThreadTitle].joined(separator: "\u{1F}")
        let requestId = pendingLaunch.flatMap { $0.fingerprint == fingerprint ? $0.id : nil } ?? UUID().uuidString
        pendingLaunch = (fingerprint, requestId)
        let request = LaunchRequest(title: LaunchRequest.title(override: newThreadTitle, message: text), message: text, projectId: newThreadProject,
                                    model: newThreadModel, mode: mode, workspace: newThreadWorkspace, plan: newThreadPlan, clientRequestId: requestId)
        do {
            let c = try await client(forMachine: machine)
            let id = try await c.launchThread(request)
            pendingLaunch = nil
            composer.drafts[Self.newThreadKey] = nil
            newThreadState = nil
            newThreadOpen = false
            var d = newThreadDefaults
            d.lastMachine = machine; d.lastProject[machine] = newThreadProject ?? ""
            setNewThreadDefaults(d)
            await refresh(force: true)
            if let id { showRowToast(id, "Started on \(machineName(forLaunch: machine))") }
            else { showToast("Started on \(machineName(forLaunch: machine))") }
        } catch {
            newThreadState = .error(Self.oneLine(error))
        }
    }
}

extension HuddleModel {
    /// Settings → New threads lists models from the machines' catalogs.
    public func loadLaunchListsForSettings(_ id: String) async { await loadLaunchLists(id) }
}
