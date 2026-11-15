import AppKit
import SwiftUI
import HuddleCore

// Composites for the demo video and a few stills. They are drawn by the demo, not by the app: the menu-bar strip, the hover
// tooltip callout and the stage around the real panel. Nothing here ships in the app's own UI.

/// The menu-bar item: the buddy (template image, animated like StatusItemController does) and the count of working threads.
struct MenuBarGlyph: View {
    var count: Int
    var frame: Int
    var size: CGFloat = 18
    var body: some View {
        let icon = count > 0 ? StatusItemController.menuBarIcon(size: size, frame: frame % 4) : StatusItemController.menuBarIcon(size: size)
        HStack(spacing: 4) {
            Image(nsImage: icon).renderingMode(.template).foregroundColor(.white)
            if count > 0 { Text(verbatim: "\(count)").font(.system(size: size * 0.67, weight: .semibold).monospacedDigit()).foregroundStyle(.white) }
        }
    }
}

struct MenuBarStrip: View {
    var count: Int
    var frame: Int
    var body: some View {
        HStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
            Image(systemName: "wifi")
            Image(systemName: "battery.100")
            MenuBarGlyph(count: count, frame: frame)
            Text(verbatim: "Fri 9:41")
        }
        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 18).frame(height: 30)
        .background(Color(white: 0.16))
    }
}

/// A macOS-style tooltip, drawn as a callout because a hover cannot be captured offscreen.
struct TooltipCallout: View {
    var lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines.indices, id: \.self) { i in
                Text(verbatim: lines[i]).font(.system(size: 13, weight: i == 0 ? .semibold : .regular)).foregroundStyle(.white.opacity(i == 0 ? 1 : 0.7))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.22)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
    }
}

/// Sessions on assorted models, built through the same reducer the app uses, so the icons are the app's own ModelIcon.
@MainActor
enum DemoModels {
    static let samples: [(provider: String, model: String, executed: String?)] = [
        ("claudeAgent", "claude-opus-5-5", "claude-sonnet-5-5"), ("codex", "gpt-6.1-sol", nil), ("pi", "ollama/qwen3.8-pi:latest", nil),
        ("grok", "grok-code-fast-1", nil), ("gemini", "gemini-3-pro", nil),
    ]
    static func sessions() -> [Session] {
        var st = HuddleState()
        st.applyActive(samples.enumerated().map { i, s in
            ThreadSummary(threadId: "sample\(i)", status: .running, providerInstanceId: s.provider, model: s.model)
        })
        return samples.indices.compactMap { st.sessions["sample\($0)"] }
    }
}

/// "Model icons" legend with the tooltip a hover shows, as a callout.
struct ModelIconLegend: View {
    var body: some View {
        let sessions = DemoModels.sessions()
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sessions.indices, id: \.self) { i in
                HStack(spacing: 14) {
                    ModelIcon(session: sessions[i], size: 30)
                    TooltipCallout(lines: ModelInfo.hover(provider: DemoModels.samples[i].provider, model: DemoModels.samples[i].model,
                                                          executedModel: DemoModels.samples[i].executed).components(separatedBy: "\n"))
                }
            }
            Text(verbatim: "Hover an icon in the panel for this text. Drawn here as a callout.").font(.system(size: 12)).foregroundStyle(Theme.grey)
        }
        .padding(18).background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// What sits beside the panel while the video explains a feature.
enum DemoInset {
    case none
    case modelIcons
    case approvals(ApprovalsSnapshotData)
    case about(NSImage?, NSImage?)
}

struct DemoFrameView: View {
    static let size = CGSize(width: 1040, height: 800)
    var panel: NSImage?
    var model: HuddleModel
    var caption: String
    var sub: String
    var inset: DemoInset
    var count: Int
    var frame: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.04), Color(red: 0.07, green: 0.08, blue: 0.03)], startPoint: .top, endPoint: .bottom)
            MenuBarStrip(count: count, frame: frame).frame(width: Self.size.width).frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: caption).font(.system(size: 31, weight: .bold, design: .serif)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if !sub.isEmpty {
                    Text(verbatim: sub).font(.system(size: 17)).foregroundStyle(Color(white: 0.7)).fixedSize(horizontal: false, vertical: true)
                }
                insetView.padding(.top, 20)
                Spacer(minLength: 0)
            }
            .frame(width: 540, alignment: .leading).padding(.leading, 28).padding(.top, 66)
            if let panel {
                Image(nsImage: panel).padding(.leading, Self.size.width - 400 - 36).padding(.top, 42)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder private var insetView: some View {
        switch inset {
        case .none: EmptyView()
        case .modelIcons: ModelIconLegend()
        case .approvals(let data):
            ApprovalsView(model: model, snapshot: data).environment(\.snapshotMode, true)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1), lineWidth: 1))
        case .about(let about, let icon):
            HStack(alignment: .top, spacing: 20) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 128, height: 128) }
                if let about { Image(nsImage: about).resizable().scaledToFit().frame(maxWidth: 380) }
            }
        }
    }
}

/// The panel alone on the usual dark ground, as a still taken from the live NSPanel (resize and scrolling need the real thing).
struct PanelStill: View {
    var panel: NSImage
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.04), Color(red: 0.07, green: 0.08, blue: 0.03)], startPoint: .top, endPoint: .bottom)
            Image(nsImage: panel).padding(28)
        }.fixedSize()
    }
}
