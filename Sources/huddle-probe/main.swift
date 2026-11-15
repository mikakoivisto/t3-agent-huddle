import Foundation
import HuddleCore

// huddle-probe — live check against the local T3 using a THROWAWAY pairing token (scripts/live-check.sh mints and revokes it).
//   HUDDLE_PAIRING_TOKEN=<12 chars> huddle-probe [--access read-only] [--call TOOL JSON]...
// Signs in through the advertised OAuth flow (approval = `pairing-code` decision), then makes read-only calls.
// The pairing token is read from the environment (never argv) and never printed; the access token stays in memory.

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

var access = "approval-required"   // read + operate scopes; never full-access
var runHuddle = false
var sendCheck: (steer: String, question: String)?
var sendRaw: (thread: String, mode: SendMode, environment: String?)?
var remoteCheck: (address: String, environmentId: String)?
var describe: [String] = []
var calls: [(String, JSON)] = []
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--access": access = it.next() ?? access
    case "--describe": describe.append(it.next() ?? "")   // print a tool's description + schema (read-only)
    case "--remote":   // live check of the "another machine" path: ADDRESS ENVIRONMENT_ID (see RemoteCheck.swift)
        guard let address = it.next(), let envId = it.next() else { fail("--remote ADDRESS ENVIRONMENT_ID") }
        remoteCheck = (address, envId)
    case "--send-check":   // spec 13 live check: SEND to these two THROWAWAY threads through the real HuddleModel
        guard let st = it.next(), let q = it.next() else { fail("--send-check STEER_THREAD_ID QUESTION_THREAD_ID") }
        sendCheck = (st, q)
    case "--send-raw":   // one t3_thread_send to THREAD (queue|steer), printing T3's whole answer or error
        guard let t = it.next(), let m = it.next().flatMap(SendMode.init(rawValue:)) else { fail("--send-raw THREAD queue|steer [ENVIRONMENT_ID]") }
        sendRaw = (t, m, nil)
    case "--env": if sendRaw != nil { sendRaw!.environment = it.next() }
    case "--huddle": runHuddle = true   // run the real HuddleModel against live T3 (read-only) and print what the panel would show
    case "--call":
        guard let name = it.next(), let json = it.next(), let j = try? JSON.parse(json) else { fail("--call TOOL JSON") }
        
        let readOnly: Set = ["t3_thread_list", "t3_thread_read", "t3_pending_request", "t3_project_list", "t3_project_read",
                             "t3_environment_read", "orchestrator_capabilities", "t3_environment_links", "t3_thread_search", "t3_worktree_list", "t3_worktree_status"]
        guard readOnly.contains(name) else { fail("refusing non-read-only tool \(name)") }
        if name == "t3_pending_request", let act = j["action"].string, act != "list", act != "read" { fail("pending_request: list/read only") }
        calls.append((name, j))
    default: fail("unknown option \(a)")
    }
}
if let r = remoteCheck { await RemoteCheck.run(address: r.address, environmentId: r.environmentId) }
guard let pairing = ProcessInfo.processInfo.environment["HUDDLE_PAIRING_TOKEN"], !pairing.isEmpty else { fail("set HUDDLE_PAIRING_TOKEN") }

let log = HuddleLog { _ in }                // silent; the probe prints its own redacted summary
log.register(secret: pairing)
let endpoint = try Discovery(runtimeFile: Discovery.defaultRuntimeFile).resolve().url
let session = LoopbackSession.probe()

/// "Browser": parse the authorize URL, POST the approval decision with the pairing code, follow redirectTo to our listener.
let opener: @Sendable (URL) -> Void = { url in
    Task.detached {
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { i in i.value.map { (i.name, $0) } })
        var authz: [String: JSON] = [:]
        for k in ["response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "resource"] {
            if let v = q[k] { authz[k] = .string(v) }
        }
        var base = URLComponents(url: url, resolvingAgainstBaseURL: false)!; base.path = "/oauth/mcp/decision"; base.query = nil
        for tag in ["_tag", "type"] {
            var req = URLRequest(url: base.url!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = ([ "authorization": .object(authz),
                              "decision": [tag: "pairing-code", "access": .string(access), "code": .string(pairing)] ] as JSON).data()
            guard let (data, resp) = try? await session.data(for: req) else { continue }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = (try? JSON.parse(data)) ?? .null
            if status == 200, let to = body["redirectTo"].string, let u = URL(string: to) { _ = try? await session.data(from: u); return }
            FileHandle.standardError.write(Data("decision(\(tag)) -> HTTP \(status)\n".utf8))   // status only: a server may echo a secret in its body
        }
    }
}

let oauth = try OAuthClient(mcpEndpoint: endpoint, log: log, opener: opener, timeout: 30)
let result: OAuthResult
do { result = try await oauth.authorize() } catch { fail("OAuth failed: \(error)") }
print("oauth: ok (client registered, token received, expires_in=\(result.expiresIn.map(String.init) ?? "?"))")

let client = try MCPClient(endpoint: endpoint, token: result.accessToken, log: log)
let tools = try await client.toolsList()
let list = tools["tools"].array ?? []
print("tools (\(list.count)):")
for t in list {
    let props = (t["inputSchema"]["properties"].object ?? [:]).keys.sorted().joined(separator: ",")
    print("  \(t["name"].string ?? "?")  [\(props)]")
}
for name in describe {
    if let t = list.first(where: { $0["name"].string == name }) { print("\nDESCRIBE \(name):\n\(t["description"].string ?? "")\nSCHEMA: \(t["inputSchema"].text())") }
}
print("contract check: \(ContractCheck.verify(toolsList: tools) ?? "ok")")
for (name, args) in calls {
    print("\n> \(name) \(args.text())")
    do { print(log.scrub((try await client.callTool(name, args)).text())) } catch { print(log.scrub("ERROR: \(error)")) }
}
if runHuddle {
    let model: HuddleModel = await MainActor.run {
        HuddleModel(config: HuddleConfig(source: .fixed(endpoint), tokenStore: MemoryTokenStore(token: result.accessToken), approvalStore: MemoryTokenStore(token: "probe-never-sent"), log: log))
    }
    await MainActor.run { }
    await model.refresh()
    await MainActor.run {
        print("\nHUDDLE connection=\(model.state.connection) failures=\(model.consecutiveFailures) note=\(model.connectNote ?? "-")")
        print("HUDDLE environments=\(model.environments.map { "\($0.label)\($0.isLocal ? "*" : "")" })  sessions=\(model.state.count)")
        for g in model.groups {
            print("HUDDLE group \(g.label) (\(g.sessions.count))")
            for s in g.sessions {
                print("  [\(s.t3Status.rawValue)] \(s.title.prefix(40)) | line=\"\(s.statusLine.prefix(50))\" steps=\(s.steps.count) attention=\(s.attention) pending=\(s.pendingRequestCount)")
                print("      model=\(s.model ?? "-") family=\(s.modelFamily) executed=\(s.executedModel ?? "-") branch=\(s.branch ?? "-") project=\(model.projectName(for: s) ?? "-") elapsed=\(s.elapsed().map { Session.formatDuration($0) } ?? "-") working=\(s.isWorking)")
                if s.permission != nil { print("      permission: summary=\(s.permission?.summary ?? "-") requestId=\(s.permission?.requestId != nil) env=\(s.environmentId ?? "nil") canDecideInline=\(model.canDecideInline(s)) approvalText=\(s.approvalText != nil)") }
            }
        }
    }
    if let first = await MainActor.run(body: { model.sessions.first?.threadId }) {
        await MainActor.run { model.openDetail(first) }
        await model.refresh()
        await MainActor.run {
            let sel = model.selected
            print("HUDDLE detail \(sel?.title.prefix(40) ?? "-"): steps=\(sel?.steps.count ?? 0) terminal=\(sel?.terminal.map { "$ \($0.command.prefix(50)) tail=\($0.tail.count) lines" } ?? "none")")
            print("HUDDLE tools called: \(Set(model.calledTools).sorted())")
        }
    }
}
if let r = sendRaw {
    do {
        try await client.sendMessage(threadId: r.thread, message: "Agent Huddle live check (send-raw, \(r.mode.rawValue)): ignore this line.",
                                     mode: r.mode, clientRequestId: UUID().uuidString, environment: r.environment)
        print("SEND-RAW ok")
    } catch { print(log.scrub("SEND-RAW error: \(error)")) }
}
if let sc = sendCheck {
    let model: HuddleModel = await MainActor.run {
        HuddleModel(config: HuddleConfig(source: .fixed(endpoint), tokenStore: MemoryTokenStore(token: result.accessToken), log: log))
    }
    await model.refresh()
    func state(_ id: String) async -> String {
        await MainActor.run {
            guard let s = model.state.sessions[id] else { return "not listed" }
            return "t3=\(s.t3Status.rawValue) canMessage=\(model.canMessage(s)) canSteer=\(model.canSteer(s)) label=\(model.sendLabel(s)) ui=\(String(describing: model.composeStates[id])) toast=\(model.rowToasts[id] ?? "-") notice=\(model.composeNotices[id] ?? "-")"
        }
    }
    print("\nSEND canSendMessages=\(await MainActor.run { model.canSendMessages })")
    print("SEND steer target before: \(await state(sc.steer))")
    await MainActor.run {
        model.openComposer(sc.steer)
        model.composer.drafts[ComposerStore.messageKey(sc.steer)] = "LIVE STEER TEST from Agent Huddle: as soon as you see this, say 'steer received' and keep going."
        model.toggleSendMode(sc.steer)
    }
    print("SEND steer label=\(await MainActor.run { model.state.sessions[sc.steer].map(model.sendLabel) ?? "-" })")
    await model.sendMessage(threadId: sc.steer)
    print("SEND after steer: \(await state(sc.steer))")
    await MainActor.run {
        model.openComposer(sc.steer)
        model.composer.drafts[ComposerStore.messageKey(sc.steer)] = "LIVE QUEUE TEST from Agent Huddle: this was queued; reply 'queue received'."
    }
    await model.sendMessage(threadId: sc.steer)
    print("SEND after queue: \(await state(sc.steer))")

    var asked = false
    for _ in 0..<30 {
        await model.refresh()
        if await MainActor.run(body: { model.state.sessions[sc.question]?.question != nil }) { asked = true; break }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }
    if asked {
        let info: String = await MainActor.run {
            let q = model.state.sessions[sc.question]!.question!
            model.startWritingAnswer(q.requestId)
            model.composer.drafts[ComposerStore.answerKey(q.requestId)] = "Blue (this is a written answer from the Agent Huddle live check)"
            return "options=\(q.options.map(\.label)) answerable=\(q.answerableInWidget) freeText=\(q.freeTextAnswerable) multi=\(q.multiSelect)"
        }
        print("SEND question: \(info)")
        await model.sendWrittenAnswer(threadId: sc.question)
        print("SEND after written answer: questionUI=\(await MainActor.run { model.questionStates.map { "\($0.value)" } }) toast=\(await MainActor.run { model.rowToasts[sc.question] ?? "-" })")
    } else { print("SEND question: none appeared within 90 s") }
    print("SEND tools called: \(Set(model.calledTools).sorted())")
}
print("\n(probe done; access token discarded with the process — revoke the session via scripts/live-check.sh)")
