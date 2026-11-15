import SwiftUI
import HuddleCore

// Row info line, detail info block and expandable steps. Agent text is rendered with `Text(verbatim:)`.

/// Small model mark. Three families get a drawn glyph, the rest a letter badge, so an unknown model never breaks the row.
struct ModelIcon: View {
    var session: Session
    var size: CGFloat = 16
    var body: some View {
        let f = session.modelFamily
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Self.tint(f).opacity(0.18))
            glyph(f)
        }
        .frame(width: size, height: size)
        .help(session.modelHover)
        .accessibilityLabel(Text(verbatim: session.modelHover.replacingOccurrences(of: "\n", with: ", ")))
    }

    static func tint(_ f: ModelFamily) -> Color {
        switch f {
        case .claude: return Color(red: 0.88, green: 0.54, blue: 0.37)
        case .openai: return Color(white: 0.85)
        case .grok: return Color(white: 0.95)
        case .qwen: return Color(red: 0.55, green: 0.45, blue: 0.95)
        case .gemini: return Color(red: 0.40, green: 0.60, blue: 0.98)
        case .glm: return Color(red: 0.25, green: 0.78, blue: 0.70)
        case .kimi: return Color(red: 0.30, green: 0.55, blue: 0.95)
        case .cursor: return Color(white: 0.9)
        case .copilot: return Color(red: 0.55, green: 0.80, blue: 0.45)
        case .deepseek: return Color(red: 0.30, green: 0.50, blue: 0.95)
        case .llama: return Color(red: 0.35, green: 0.65, blue: 0.95)
        case .mistral: return Color(red: 0.98, green: 0.62, blue: 0.20)
        case .pi: return Color(white: 0.8)
        case .other: return Color(white: 0.6)
        }
    }

    @ViewBuilder private func glyph(_ f: ModelFamily) -> some View {
        let c = Self.tint(f)
        switch f {
        case .claude:
            ZStack { ForEach(0..<4, id: \.self) { i in Capsule().fill(c).frame(width: size * 0.12, height: size * 0.62).rotationEffect(.degrees(Double(i) * 45)) } }
        case .openai:
            ZStack { Circle().stroke(c, lineWidth: size * 0.12).frame(width: size * 0.62, height: size * 0.62); Circle().fill(c).frame(width: size * 0.2, height: size * 0.2) }
        case .grok:
            ZStack { Circle().stroke(c, lineWidth: size * 0.11).frame(width: size * 0.6, height: size * 0.6)
                     Capsule().fill(c).frame(width: size * 0.11, height: size * 0.8).rotationEffect(.degrees(40)) }
        default:
            Text(verbatim: Self.letter(f, session.model)).font(.system(size: size * 0.62, weight: .heavy, design: .rounded)).foregroundStyle(c)
        }
    }

    static func letter(_ f: ModelFamily, _ model: String?) -> String {
        switch f {
        case .pi: return "π"
        case .other:
            let name = ModelInfo.displayName(model: model)
            return name.first.map { String($0).uppercased() } ?? "?"
        default: return String(f.rawValue.prefix(1)).uppercased()
        }
    }
}

struct DurationText: View {
    var session: Session
    @Environment(\.snapshotMode) private var snapshot
    var body: some View {
        if session.isWorking && !snapshot {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in label(ctx.date) }
        } else { label(Date()) }
    }
    @ViewBuilder private func label(_ now: Date) -> some View {
        if let t = session.elapsed(now: now) { Text(verbatim: Session.formatDuration(t)).monospacedDigit() }
    }
}

/// Replaces the progress bar: steps · run time · model icon · project, as quiet grey text.
struct InfoLine: View {
    @ObservedObject var model: HuddleModel
    var session: Session
    var body: some View {
        HStack(spacing: 7) {
            Text(verbatim: session.progressText).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.lime)
            if session.elapsed() != nil { dot; DurationText(session: session) }
            if session.model != nil { dot; ModelIcon(session: session) }
            if let p = model.projectName(for: session) { dot; Text(verbatim: p).lineLimit(1).truncationMode(.tail) }
        }
        .font(.system(size: 13)).foregroundStyle(Theme.grey)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var dot: some View { Text(verbatim: "·").foregroundStyle(Theme.dim) }
}

struct DetailInfo: View {
    @ObservedObject var model: HuddleModel
    var session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let p = model.projectName(for: session) {
                line("Project") { Text(verbatim: p); if let b = session.branch { Text(verbatim: "· \(b)").foregroundStyle(Theme.grey) } }
            } else if let b = session.branch { line("Branch") { Text(verbatim: b) } }
            if session.elapsed() != nil {
                line(session.isWorking ? "Running" : "Took") {
                    DurationText(session: session)
                    if let n = session.runCount { Text(verbatim: "· run \(n)").foregroundStyle(Theme.dim) }
                }
            }
            if session.model != nil {
                line("Model") {
                    ModelIcon(session: session)
                    Text(verbatim: ModelInfo.displayName(model: session.model))
                }
                if session.ranOnDifferentModel {
                    line("") { Text(verbatim: "→ ran on \(ModelInfo.displayName(model: session.executedModel))").foregroundStyle(Theme.lime) }
                }
            }
        }
        .font(.system(size: 13)).foregroundStyle(Color(white: 0.86))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func line<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(verbatim: title).foregroundStyle(Theme.dim).frame(width: 62, alignment: .leading)
            HStack(spacing: 6) { content() }
            Spacer(minLength: 0)
        }
    }
}

/// One step: tap to open. A running step is open until you close it; the rest start closed.
struct ExpandableStepRow: View {
    @ObservedObject var model: HuddleModel
    var session: Session
    var step: Step
    var body: some View {
        let open = model.isExpanded(threadId: session.threadId, step)
        VStack(alignment: .leading, spacing: 8) {
            Button { Task { await model.toggleStep(threadId: session.threadId, stepId: step.id) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                    switch step.state {
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.grey)
                    case .running: Spinner()
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
                    case .pending: Image(systemName: "circle").foregroundStyle(Theme.dim)
                    }
                    Image(systemName: step.kind == .edit ? "pencil" : step.kind == .terminal ? "terminal" : "wrench.and.screwdriver")
                        .font(.system(size: 12)).foregroundStyle(Theme.grey).frame(width: 16)
                    Text(verbatim: step.label).font(.system(size: 15)).lineLimit(1)
                        .foregroundStyle(step.state == .running ? Color.white : step.state == .failed ? Theme.red : Theme.grey)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { StepBody(step: step).padding(.leading, 26) }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(open ? Theme.cardRaised.opacity(0.55) : .clear))
    }
}

struct StepBody: View {
    var step: Step
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if step.kind == .terminal {
                Text(verbatim: DisplayText.clean("$ \(step.command ?? step.label)", allowNewlines: true)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.lime).lineLimit(3)
                let lines = Self.tail(step.output)
                if lines.isEmpty {
                    if step.state == .running { HStack(spacing: 6) { Spinner(size: 12); Text(verbatim: "waiting for output").font(.system(size: 12)).foregroundStyle(Theme.dim) } }
                } else {
                    Text(verbatim: DisplayText.clean(lines.joined(separator: "\n"), allowNewlines: true)).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let d = step.detail {
                Text(verbatim: DisplayText.clean(d, allowNewlines: true)).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color(white: 0.85)).lineLimit(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(verbatim: "No details").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.terminal))
    }
    static func tail(_ output: String?) -> [String] {
        var lines = (output ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last == "" { lines.removeLast() }
        return Array(lines.suffix(20))
    }
}
