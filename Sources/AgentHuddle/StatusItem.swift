import AppKit
import Combine
import HuddleCore

/// Minimal menu-bar item (SPEC Q11 proposed default): show/hide and quit. This is also how the widget
/// comes back after its × (Q8 default).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var roItem: NSMenuItem?
    private var settleItem: NSMenuItem?
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: HuddleModel
    private var cancellable: AnyCancellable?
    private var timer: Timer?
    private var frame = 0
    private var activeCount = 0
    private let frames = (0..<4).map { StatusItemController.menuBarIcon(frame: $0) }
    private let idleIcon = StatusItemController.menuBarIcon()
    init(model: HuddleModel) {
        self.model = model
        super.init()
        item.button?.image = StatusItemController.menuBarIcon()
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show / Hide Agent Huddle", action: #selector(toggle), keyEquivalent: "")
        toggle.target = self
        let quit = NSMenuItem(title: "Quit Agent Huddle", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        let ro = NSMenuItem(title: "Read-only mode (no answering)", action: #selector(toggleReadOnly), keyEquivalent: "")
        ro.target = self; roItem = ro
        let settle = NSMenuItem(title: "Close also settles finished threads in T3", action: #selector(toggleSettle), keyEquivalent: "")
        settle.target = self; settleItem = settle
        menu.addItem(toggle); menu.addItem(.separator()); menu.addItem(ro); menu.addItem(settle)
        let approvals = NSMenuItem(title: "Inline approvals…", action: #selector(showApprovals), keyEquivalent: "")
        approvals.target = self
        menu.addItem(approvals)
        let about = NSMenuItem(title: "About Agent Huddle", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(.separator()); menu.addItem(about); menu.addItem(quit)
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeft
        cancellable = model.$state.sink { [weak self] state in
            let n = state.visible.filter { $0.isWorking }.count
            MainActor.assumeIsolated { self?.setActive(n) }
        }
    }
    /// Animates the buddy and shows the count while threads are running; a still icon with no number when none are.
    private func setActive(_ n: Int) {
        guard n != activeCount else { return }
        activeCount = n
        let title = n > 0 ? " \(n)" : ""
        item.button?.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
        item.button?.toolTip = n > 0 ? "\(n) running" : "Agent Huddle"
        item.length = n > 0 ? NSStatusItem.variableLength : NSStatusItem.squareLength
        timer?.invalidate(); timer = nil
        guard n > 0 else { item.button?.image = idleIcon; return }
        item.button?.image = frames[frame % frames.count]
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frame += 1
                self.item.button?.image = self.frames[self.frame % self.frames.count]
            }
        }
    }
    @objc private func toggle() { model.widgetHidden ? model.showWidget() : model.hideWidget() }
    @objc private func toggleReadOnly() { model.setReadOnly(!model.readOnly) }
    @objc private func toggleSettle() { model.setCloseSettles(!model.closeSettles) }
    @objc private func showApprovals() { ApprovalsWindowController.shared.show(model: model) }
    @objc private func showAbout() { About.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension StatusItemController {
    func menuNeedsUpdate(_ menu: NSMenu) {
        roItem?.state = model.readOnly ? .on : .off
        settleItem?.state = model.closeSettles ? .on : .off
    }
}

extension StatusItemController {
    /// Menu-bar glyph: one buddy (rounded square with two eyes and a mouth cut out, plus two feet) as a template image,
    /// so macOS tints it for light, dark and highlighted states.
    static func menuBarIcon(size: CGFloat = 18, frame: Int? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Animation frames 0...3: the buddy hops (body up on odd frames), its feet alternate and its eyes look side to side.
            let hop = frame.map { $0 % 2 == 1 ? 0.06 : 0.0 } ?? 0.0
            let look = frame.map { [0.0, 0.04, 0.0, -0.04][$0 % 4] } ?? 0.0
            let body = NSRect(x: rect.width * 0.12, y: rect.height * (0.22 + hop), width: rect.width * 0.76, height: rect.height * 0.70)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: body, xRadius: body.width * 0.24, yRadius: body.width * 0.24).fill()
            let footTop = rect.height * (0.24 + hop)
            for (i, x) in [0.28, 0.58].enumerated() {   // feet
                let lifted = frame.map { ($0 % 2 == 0) == (i == 1) } ?? false
                let bottom = rect.height * (lifted ? 0.12 : 0.04)
                NSBezierPath(roundedRect: NSRect(x: rect.width * x, y: bottom, width: rect.width * 0.14, height: footTop - bottom),
                             xRadius: 1, yRadius: 1).fill()
            }
            NSGraphicsContext.current?.compositingOperation = .destinationOut   // eyes + mouth cut out
            let eyeW = body.width * 0.13, eyeH = body.height * 0.24
            for dx in [-0.2, 0.2] {
                NSBezierPath(rect: NSRect(x: body.midX + body.width * (dx + look) - eyeW / 2, y: body.midY + body.height * 0.02, width: eyeW, height: eyeH)).fill()
            }
            NSBezierPath(rect: NSRect(x: body.midX - body.width * 0.14, y: body.midY - body.height * 0.22, width: body.width * 0.28, height: body.height * 0.08)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Agent Huddle"
        return image
    }
}
