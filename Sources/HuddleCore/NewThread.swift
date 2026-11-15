import Foundation

// Start a new thread from the panel (spec 16). Typed by the user, started on a click, on a machine the app is connected to.

public struct ProjectSummary: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var updatedAt: String
    public var pinned: Bool
    public init(id: String, title: String, updatedAt: String = "", pinned: Bool = false) {
        self.id = id; self.title = title; self.updatedAt = updatedAt; self.pinned = pinned
    }
}

public struct ModelChoice: Codable, Equatable, Sendable, Hashable {
    public var instanceId: String
    public var model: String
    public var label: String
    public init(instanceId: String, model: String, label: String) { self.instanceId = instanceId; self.model = model; self.label = label }
}

/// One provider from `orchestrator_capabilities`: its models and the runtime modes it allows (nil = any).
public struct ProviderModels: Equatable, Sendable {
    public var instanceId: String
    public var name: String
    public var models: [ModelChoice]
    public var runtimeModes: [String]?
}

/// The runtime modes the panel offers. `full-access` is never offered: it is the widest key, and starting such a thread
/// from a floating panel is better done deliberately in T3 Code.
public enum LaunchMode: String, Codable, Sendable, CaseIterable {
    case approvalRequired = "approval-required", autoAcceptEdits = "auto-accept-edits", auto
    public var label: String {
        switch self { case .approvalRequired: return "Approval"; case .autoAcceptEdits: return "Accept edits"; case .auto: return "Auto" }
    }
}

public enum LaunchWorkspace: String, Codable, Sendable, CaseIterable {
    case checkout, worktree
    public var label: String { self == .checkout ? "Project checkout" : "New worktree" }
}

/// Settings → General → New threads (spec 16), plus what was used last.
public struct NewThreadDefaults: Codable, Equatable, Sendable {
    /// nil = the machine used last.
    public var machine: String?
    /// false = the project used last on that machine; true = Scratch.
    public var scratch = false
    /// nil = T3's default model.
    public var model: ModelChoice?
    public var mode: LaunchMode = .auto
    public var workspace: LaunchWorkspace = .checkout
    public var plan = false
    public var lastMachine: String?
    /// Machine id → project id, or "" for Scratch.
    public var lastProject: [String: String] = [:]
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        machine = try c.decodeIfPresent(String.self, forKey: .machine)
        scratch = try c.decodeIfPresent(Bool.self, forKey: .scratch) ?? false
        model = try? c.decodeIfPresent(ModelChoice.self, forKey: .model)
        mode = (try? c.decodeIfPresent(LaunchMode.self, forKey: .mode)) ?? .auto
        workspace = (try? c.decodeIfPresent(LaunchWorkspace.self, forKey: .workspace)) ?? .checkout
        plan = try c.decodeIfPresent(Bool.self, forKey: .plan) ?? false
        lastMachine = try c.decodeIfPresent(String.self, forKey: .lastMachine)
        lastProject = try c.decodeIfPresent([String: String].self, forKey: .lastProject) ?? [:]
    }
    enum Keys: String, CodingKey { case machine, scratch, model, mode, workspace, plan, lastMachine, lastProject }
}

/// What one Start sends.
public struct LaunchRequest: Equatable, Sendable {
    public var title: String
    public var message: String
    /// nil = Scratch.
    public var projectId: String?
    public var model: ModelChoice?
    public var mode: LaunchMode
    public var workspace: LaunchWorkspace
    public var plan: Bool
    public var clientRequestId: String

    /// The title T3 shows: what the user typed in Options, else the first line of the task, at most 60 characters.
    public static func title(override: String, message: String) -> String {
        let o = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { return String(o.prefix(80)) }
        let first = message.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if first.count <= 60 { return first.isEmpty ? "New thread" : first }
        return String(first.prefix(59)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public var arguments: [String: JSON] {
        var a: [String: JSON] = ["title": .string(title), "message": .string(message), "runtimeMode": .string(mode.rawValue),
                                 "interactionMode": .string(plan ? "plan" : "default"), "clientRequestId": .string(clientRequestId)]
        if let projectId {
            a["projectId"] = .string(projectId)
            a["workspaceStrategy"] = workspace == .worktree ? ["type": "worktree", "startFromOrigin": true] : ["type": "root"]
        } else { a["scratch"] = true }
        if let model { a["modelSelection"] = ["instanceId": .string(model.instanceId), "model": .string(model.model)] }
        return a
    }
}

extension MCPClient {
    /// The machine's projects (`t3_project_list`), archived and deleted ones left out.
    public func projects(environment: String? = nil) async throws -> [ProjectSummary] {
        var args: [String: JSON] = ["limit": 100]
        if let environment { args["environmentId"] = .string(environment) }
        let r = try await callTool("t3_project_list", .object(args))
        return (r["projects"].array ?? []).compactMap { p in
            guard let id = p["id"].string ?? p["projectId"].string, p["archivedAt"].string == nil, p["deletedAt"].string == nil else { return nil }
            return ProjectSummary(id: id, title: DisplayText.clean(p["title"].string ?? p["name"].string ?? id),
                                  updatedAt: p["updatedAt"].string ?? "", pinned: p["pinnedAt"].string != nil)
        }
    }

    /// Providers, their models and allowed modes (`orchestrator_capabilities`); disabled providers left out.
    public func capabilities(environment: String? = nil) async throws -> [ProviderModels] {
        var args: [String: JSON] = [:]
        if let environment { args["environmentId"] = .string(environment) }
        let r = try await callTool("orchestrator_capabilities", .object(args))
        return (r["providers"].array ?? []).compactMap { p in
            guard let id = p["providerInstanceId"].string, (p["constraints"].array ?? []).isEmpty else { return nil }
            let name = DisplayText.clean(p["displayName"].string ?? id)
            let models = (p["models"].array ?? []).compactMap { m -> ModelChoice? in
                guard let mid = m["id"].string else { return nil }
                return ModelChoice(instanceId: id, model: mid, label: DisplayText.clean(m["label"].string ?? mid))
            }
            guard !models.isEmpty else { return nil }
            return ProviderModels(instanceId: id, name: name, models: models, runtimeModes: p["runtimeModes"].array?.compactMap(\.string))
        }
    }

    /// The only `t3_thread_launch` call in the app (spec 16). Returns the new thread's id.
    public func launchThread(_ r: LaunchRequest, environment: String? = nil) async throws -> String? {
        var args = r.arguments
        if let environment { args["environmentId"] = .string(environment) }
        let res = try await callTool("t3_thread_launch", .object(args))
        return res["threadId"].string ?? res["thread"]["threadId"].string
    }
}
