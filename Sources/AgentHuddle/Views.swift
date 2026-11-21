import SwiftUI
import HuddleCore

// Agent-supplied strings (titles, commands, questions, options) are always rendered with
// `Text(verbatim:)`: no markdown, no links, so an agent cannot draw a fake button (SPEC §10).

// MARK: - Snapshot support

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// `ImageRenderer` cannot draw `ScrollView` content, so offscreen snapshots swap it for a plain stack.
    var snapshotMode: Bool { get { self[SnapshotModeKey.self] } set { self[SnapshotModeKey.self] = newValue } }
}

private struct ExpandCommandsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Snapshots only: draw long commands as if "Show full command" had been tapped (that toggle is view state, not model state).
    var expandCommands: Bool { get { self[ExpandCommandsKey.self] } set { self[ExpandCommandsKey.self] = newValue } }
}

/// Scrolls when the panel is shorter than its content. Its ideal height is the content's own height, so the window
/// fits the content when there is room and the list shrinks and scrolls when the window is capped or dragged shorter.
struct MaybeScroll<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshot
    @State private var contentHeight: CGFloat = 0
    @ViewBuilder var content: () -> Content
    var body: some View {
        if snapshot { content() }
        else {
            ScrollView(showsIndicators: false) {
                content().background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
            }
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .frame(minHeight: 0, idealHeight: max(contentHeight, 1), maxHeight: contentHeight > 0 ? contentHeight : nil)
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Buddy

struct BuddyView: View {
    var index: Int
    var size: CGFloat = 44
    var body: some View {
        let c = Theme.buddy(index)
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.14, style: .continuous).fill(c)
                VStack(spacing: size * 0.10) {
                    HStack(spacing: size * 0.20) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.black.opacity(0.75)).frame(width: size * 0.11, height: size * 0.15)
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.black.opacity(0.75)).frame(width: size * 0.11, height: size * 0.15)
                    }
                    Capsule().fill(Color.black.opacity(0.75)).frame(width: size * 0.22, height: size * 0.05)
                }
            }
            .frame(width: size * 0.84, height: size * 0.92)
            HStack(spacing: size * 0.30) {
                RoundedRectangle(cornerRadius: 2).fill(c.opacity(0.9)).frame(width: size * 0.13, height: size * 0.12)
                RoundedRectangle(cornerRadius: 2).fill(c.opacity(0.9)).frame(width: size * 0.13, height: size * 0.12)
            }
        }
        .frame(width: size, height: size * 1.04)
    }
}

struct BuddyPill: View {
    var index: Int
    var selected: Bool
    var body: some View {
        ZStack {
            Capsule().fill(Theme.buddy(index)).frame(width: 30, height: 22)
            HStack(spacing: 5) {
                Capsule().fill(Color.black.opacity(0.7)).frame(width: 3, height: 6)
                Capsule().fill(Color.black.opacity(0.7)).frame(width: 3, height: 6)
            }
        }
        .opacity(selected ? 1 : 0.55)
        .overlay(Capsule().stroke(Theme.lime, lineWidth: selected ? 1.5 : 0).padding(-2))
    }
}

// MARK: - Bits

struct IconButton: View {
    var system: String
    var help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.grey)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help)
    }
}

/// Plain-SwiftUI spinner (ProgressView is AppKit-backed and cannot be drawn by ImageRenderer).
struct Spinner: View {
    var size: CGFloat = 16
    @State private var spin = false
    var body: some View {
        Circle().trim(from: 0, to: 0.7).stroke(Theme.lime, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size - 2, height: size - 2).rotationEffect(.degrees(spin ? 360 : 0)).frame(width: size, height: size)
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
    }
}

struct Pill: View {
    var text: String
    var fill: Color
    var fg: Color = .black
    var body: some View {
        Text(verbatim: text).font(.system(size: 13, weight: .bold)).foregroundStyle(fg)
            .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(fill))
    }
}

// MARK: - Header

struct HeaderBar: View {
    @ObservedObject var model: HuddleModel
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(model.anyMachineConnected ? Theme.lime : Theme.dim).frame(width: 9, height: 9)
            Text(verbatim: "Agent Huddle").font(.system(size: 20, weight: .bold)).foregroundStyle(.white).lineLimit(1).fixedSize()
            // The count: orange (the menu-bar badge) while threads need you, a click goes to the first one; grey otherwise (spec 14).
            if model.attentionSessions.isEmpty {
                Text(verbatim: "\(model.state.count)").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.grey).fixedSize()
            } else {
                AttentionPill(model: model)
            }
            if model.canStartThreads {   // spec 16: start a new thread (expands a collapsed panel)
                Button { model.newThreadOpen ? model.closeNewThread() : model.openNewThread() } label: {
                    Image(systemName: model.newThreadOpen ? "xmark" : "plus").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(model.newThreadOpen ? .black : .white).frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 7).fill(model.newThreadOpen ? Theme.lime : Color.white.opacity(0.1)))
                }.buttonStyle(.plain).help("Start a new thread (⌘N)").keyboardShortcut("n", modifiers: .command)
            }
            Spacer(minLength: 4)
            IconButton(system: model.muted ? "speaker.slash" : "speaker.wave.2", help: model.muted ? "Unmute" : "Mute") { model.toggleMute() }
            IconButton(system: model.collapsed ? "chevron.down" : "chevron.up", help: model.collapsed ? "Expand" : "Collapse") { model.toggleCollapsed() }
            IconButton(system: "xmark", help: "Hide Agent Huddle") { model.hideWidget() }
        }
    }
}

struct DetailTopBar: View {
    @ObservedObject var model: HuddleModel
    var session: Session
    var body: some View {
        HStack(spacing: 8) {
            IconButton(system: "chevron.left", help: "Back") { model.back() }
            BuddyPill(index: session.buddy, selected: true)
            AttentionPill(model: model, excluding: session.threadId)
            Spacer(minLength: 4)
            IconButton(system: "arrow.up.forward.square", help: "Open in T3 Code") { Task { await model.jump(session: session) } }
            IconButton(system: model.muted ? "speaker.slash" : "speaker.wave.2", help: "Mute") { model.toggleMute() }
            IconButton(system: model.collapsed ? "chevron.down" : "chevron.up", help: "Collapse") { model.toggleCollapsed() }
            IconButton(system: "xmark", help: "Hide Agent Huddle") { model.hideWidget() }
        }
    }
}

// MARK: - Connection banner

struct ConnectionBanner: View {
    @ObservedObject var model: HuddleModel
    @State private var token = ""
    @State private var entering = false
    var body: some View {
        let local = model.state.connection
        if !model.anyMachineConnected {
            // Nothing connected yet: this Mac is one choice, another machine the other (spec 15).
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Connect to T3 Code").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                if local == .unauthorized {
                    ConnectChoice(icon: "laptopcomputer", title: "This Mac", detail: model.signingIn ? "Approve Agent Huddle in your browser…" : "T3 Code is running here") {
                        if model.signingIn {
                            Button("Cancel") { model.cancelSignIn() }.buttonStyle(.plain).foregroundStyle(Theme.lime).font(.system(size: 13, weight: .semibold))
                        } else {
                            Button { model.signIn() } label: { Pill(text: "Connect", fill: Theme.lime) }.buttonStyle(.plain)
                        }
                    }
                } else if let text = local.headline, local != .connected {
                    Text(verbatim: local == .notRunning ? "T3 Code isn’t running on this Mac." : text)
                        .font(.system(size: 12.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
                }
                ConnectChoice(icon: "desktopcomputer", title: "Another machine…", detail: "A Mac mini, a build box, over Tailscale") {
                    Button { MachinesWindowController.shared.show(model: model, adding: "") } label: {
                        Pill(text: "Add", fill: Color.white.opacity(0.12), fg: .white)
                    }.buttonStyle(.plain)
                }
                if local == .unauthorized && !model.signingIn {
                    if entering {
                        HStack {
                            SecureField("Paste scoped token", text: $token).textFieldStyle(.roundedBorder)
                            Button("Save") { let t = token; token = ""; entering = false; Task { await model.submitToken(t) } }
                        }
                        Text(verbatim: "Stored in the macOS Keychain only.").font(.system(size: 11)).foregroundStyle(Theme.dim)
                    } else {
                        Button { entering = true } label: { Text(verbatim: "or paste a token for this Mac").font(.system(size: 11)).foregroundStyle(Theme.dim) }.buttonStyle(.plain)
                    }
                }
                if let note = model.connectNote {
                    Text(verbatim: note).font(.system(size: 12)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        } else if case .error(let m) = local {
            Text(verbatim: m).font(.system(size: 12)).foregroundStyle(Theme.grey).frame(maxWidth: .infinity, alignment: .leading)
        } else if case .unsupported = local, let text = local.headline {
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Theme.grey).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ConnectChoice<Trailing: View>: View {
    var icon: String
    var title: String
    var detail: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).font(.system(size: 13.5, weight: .bold)).foregroundStyle(.white)
                Text(verbatim: detail).font(.system(size: 11.5)).foregroundStyle(Theme.grey).lineLimit(2)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardRaised))
    }
}

// MARK: - Rows

struct SessionRow: View {
    @ObservedObject var model: HuddleModel
    var session: Session
    var showsPanels = true
    @State private var hovering = false

    var body: some View {
        let armed = model.armedCloseID == session.threadId
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                BuddyView(index: session.buddy).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: session.title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Text(verbatim: session.statusLine)
                        .font(.system(size: 14, weight: session.needsAttention ? .semibold : .regular))
                        .foregroundStyle(session.needsAttention ? Theme.lime : Theme.grey).lineLimit(1)
                    InfoLine(model: model, session: session)
                }
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 0) {
                        if model.canMessage(session) {
                            let open = model.composingThreadId == session.threadId
                            Button { open ? model.closeComposer(session.threadId) : model.openComposer(session.threadId) } label: {
                                Image(systemName: open ? "bubble.left.fill" : "bubble.left").font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(open ? Theme.lime : Theme.grey).frame(width: 26, height: 26).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Message this thread")
                        }
                        IconButton(system: "arrow.up.forward.square", help: "Open in T3 Code") { Task { await model.jump(session: session) } }
                    }
                    if armed {
                        Button { model.closeTapped(session.threadId) } label: { Pill(text: "Close", fill: Theme.red, fg: .white) }.buttonStyle(.plain)
                    } else {
                        IconButton(system: "xmark", help: "Close") { model.closeTapped(session.threadId) }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.openDetail(session.threadId) }

            if showsPanels { AttentionPanels(model: model, session: session) }
            if showsPanels, model.composingThreadId == session.threadId, model.canMessage(session) {
                MessageComposer(model: model, store: model.composer, session: session)
            }
            if let note = model.rowToasts[session.threadId] {
                Text(verbatim: note).font(.system(size: 12.5, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Theme.lime))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Theme.lime, lineWidth: (hovering || session.needsAttention) ? 1.5 : 0))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)   // flashes once when the header pill brings you here
            .stroke(Theme.attention, lineWidth: model.flashThreadId == session.threadId ? 3 : 0)
            .animation(.easeInOut(duration: 0.3), value: model.flashThreadId))
        .onHover { hovering = $0 }
    }
}

/// Section label shown when threads come from more than one T3 environment (this Mac + linked ones).
struct EnvironmentHeader: View {
    var label: String
    var count: Int
    var badge: MachineBadge? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: label.uppercased()).font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.grey)
            Text(verbatim: "\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim)
            if let badge, badge != .thisMac, badge != .connected { MachineBadgeView(badge: badge) }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
        .padding(.top, 6).padding(.horizontal, 4)
    }
}

struct AttentionPanels: View {
    @ObservedObject var model: HuddleModel
    var session: Session
    var body: some View {
        if session.permission != nil { PermissionPanel(model: model, session: session) }
        if let q = session.question { QuestionPanel(model: model, session: session, question: q) }
        if let secret = session.secretPrompt { SecretPanel(model: model, session: session, prompt: secret) }
    }
}

/// The agent asked for a secret. Only T3 takes it: this panel says so and jumps there. It never has a field for the value.
struct SecretPanel: View {
    @ObservedObject var model: HuddleModel
    var session: Session
    var prompt: SecretPrompt
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "SECRET").font(.system(size: 12, weight: .heavy)).foregroundStyle(.black)
                .padding(.horizontal, 8).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 5).fill(Theme.lime))
            Text(verbatim: prompt.label).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "Enter it in T3 Code. Agent Huddle never asks for or keeps a secret.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
            Button { Task { await model.jump(session: session) } } label: { Pill(text: "Enter it in T3 Code", fill: Theme.lime) }.buttonStyle(.plain)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardRaised))
    }
}

/// Show it and jump. Allow / Deny exist only when the user opted in to inline approvals (SPEC §9.4, Q1); off by default.
struct PermissionPanel: View {
    @ObservedObject var model: HuddleModel
    var session: Session
    @State private var tappedShowFull = false
    @State private var armed = false
    @Environment(\.snapshotMode) private var snapshotMode
    @Environment(\.expandCommands) private var expandCommands
    private static let collapsedLines = 3
    private var showFull: Bool { tappedShowFull || expandCommands }

    var body: some View {
        let prompt = session.permission
        let detail = prompt?.detail
        // A command that could be clipped must be expanded before Allow works: what the user approves is what they saw.
        let long = detail.map(DisplayText.commandNeedsExpansion) ?? false
        VStack(alignment: .leading, spacing: 10) {
            if let tool = prompt?.tool {
                Text(verbatim: tool.uppercased()).font(.system(size: 12, weight: .heavy)).foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 5).fill(Theme.lime))
            }
            if let detail {
                Text(verbatim: DisplayText.clean(detail, allowNewlines: true)).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white)
                    .lineLimit(showFull || !long ? nil : Self.collapsedLines).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if long {
                    Button { tappedShowFull.toggle() } label: {
                        Text(verbatim: showFull ? "Show less" : "Show full command").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.grey)
                    }.buttonStyle(.plain)
                }
            } else {
                Text(verbatim: "Waiting for approval in T3 Code").font(.system(size: 13)).foregroundStyle(Theme.grey)
            }
            // Allow / Deny are opt-in (ApprovalSetup.swift); without them this is only "Review in T3 Code".
            ApprovalButtons(model: model, session: session, commandVisibleInFull: !long || showFull, armed: armed || snapshotMode) {
                Task { await model.jump(session: session) }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardRaised))
        // A different request under an open row starts collapsed and unarmed again, so an expansion or a click that belonged to
        // the previous request cannot carry over.
        .task(id: prompt?.requestId ?? prompt?.summary) {
            tappedShowFull = false
            armed = false
            try? await Task.sleep(nanoseconds: UInt64(ApprovalGate.armDelay * 1_000_000_000))
            if !Task.isCancelled { armed = true }
        }
    }
}

struct QuestionPanel: View {
    @ObservedObject var model: HuddleModel
    var session: Session
    var question: Question
    var body: some View {
        // Several questions in one request (spec 04): one at a time, then a review and one Send.
        if question.multiAnswerable && model.canAnswer(session) {
            MultiQuestionPanel(model: model, store: model.composer, session: session, question: question)
        } else { single }
    }

    @ViewBuilder private var single: some View {
        let selected = model.selections[question.requestId]
        let ui = model.questionStates[question.requestId] ?? .pending
        let writing = model.writingAnswerFor == question.requestId && question.freeTextAnswerable
        VStack(alignment: .leading, spacing: 10) {
            if let tag = question.tag {
                Text(verbatim: tag.uppercased()).font(.system(size: 12, weight: .heavy)).foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 5).fill(Theme.lime))
            }
            Text(verbatim: question.prompt).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !model.canAnswer(session) {
                // Shown through this Mac's T3 only: T3 refuses answers sent that way. Connecting the machine fixes it (spec 15).
                HStack(spacing: 6) {
                    Text(verbatim: "Connect \(session.environmentId.map(model.machineLabel) ?? "that machine") to answer here.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
                    Button { MachinesWindowController.shared.show(model: model) } label: {
                        Text(verbatim: "Machines…").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.lime)
                    }.buttonStyle(.plain)
                }
            } else if writing {
                AnswerEditor(model: model, store: model.composer, session: session, question: question)
            } else {
                if question.answerableInWidget {
                    if question.multiSelect {
                        Text(verbatim: "Pick one or more").font(.system(size: 12)).foregroundStyle(Theme.grey)
                    }
                    ForEach(question.options, id: \.self) { opt in
                        let on = question.multiSelect ? (model.checks[question.requestId]?.contains(opt.label) ?? false) : selected == opt.label
                        Button { model.select(option: opt.label, for: question) } label: {
                            HStack(spacing: 10) {
                                ChoiceMark(on: on, box: question.multiSelect)
                                Text(verbatim: opt.label).font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.lime, lineWidth: on ? 1.5 : 0))
                        }.buttonStyle(.plain)
                    }
                }
                if case .error(let msg) = ui {
                    Text(verbatim: msg).font(.system(size: 12)).foregroundStyle(Theme.red).lineLimit(2)
                }
                if question.answerableInWidget || question.freeTextAnswerable {
                    HStack(spacing: 8) {
                        if question.answerableInWidget {
                            Button { Task { await model.sendAnswer(threadId: session.threadId) } } label: {
                                Pill(text: ui == .sending ? "Sending…" : "Send", fill: selected == nil ? Theme.dim : Theme.lime)
                            }
                            .buttonStyle(.plain).disabled(selected == nil || ui == .sending)
                        }
                        if question.freeTextAnswerable {
                            Button { model.startWritingAnswer(question.requestId) } label: {
                                Pill(text: "Write answer", fill: question.answerableInWidget ? Color.white.opacity(0.12) : Theme.lime,
                                     fg: question.answerableInWidget ? .white : .black)
                            }.buttonStyle(.plain)
                        }
                    }
                } else {
                    // Several questions or multi-select: T3 Code only. The row's ↗ opens it.
                    Text(verbatim: "Answer this one in T3 Code: ↗ opens it.").font(.system(size: 12.5)).foregroundStyle(Theme.grey)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardRaised))
    }
}

// MARK: - Detail

struct DetailView: View {
    @ObservedObject var model: HuddleModel
    var session: Session
    var body: some View {
        VStack(spacing: 10) {
            DetailTopBar(model: model, session: session)
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    BuddyView(index: session.buddy, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: session.title).font(.system(size: 19, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                        Text(verbatim: session.statusLine).font(.system(size: 14, weight: session.needsAttention ? .semibold : .regular))
                            .foregroundStyle(session.needsAttention ? Theme.lime : Theme.grey).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                AttentionPanels(model: model, session: session)
                DetailInfo(model: model, session: session)
                Divider().overlay(Color.white.opacity(0.08))
                if session.steps.isEmpty {
                    Text(verbatim: "No steps yet").font(.system(size: 13)).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MaybeScroll {
                        VStack(alignment: .leading, spacing: 4) { ForEach(session.steps) { ExpandableStepRow(model: model, session: session, step: $0) } }
                    }
                }
                if model.canMessage(session) { MessageComposer(model: model, store: model.composer, session: session, pinned: true) }
                if let note = model.rowToasts[session.threadId] {
                    Text(verbatim: note).font(.system(size: 12.5, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Theme.lime))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        }
    }
}

// MARK: - Root

struct HuddleRootView: View {
    @ObservedObject var model: HuddleModel
    var body: some View {
        VStack(spacing: 10) {
            if let session = model.selected, !model.collapsed {
                DetailView(model: model, session: session)
            } else {
                HeaderBar(model: model)
                if !model.collapsed {
                    ConnectionBanner(model: model)
                    if model.newThreadOpen && model.canStartThreads { NewThreadComposer(model: model, store: model.composer) }
                    if model.sessions.isEmpty {
                        if model.anyMachineConnected {
                            Text(verbatim: "No active threads").font(.system(size: 14)).foregroundStyle(Theme.grey).padding(.vertical, 8)
                        }
                    } else {
                        ScrollViewReader { proxy in
                            MaybeScroll {
                                let groups = model.groups
                                VStack(spacing: 8) {
                                    ForEach(groups) { g in
                                        let badge = model.machineBadge(g.id)
                                        if groups.count > 1 || badge != .thisMac { EnvironmentHeader(label: g.label, count: g.sessions.count, badge: badge) }
                                        ForEach(g.sessions) { SessionRow(model: model, session: $0).id($0.threadId) }
                                            .opacity(badge == .offline ? 0.5 : 1)
                                    }
                                }
                            }
                            .onChange(of: model.revealThreadId) { _, id in   // the header pill: go to the first thread that needs you
                                guard let id else { return }
                                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
                                model.revealThreadId = nil
                            }
                        }
                    }
                }
            }
            if let toast = model.toast {
                Text(verbatim: toast).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 12).padding(.vertical, 7).background(Capsule().fill(Theme.lime))
            }
        }
        .padding(14)
        .frame(width: Theme.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Attention (spec 14)

extension Theme {
    /// Orange for "needs you" in the menu bar and the header pill: lime cannot be read on a light menu bar.
    static let attention = Color(red: 1.0, green: 0.54, blue: 0.12)
}

/// The attention count in orange, like the menu-bar badge: shown while threads ask for something.
/// A click goes to the first one (or the first other one, in a detail view).
struct AttentionPill: View {
    @ObservedObject var model: HuddleModel
    var excluding: String? = nil
    var body: some View {
        let n = model.attentionSessions.filter { $0.threadId != excluding }.count
        if n > 0 {
            Button { model.revealAttention(excluding: excluding) } label: {
                Text(verbatim: n > 99 ? "99+" : "\(n)").font(.system(size: 14, weight: .heavy).monospacedDigit()).foregroundStyle(.black)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 20).background(Capsule().fill(Theme.attention))
            }.buttonStyle(.plain).help(n == 1 ? "1 thread needs you" : "\(n) threads need you")
             .accessibilityLabel(n == 1 ? "1 needs you" : "\(n) need you")
        }
    }
}
