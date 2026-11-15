import Foundation

// MARK: - T3 wire models (decoded tolerantly from `JSON`)

public enum T3Status: String, Sendable, Equatable {
    case idle, preparing, queued, starting, running, waiting
    case completed, interrupted, failed, cancelled
    case rolledBack = "rolled_back"
    case unknown

    public init(raw: String?) { self = raw.flatMap(T3Status.init(rawValue:)) ?? .unknown }

    public var isActive: Bool {
        switch self {
        case .preparing, .queued, .starting, .running, .waiting: return true
        default: return false
        }
    }
    public var isFinished: Bool {
        switch self {
        case .completed, .interrupted, .failed, .cancelled, .rolledBack: return true
        default: return false
        }
    }
    /// Words used for the status line when nothing more specific applies (SPEC §8).
    public var words: String {
        switch self {
        case .queued: return "Queued"
        case .preparing, .starting: return "Starting"
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .cancelled: return "Cancelled"
        case .rolledBack: return "Rolled back"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }
    public static let activeStatuses: [String] = ["preparing", "queued", "starting", "running", "waiting"]
    public static let finishedStatuses: [String] = ["completed", "failed", "interrupted", "cancelled"]
}

public struct ThreadSummary: Equatable, Sendable {
    public var threadId: String
    public var projectId: String
    public var title: String
    public var link: String?
    public var status: T3Status
    public var settled: Bool
    public var snoozed: Bool
    public var parentThreadId: String?
    public var itemCount: Int
    public var updatedAt: String
    /// From the `environmentId` field, else parsed from `link` (`…/threads/<env>/<id>` or `t3-thread://v2/<env>/<id>`).
    public var environmentId: String?
    public var providerInstanceId: String?
    public var model: String?
    public var branch: String?

    public init(threadId: String, projectId: String = "", title: String = "", link: String? = nil,
                status: T3Status, settled: Bool = false, snoozed: Bool = false,
                parentThreadId: String? = nil, itemCount: Int = 0, updatedAt: String = "", environmentId: String? = nil,
                providerInstanceId: String? = nil, model: String? = nil, branch: String? = nil) {
        self.providerInstanceId = providerInstanceId; self.model = model; self.branch = branch
        self.threadId = threadId; self.projectId = projectId; self.title = title; self.link = link
        self.status = status; self.settled = settled; self.snoozed = snoozed
        self.parentThreadId = parentThreadId; self.itemCount = itemCount; self.updatedAt = updatedAt
        self.environmentId = environmentId
    }

    public static func environment(fromLink link: String?) -> String? {
        guard let link else { return nil }
        let parts = link.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: "threads"), parts.indices.contains(i + 1) { return parts[i + 1] }
        if let i = parts.firstIndex(of: "v2"), parts.indices.contains(i + 1) { return parts[i + 1] }
        return nil
    }

    /// A linked machine's T3 returns `link` as a markdown link, `[Title](t3-thread://v2/<env>/<id>)`, where this Mac's T3
    /// returns a bare URL. Return just the URL in both cases (a trailing `)` would end up in the thread id).
    public static func bareLink(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let r = s.range(of: "](", options: .backwards), s.hasSuffix(")") {
            s = String(s[r.upperBound...].dropLast())
        }
        if s.hasPrefix("<") && s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        return s
    }

    public init?(json j: JSON) {
        guard let id = j["threadId"].string, id.utf8.count <= 512 else { return nil }   // an absurd id is not a thread
        let link = Self.bareLink(j["link"].string)
        self.init(
            threadId: id,
            projectId: j["projectId"].string ?? "",
            title: j["title"].string ?? "Untitled",
            link: link,
            status: T3Status(raw: j["status"].string),
            settled: j["settled"].bool ?? false,
            snoozed: j["snoozed"].bool ?? false,
            parentThreadId: j["parentThreadId"].string,
            itemCount: j["itemCount"].int ?? 0,
            updatedAt: j["updatedAt"].string ?? "",
            environmentId: j["environmentId"].string ?? Self.environment(fromLink: link),
            providerInstanceId: j["providerInstanceId"].string, model: j["model"].string, branch: j["branch"].string)
    }
}

public struct ThreadListPage: Equatable, Sendable {
    public var threads: [ThreadSummary]
    /// Live T3 returns a *number* (`"nextCursor": 5`); keep whatever type it is and send it back unchanged.
    public var nextCursor: JSON?
    /// True when the server reported no further page.
    public var isLast: Bool { nextCursor == nil || nextCursor?.isNull == true }

    public init(json j: JSON) {
        let rows = j["threads"].array ?? j["items"].array ?? j["results"].array ?? []
        threads = rows.compactMap(ThreadSummary.init(json:))
        // NB: JSON is ExpressibleByNilLiteral, so `cond ? nil : json` would wrap `.null` in an Optional. Be explicit.
        if j["nextCursor"].isNull { nextCursor = Optional<JSON>.none } else { nextCursor = Optional(j["nextCursor"]) }
    }
}

public struct ActivityItem: Equatable, Sendable {
    public var position: Int
    public var itemId: String
    public var type: String
    public var status: String
    public var title: String?
    public var text: String?
    public var textTruncated: Bool
    public var nextTextOffset: Int?
    public var updatedAt: String?
    public var runId: String?

    public init(position: Int, itemId: String, type: String, status: String,
                title: String? = nil, text: String? = nil, textTruncated: Bool = false,
                nextTextOffset: Int? = nil, updatedAt: String? = nil, runId: String? = nil) {
        self.position = position; self.itemId = itemId; self.type = type; self.status = status
        self.title = title; self.text = text; self.textTruncated = textTruncated
        self.nextTextOffset = nextTextOffset; self.updatedAt = updatedAt; self.runId = runId
    }

    public init?(json j: JSON) {
        guard let id = j["itemId"].string, let pos = j["position"].int else { return nil }
        self.init(position: pos, itemId: id, type: j["type"].string ?? "unknown",
                  status: j["status"].string ?? "completed",
                  title: j["title"].string, text: j["text"].string,
                  textTruncated: j["truncated"].bool ?? j["textTruncated"].bool ?? false,
                  nextTextOffset: j["nextTextOffset"].int, updatedAt: j["updatedAt"].string, runId: j["runId"].string)
    }
}

public struct ThreadRead: Equatable, Sendable {
    public var threadId: String
    public var status: T3Status
    public var title: String?
    public var activeRunId: String?
    public var pendingRequestCount: Int
    public var items: [ActivityItem]
    public var hasMore: Bool
    public var latestRunId: String?
    public var providerInstanceId: String?
    public var model: String?
    public var branch: String?
    public var runCount: Int?
    /// The newest run (`recentRuns` with `runLimit: 1`): start, end and the model that actually executed.
    public var run: RunInfo?

    public init(threadId: String, status: T3Status, title: String? = nil, activeRunId: String? = nil,
                pendingRequestCount: Int = 0, items: [ActivityItem] = [], hasMore: Bool = false, latestRunId: String? = nil,
                providerInstanceId: String? = nil, model: String? = nil, branch: String? = nil, runCount: Int? = nil, run: RunInfo? = nil) {
        self.providerInstanceId = providerInstanceId; self.model = model; self.branch = branch; self.runCount = runCount; self.run = run
        self.threadId = threadId; self.status = status; self.title = title
        self.activeRunId = activeRunId; self.pendingRequestCount = pendingRequestCount
        self.items = items; self.hasMore = hasMore; self.latestRunId = latestRunId
    }

    public init(json j: JSON) {
        let t = j["thread"].isNull ? j : j["thread"]
        self.init(
            threadId: t["threadId"].string ?? j["threadId"].string ?? "",
            status: T3Status(raw: t["status"].string),
            title: t["title"].string,
            activeRunId: t["activeRunId"].string,
            pendingRequestCount: t["pendingRequestCount"].int ?? 0,
            items: (j["items"].array ?? j["activity"].array ?? []).compactMap(ActivityItem.init(json:)),
            hasMore: j["hasMore"].bool ?? false,
            latestRunId: t["latestRunId"].string ?? t["activeRunId"].string,
            providerInstanceId: t["providerInstanceId"].string, model: t["model"].string, branch: t["branch"].string,
            runCount: t["runCount"].int,
            run: (j["recentRuns"].array ?? []).compactMap(RunInfo.init(json:)).max(by: { $0.ordinal < $1.ordinal }))
    }
}

public struct RunInfo: Equatable, Sendable {
    public var ordinal: Int
    public var startedAt: String?
    public var completedAt: String?
    public var model: String?
    /// Null while running (and for some providers even afterwards): unknown, not "different".
    public var executedModel: String?
    public init(ordinal: Int = 0, startedAt: String? = nil, completedAt: String? = nil, model: String? = nil, executedModel: String? = nil) {
        self.ordinal = ordinal; self.startedAt = startedAt; self.completedAt = completedAt; self.model = model; self.executedModel = executedModel
    }
    public init?(json j: JSON) {
        guard j["runId"].string != nil || j["ordinal"].int != nil else { return nil }
        self.init(ordinal: j["ordinal"].int ?? 0, startedAt: j["startedAt"].string ?? j["requestedAt"].string,
                  completedAt: j["completedAt"].string, model: j["model"].string, executedModel: j["executedModel"].string)
    }
}

// MARK: - Questions (shape ASSUMED, SPEC Q5 — isolated here so M0 can correct it in one place)

public struct QuestionOption: Equatable, Sendable, Hashable {
    public var label: String
    public var detail: String?
    public init(label: String, detail: String? = nil) { self.label = label; self.detail = detail }
}

public struct Question: Equatable, Sendable {
    public var requestId: String
    public var threadId: String
    public var questionId: String
    public var tag: String?
    public var prompt: String
    public var options: [QuestionOption]
    public var multiSelect: Bool
    /// False for anything the options cannot answer (several questions, multi-select, no options).
    public var answerableInWidget: Bool
    /// A single, not multi-select question: it can be answered with text the user writes (spec 13), options or not.
    public var freeTextAnswerable: Bool

    public init(requestId: String, threadId: String, questionId: String = "0", tag: String? = nil,
                prompt: String, options: [QuestionOption], multiSelect: Bool = false,
                answerableInWidget: Bool = true, freeTextAnswerable: Bool = false) {
        self.requestId = requestId; self.threadId = threadId; self.questionId = questionId
        self.tag = tag; self.prompt = prompt; self.options = options
        self.multiSelect = multiSelect; self.answerableInWidget = answerableInWidget
        self.freeTextAnswerable = freeTextAnswerable
    }
}

public enum QuestionCodec {
    /// `t3_pending_request {action:"list"}` → request ids. Approvals are never listed (§5.4).
    public static func requestIds(fromList j: JSON) -> [String] {
        // Live T3: {"requestIds": [...]} (L6). Older/assumed shapes kept as fallbacks.
        if let ids = j["requestIds"].array { return ids.compactMap { $0.string ?? $0["requestId"].string ?? $0["id"].string } }
        let rows = j["requests"].array ?? j["pending"].array ?? j["items"].array ?? []
        return rows.compactMap { $0["requestId"].string ?? $0["id"].string }
    }

    /// `t3_pending_request {action:"read"}` → a `Question`.
    public static func question(fromRead j: JSON, threadId: String) -> Question? {
        guard let requestId = j["requestId"].string ?? j["id"].string else { return nil }
        let qs = j["questions"].array ?? []
        let first = qs.first ?? j
        let prompt = first["question"].string ?? first["prompt"].string ?? first["text"].string
        guard let prompt else { return nil }
        let options = (first["options"].array ?? []).compactMap { o -> QuestionOption? in
            if let s = o.string { return QuestionOption(label: s) }
            guard let l = o["label"].string else { return nil }
            return QuestionOption(label: l, detail: o["description"].string)
        }
        let multi = first["multiSelect"].bool ?? false
        let simple = qs.count <= 1 && !multi && !options.isEmpty
        return Question(requestId: requestId, threadId: threadId,
                        questionId: first["id"].string ?? "0",
                        tag: first["header"].string ?? first["tag"].string,
                        prompt: prompt, options: options, multiSelect: multi,
                        answerableInWidget: simple, freeTextAnswerable: qs.count <= 1 && !multi)
    }

    /// Arguments for `respond`. Shape ASSUMED: `{requestId, answers: {<questionId>: <label or written text>}}`.
    public static func respondArguments(question q: Question, selection: String) -> JSON {
        ["action": "respond", "threadId": .string(q.threadId), "requestId": .string(q.requestId),
         "answers": .object([q.questionId: .string(selection)])]
    }
}

public struct HuddleEnvironment: Equatable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var isLocal: Bool
    public init(id: String, label: String, isLocal: Bool) { self.id = id; self.label = label; self.isLocal = isLocal }
}
