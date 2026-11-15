import SwiftUI
import AppKit
import Combine
import HuddleCore

// Settings (spec 14): one window for every setting. General (attention, answering, window) and Machines (spec 15).
// It floats above other apps while open unless "Keep this window on top" is off.

enum SettingsTab: String, CaseIterable { case general, machines }

@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private let selection = SettingsSelection()
    private let flow = AddMachineFlow()
    private var setup: ApprovalSetup?
    private var bag = Set<AnyCancellable>()

    func show(model: HuddleModel, tab: SettingsTab? = nil, adding address: String? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Agent Huddle Settings"
            w.isReleasedWhenClosed = false
            let s = ApprovalSetup(model: model); setup = s
            w.contentView = NSHostingView(rootView: SettingsView(model: model, selection: selection, flow: flow, setup: s))
            w.contentMinSize = NSSize(width: 540, height: 380)
            w.contentMaxSize = NSSize(width: 540, height: 4000)
            w.backgroundColor = NSColor(Theme.panel)
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.center()
            window = w
            model.$settingsOnTop.sink { [weak w] onTop in w?.level = onTop ? .floating : .normal }.store(in: &bag)
        }
        if let tab { selection.tab = tab }
        if let address { selection.tab = .machines; flow.start(address: address) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: HuddleModel
    @ObservedObject var selection: SettingsSelection
    @ObservedObject var flow: AddMachineFlow
    @ObservedObject var setup: ApprovalSetup

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tabButton(.general, "gearshape", "General")
                tabButton(.machines, "desktopcomputer", "Machines")
            }
            .padding(.vertical, 8).frame(maxWidth: .infinity)
            .background(Color(white: 0.16))
            .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1), alignment: .bottom)
            switch selection.tab {
            case .general: GeneralSettingsView(model: model)
            case .machines: MachinesView(model: model, flow: flow, setup: setup)
            }
        }
        .frame(width: 540).background(Theme.panel).preferredColorScheme(.dark)
    }

    private func tabButton(_ tab: SettingsTab, _ icon: String, _ title: String) -> some View {
        let on = selection.tab == tab
        return Button { selection.tab = tab } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 16))
                Text(verbatim: title).font(.system(size: 11))
            }
            .foregroundStyle(on ? .white : Theme.grey)
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.white.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var model: HuddleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            section("ATTENTION")
            group {
                SettingRow(title: "Show the panel when something needs me",
                           detail: "Brings a hidden panel back for a new question, permission or secret request. Never takes focus.",
                           on: model.showPanelOnAttention) { model.setShowPanelOnAttention($0) }
                divider
                SettingRow(title: "Chime when something needs me", detail: "Once per new request. The panel’s speaker button changes the same setting.",
                           on: !model.muted) { model.setChime($0) }
            }
            section("ANSWERING")
            group {
                SettingRow(title: "Read-only mode", detail: "No answers, messages, Allow / Deny or settle from the panel.",
                           on: model.readOnly) { model.setReadOnly($0) }
                divider
                SettingRow(title: "Close also settles finished threads in T3", detail: "× on a finished thread settles it in T3 Code too.",
                           on: model.closeSettles) { model.setCloseSettles($0) }
            }
            section("WINDOW")
            group {
                SettingRow(title: "Keep this window on top", detail: "Settings float above other apps while open.",
                           on: model.settingsOnTop) { model.setSettingsOnTop($0) }
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    private func section(_ t: String) -> some View {
        Text(verbatim: t).font(.system(size: 10.5, weight: .heavy)).foregroundStyle(Theme.grey).padding(.top, 8).padding(.leading, 2)
    }
    private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 0) { c() }.background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }
}

struct SettingRow: View {
    var title: String
    var detail: String
    var on: Bool
    var set: (Bool) -> Void
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 13)).foregroundStyle(.white)
                Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            SwitchView(on: on) { set(!on) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// A drawn switch, so `--snapshot` can render it (ImageRenderer cannot draw an NSSwitch).
struct SwitchView: View {
    var on: Bool
    var toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            Capsule().fill(on ? Theme.lime : Color.white.opacity(0.25)).frame(width: 32, height: 18)
                .overlay(Circle().fill(on ? Color.black : Color.white).frame(width: 14, height: 14).padding(2),
                         alignment: on ? .trailing : .leading)
                .animation(.easeOut(duration: 0.12), value: on)
        }.buttonStyle(.plain).accessibilityAddTraits(.isButton).accessibilityValue(on ? "on" : "off")
    }
}
