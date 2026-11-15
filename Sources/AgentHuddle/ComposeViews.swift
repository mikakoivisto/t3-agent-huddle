import SwiftUI
import AppKit
import HuddleCore

// Write an answer, send a message, steer a run (spec 13). What the user types is sent only on an explicit click or ⌘↩.
// Agent text never fills these fields; titles shown here are the cleaned ones the rows already use.

extension Theme {
    /// Steering changes the turn in progress, so the button says so in a colour of its own.
    static let steer = Color(red: 1.0, green: 0.62, blue: 0.18)
}

/// The text field the composers share: grows with its text up to `maxLines`, then scrolls. Snapshots draw plain text
/// (`ImageRenderer` cannot draw an `NSTextView`).
struct ComposeField: View {
    @Binding var text: String
    var placeholder: String
    var maxLines = 6
    var minHeight: CGFloat = 40
    var fixedHeight: CGFloat? = nil
    var focused = true
    var onExpand: (() -> Void)? = nil
    var disabled = false
    @Environment(\.snapshotMode) private var snapshot
    @FocusState private var hasFocus: Bool
    @State private var measured: CGFloat = 0

    private static let lineHeight: CGFloat = 17

    var body: some View {
        let cap = CGFloat(maxLines) * Self.lineHeight + 16
        let trailing: CGFloat = onExpand == nil ? 0 : 18
        Group {
            if snapshot {
                Text(verbatim: text.isEmpty ? placeholder : text).font(.system(size: 13))
                    .foregroundStyle(text.isEmpty ? Theme.dim : .white).lineLimit(fixedHeight == nil ? maxLines : nil)
                    .padding(.horizontal, 9).padding(.vertical, 8).padding(.trailing, trailing)
                    .frame(maxWidth: .infinity, minHeight: fixedHeight ?? minHeight, alignment: .topLeading)
                    .frame(height: fixedHeight)
            } else {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(verbatim: placeholder).font(.system(size: 13)).foregroundStyle(Theme.dim)
                            .padding(.horizontal, 9).padding(.vertical, 8).allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 13)).foregroundStyle(.white)
                        .scrollContentBackground(.hidden).background(Color.clear)
                        .padding(.horizontal, 4).padding(.vertical, 6).padding(.trailing, trailing)
                        .focused($hasFocus).disabled(disabled)
                }
                // Grows with the text (measured off a hidden copy), capped at `maxLines`, then the editor scrolls.
                .frame(height: fixedHeight ?? min(max(measured, minHeight), cap))
                .background(alignment: .topLeading) {
                    Text(verbatim: text + " ").font(.system(size: 13)).padding(.horizontal, 9).padding(.vertical, 8).padding(.trailing, trailing)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .background(GeometryReader { g in Color.clear.preference(key: FieldHeightKey.self, value: g.size.height) })
                }
                .onPreferenceChange(FieldHeightKey.self) { measured = $0 }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.terminal))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(hasFocus || (snapshot && focused) ? Theme.lime : Color.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if let onExpand {
                Button(action: onExpand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.grey)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Open in a bigger editor").padding(3)
            }
        }
        .onAppear { if focused && !snapshot && !disabled { hasFocus = true } }
    }
}

private struct FieldHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The send button. Running threads get the ⇄ part that flips Queue ↔ Steer (spec 13, D5).
struct SendButton: View {
    @ObservedObject var model: HuddleModel
    var session: Session
    var enabled: Bool
    var send: (_ steer: Bool) -> Void

    var body: some View {
        let label = model.sendLabel(session)
        let steering = session.t3Status.isActive && model.sendMode(session) == .steer   // orange also while sending or retrying a steer
        let fill = !enabled ? Theme.dim : (steering ? Theme.steer : Theme.lime)
        HStack(spacing: 0) {
            Button { send(false) } label: {
                Text(verbatim: label).font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                    .padding(.leading, 12).padding(.trailing, model.canSteer(session) ? 9 : 12).padding(.vertical, 6)
            }
            .buttonStyle(.plain).disabled(!enabled)
            .keyboardShortcut(.return, modifiers: .command)
            if model.canSteer(session) {
                Rectangle().fill(Color.black.opacity(0.25)).frame(width: 1, height: 16)
                Button { model.toggleSendMode(session.threadId) } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                        .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(steering ? "Queue it instead" : "Steer: send it into this turn")
            }
        }
        .background(Capsule().fill(fill))
        .background(   // ⌥⌘↩ steers once, without the toggle (only while running)
            Button("") { send(true) }.keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled(!enabled || !model.canSteer(session)).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        )
    }
}

/// The small composer under a row, and pinned at the bottom of the detail view.
struct MessageComposer: View {
    @ObservedObject var model: HuddleModel
    @ObservedObject var store: ComposerStore
    var session: Session
    var pinned = false     // detail view: always there, with a placeholder

    var body: some View {
        let id = session.threadId
        let key = ComposerStore.messageKey(id)
        let text = store.text(key)
        let ui = model.composeStates[id]
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let enabled = !model.readOnly && !blank && text.count <= HuddleModel.maxMessageLength && ui != .sending
        VStack(alignment: .leading, spacing: 7) {
            if !pinned {
                HStack(spacing: 4) {
                    Text(verbatim: "To").foregroundStyle(Theme.grey)
                    Text(verbatim: session.title).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    if let machine = machineName { Text(verbatim: "· \(machine)").foregroundStyle(Theme.grey).lineLimit(1) }
                }.font(.system(size: 11.5, weight: .medium))
            }
            ComposeField(text: Binding(get: { store.text(key) }, set: { store.drafts[key] = $0 }),
                         placeholder: "Message \(session.title)…", maxLines: pinned ? 4 : 6, focused: !pinned,
                         onExpand: { ComposeWindowController.shared.show(model: model, threadId: id) },
                         disabled: model.readOnly)
            if text.count > 18_000 {
                Text(verbatim: "\(text.count) / \(HuddleModel.maxMessageLength)").font(.system(size: 11))
                    .foregroundStyle(text.count > HuddleModel.maxMessageLength ? Theme.red : Theme.grey)
            }
            if model.readOnly {
                Text(verbatim: "Read-only mode. Turn it off in the menu to send.").font(.system(size: 11.5)).foregroundStyle(Theme.grey)
            } else if let notice = model.composeNotices[id] {
                Text(verbatim: notice).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.steer)
            } else if case .error(let msg) = ui {
                Text(verbatim: msg).font(.system(size: 11.5)).foregroundStyle(Theme.red).lineLimit(2)
            } else {
                Text(verbatim: model.sendHint(session)).font(.system(size: 11)).foregroundStyle(Theme.grey)
            }
            HStack(spacing: 8) {
                SendButton(model: model, session: session, enabled: enabled) { steer in
                    Task { await model.sendMessage(threadId: id, steer: steer) }
                }
                if !pinned {
                    Button { model.closeComposer(id) } label: { Pill(text: "Cancel", fill: Color.white.opacity(0.12), fg: .white) }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                }
                Spacer()
                Text(verbatim: model.canSteer(session) ? "⌘↩ · ⌥⌘↩ steer" : "⌘↩").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardRaised))
    }

    private var machineName: String? {
        guard model.environments.count > 1, let e = session.environmentId else { return nil }
        return model.environmentLabel(e)
    }
}

/// Writing an answer to a question instead of picking an option.
struct AnswerEditor: View {
    @ObservedObject var model: HuddleModel
    @ObservedObject var store: ComposerStore
    var session: Session
    var question: Question

    var body: some View {
        let key = ComposerStore.answerKey(question.requestId)
        let text = store.text(key)
        let ui = model.questionStates[question.requestId] ?? .pending
        let enabled = !model.readOnly && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.count <= HuddleModel.maxMessageLength && ui != .sending
        VStack(alignment: .leading, spacing: 8) {
            ComposeField(text: Binding(get: { store.text(key) }, set: { store.drafts[key] = $0 }),
                         placeholder: "Write your answer…", disabled: model.readOnly)
            if model.readOnly {
                Text(verbatim: "Read-only mode. Turn it off in the menu to send.").font(.system(size: 11.5)).foregroundStyle(Theme.grey)
            } else if case .error(let msg) = ui {
                Text(verbatim: msg).font(.system(size: 12)).foregroundStyle(Theme.red).lineLimit(2)
            }
            HStack(spacing: 8) {
                Button { Task { await model.sendWrittenAnswer(threadId: session.threadId) } } label: {
                    Pill(text: ui == .sending ? "Sending…" : "Send answer", fill: enabled ? Theme.lime : Theme.dim)
                }.buttonStyle(.plain).disabled(!enabled).keyboardShortcut(.return, modifiers: .command)
                Button { model.stopWritingAnswer() } label: {
                    Pill(text: question.answerableInWidget ? "Back to options" : "Cancel", fill: Color.white.opacity(0.12), fg: .white)
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                Spacer()
                Text(verbatim: "⌘↩").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
            }
        }
    }
}

// MARK: - Pop-out editor (spec 13, D6)

@MainActor
final class ComposeWindowController: NSObject, NSWindowDelegate {
    static let shared = ComposeWindowController()
    private var windows: [String: NSWindow] = [:]

    func show(model: HuddleModel, threadId: String) {
        guard let s = model.state.sessions[threadId] else { return }
        if windows[threadId] == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            let machine = model.environments.count > 1 ? s.environmentId.map { " — \(model.environmentLabel($0))" } ?? "" : ""
            w.title = "Message · \(s.title)\(machine)"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentMinSize = NSSize(width: 420, height: 260)
            w.backgroundColor = NSColor(Theme.panel)
            w.contentView = NSHostingView(rootView: ComposeEditorView(model: model, store: model.composer, threadId: threadId,
                                                                      close: { [weak self] in self?.close(threadId) }))
            w.center()
            windows[threadId] = w
        }
        model.closeComposer(threadId)      // one editor at a time for a draft: the small one closes, the text stays
        NSApp.activate(ignoringOtherApps: true)
        windows[threadId]?.makeKeyAndOrderFront(nil)
    }

    func close(_ threadId: String) { windows[threadId]?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = windows.first(where: { $0.value === w })?.key else { return }
        windows[id] = nil
    }
}

struct ComposeEditorView: View {
    @ObservedObject var model: HuddleModel
    @ObservedObject var store: ComposerStore
    var threadId: String
    var close: () -> Void

    var body: some View {
        let key = ComposerStore.messageKey(threadId)
        let text = store.text(key)
        let ui = model.composeStates[threadId]
        VStack(alignment: .leading, spacing: 8) {
            if let s = model.state.sessions[threadId] {
                let enabled = !model.readOnly && model.canMessage(s) && ui != .sending && text.count <= HuddleModel.maxMessageLength
                    && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                GeometryReader { geo in
                    ComposeField(text: Binding(get: { store.text(key) }, set: { store.drafts[key] = $0 }),
                                 placeholder: "Message \(s.title)…", fixedHeight: max(120, geo.size.height), disabled: model.readOnly)
                }
                HStack {
                    Text(verbatim: s.isWorking ? "\(s.statusLine)" : "Not running").lineLimit(1)
                    Spacer()
                    Text(verbatim: text.count > 18_000 ? "\(text.count) / \(HuddleModel.maxMessageLength)" : Self.words(text))
                        .foregroundStyle(text.count > HuddleModel.maxMessageLength ? Theme.red : Theme.dim)
                }.font(.system(size: 11)).foregroundStyle(Theme.dim)
                if model.readOnly {
                    Text(verbatim: "Read-only mode. Turn it off in the menu to send.").font(.system(size: 12)).foregroundStyle(Theme.grey)
                } else if !model.canMessage(s) {
                    Text(verbatim: "This thread is asking for something first. Answer it in the panel or in T3 Code.").font(.system(size: 12)).foregroundStyle(Theme.grey)
                } else if let notice = model.composeNotices[threadId] {
                    Text(verbatim: notice).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.steer)
                } else if case .error(let msg) = ui {
                    Text(verbatim: msg).font(.system(size: 12)).foregroundStyle(Theme.red).lineLimit(2)
                } else {
                    Text(verbatim: model.sendHint(s)).font(.system(size: 12)).foregroundStyle(Theme.grey)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button { close() } label: { Pill(text: "Cancel", fill: Color.white.opacity(0.12), fg: .white) }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    SendButton(model: model, session: s, enabled: enabled) { steer in
                        Task {
                            await model.sendMessage(threadId: threadId, steer: steer)
                            if store.drafts[key] == nil { close() }    // sent
                        }
                    }
                }
            } else {
                Text(verbatim: "This thread is no longer in the list. The text was not sent.").font(.system(size: 13)).foregroundStyle(Theme.grey)
                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 420, minHeight: 260)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    static func words(_ s: String) -> String {
        let n = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return "\(n) word\(n == 1 ? "" : "s")"
    }
}
