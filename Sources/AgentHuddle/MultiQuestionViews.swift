import SwiftUI
import HuddleCore

/// Several questions in one request (spec 04): one question at a time with "n of N" and dots; an option moves on to the next
/// question; Write answer replaces the options for that question; the last one leads to a review where Send answers them all.
struct MultiQuestionPanel: View {
    @ObservedObject var model: HuddleModel
    @ObservedObject var store: ComposerStore
    var session: Session
    var question: Question

    var body: some View {
        let step = model.multiStep(question)
        let ui = model.questionStates[question.requestId] ?? .pending
        VStack(alignment: .leading, spacing: 9) {
            if question.parts.indices.contains(step) {
                partView(question.parts[step], index: step)
            } else {
                review(ui)
            }
            if model.readOnly {
                Text(verbatim: "Read-only mode. Turn it off in the menu to send.").font(.system(size: 11.5)).foregroundStyle(Theme.grey)
            } else if case .error(let msg) = ui {
                Text(verbatim: msg).font(.system(size: 12)).foregroundStyle(Theme.red).lineLimit(2)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardRaised))
    }

    // MARK: One question

    @ViewBuilder private func partView(_ part: QuestionPart, index: Int) -> some View {
        let answer = model.multiAnswer(question, part)
        let writing = model.multiWritingFor == question.requestId
        header(tag: part.tag, trailing: "\(index + 1) of \(question.parts.count)", current: index)
        Text(verbatim: part.prompt).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
        if writing {
            let key = HuddleModel.multiDraftKey(question.requestId, part.id)
            let text = store.text(key).trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = !text.isEmpty && text.count <= HuddleModel.maxMessageLength
            ComposeField(text: Binding(get: { store.text(key) }, set: { store.drafts[key] = $0 }),
                         placeholder: "Write your answer…", disabled: model.readOnly)
            HStack(spacing: 8) {
                Button { model.useWrittenMultiAnswer(question) } label: {
                    Pill(text: "Use this answer", fill: ok ? Theme.lime : Theme.dim)
                }.buttonStyle(.plain).disabled(!ok).keyboardShortcut(.return, modifiers: .command)
                Button { model.cancelWritingMultiAnswer() } label: {
                    Pill(text: "Back to options", fill: Color.white.opacity(0.12), fg: .white)
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
        } else {
            ForEach(part.options, id: \.self) { opt in
                optionRow(opt, on: answer == opt.label)
            }
            if let answer, !part.options.contains(where: { $0.label == answer }) {
                // A written answer is shown like a chosen option.
                HStack(alignment: .top, spacing: 9) {
                    radio(on: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "Your answer").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.grey)
                        Text(verbatim: answer).font(.system(size: 13.5)).foregroundStyle(.white).lineLimit(4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.lime, lineWidth: 1.5))
            }
            HStack(spacing: 7) {
                if index > 0 {
                    Button { model.goToMultiStep(question, index - 1) } label: { Pill(text: "Back", fill: Color.white.opacity(0.12), fg: .white) }
                        .buttonStyle(.plain)
                }
                if answer != nil {
                    let last = index == question.parts.count - 1 || model.multiAllAnswered(question)
                    Button { model.goToMultiStep(question, last ? question.parts.count : index + 1) } label: {
                        Pill(text: last ? "Review answers" : "Next", fill: Theme.lime)
                    }.buttonStyle(.plain)
                }
                Button { model.startWritingMultiAnswer(question) } label: {
                    Pill(text: "Write answer", fill: Color.white.opacity(0.12), fg: .white)
                }.buttonStyle(.plain).disabled(model.readOnly)
            }
        }
    }

    private func optionRow(_ opt: QuestionOption, on: Bool) -> some View {
        Button { model.chooseMultiAnswer(question, opt.label) } label: {
            HStack(alignment: .top, spacing: 9) {
                radio(on: on)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: opt.label).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if let d = opt.detail, !d.isEmpty {
                        Text(verbatim: d).font(.system(size: 11.5)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.lime, lineWidth: on ? 1.5 : 0))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.readOnly)
    }

    private func radio(on: Bool) -> some View {
        Circle().fill(on ? Theme.lime : Color.clear).frame(width: 9, height: 9)
            .overlay(Circle().stroke(on ? Theme.lime : Theme.dim, lineWidth: 1.5)).padding(.top, 4)
    }

    // MARK: Header and review

    private func header(tag: String?, trailing: String, current: Int?) -> some View {
        HStack(spacing: 8) {
            if let tag {
                Text(verbatim: tag.uppercased()).font(.system(size: 11, weight: .heavy)).foregroundStyle(.black).lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 5).fill(Theme.lime))
            }
            Spacer(minLength: 4)
            Text(verbatim: trailing).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.grey)
            HStack(spacing: 4) {
                ForEach(question.parts.indices, id: \.self) { i in
                    let done = model.multiAnswer(question, question.parts[i]) != nil
                    Button { model.goToMultiStep(question, i) } label: {
                        Circle().fill(done ? Theme.lime : Color.white.opacity(0.25)).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color.white, lineWidth: current == i ? 1.5 : 0).padding(-2.5))
                    }.buttonStyle(.plain).help(question.parts[i].tag ?? "Question \(i + 1)")
                }
            }
        }
    }

    @ViewBuilder private func review(_ ui: QuestionUIState) -> some View {
        let n = question.parts.count
        let answered = question.parts.filter { model.multiAnswer(question, $0) != nil }.count
        header(tag: "Your answers", trailing: "\(answered) of \(n) answered", current: nil)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(question.parts.indices, id: \.self) { i in
                let p = question.parts[i]
                Button { model.goToMultiStep(question, i) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: (p.tag ?? "Question \(i + 1)").uppercased()).font(.system(size: 10.5, weight: .heavy)).foregroundStyle(Theme.grey)
                        Text(verbatim: model.multiAnswer(question, p) ?? "No answer yet").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(model.multiAnswer(question, p) == nil ? Theme.red : .white).lineLimit(2)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("Change this answer")
            }
        }
        let ready = answered == n && !model.readOnly && ui != .sending
        HStack(spacing: 7) {
            Button { model.goToMultiStep(question, n - 1) } label: { Pill(text: "Back", fill: Color.white.opacity(0.12), fg: .white) }
                .buttonStyle(.plain)
            Button { Task { await model.sendMultiAnswers(threadId: session.threadId) } } label: {
                Pill(text: ui == .sending ? "Sending…" : "Send \(n) answers", fill: ready ? Theme.lime : Theme.dim)
            }.buttonStyle(.plain).disabled(!ready)
        }
    }
}
