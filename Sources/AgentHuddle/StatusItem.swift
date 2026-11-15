import AppKit
import Combine
import HuddleCore

/// Minimal menu-bar item (SPEC Q11 proposed default): show/hide and quit. This is also how the widget
/// comes back after its × (Q8 default).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: HuddleModel
    private var cancellable: AnyCancellable?
    private var timer: Timer?
    private var frame = 0
    private var activeCount = 0
    private var attentionCount = 0
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
        // Spec 14: every setting lives in the Settings window; the menu keeps Show / Hide, Settings…, About and Quit.
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(toggle); menu.addItem(.separator()); menu.addItem(settings)
        let about = NSMenuItem(title: "About Agent Huddle", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(.separator()); menu.addItem(about); menu.addItem(quit)
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeft
        cancellable = model.$state.sink { [weak self] state in
            let n = state.visible.filter { $0.isWorking }.count
            let a = state.visible.filter(\.needsAttention).count
            MainActor.assumeIsolated { self?.setActive(n, attention: a) }
        }
    }
    /// Animates the buddy while threads are running. The number is the working count, or, while something needs the user,
    /// the attention count in an orange badge (spec 14). A still icon with no number when nothing is running or waiting.
    private func setActive(_ n: Int, attention: Int) {
        guard n != activeCount || attention != attentionCount else { return }
        let animationChanged = (n > 0) != (activeCount > 0)
        activeCount = n; attentionCount = attention
        if attention > 0 {
            let a = NSTextAttachment(); a.image = Self.badge(attention)
            let t = NSMutableAttributedString(string: " ")
            t.append(NSAttributedString(attachment: a))
            item.button?.attributedTitle = t
        } else {
            item.button?.attributedTitle = NSAttributedString(string: n > 0 ? " \(n)" : "", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
        }
        // From the numbers passed in: `$state` publishes before the model's own properties change.
        item.button?.toolTip = HuddleModel.tooltip(attention: attention, working: n)
        item.length = (n > 0 || attention > 0) ? NSStatusItem.variableLength : NSStatusItem.squareLength
        guard animationChanged || timer == nil else { return }
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
    @objc private func showAbout() { About.show() }
    @objc private func showSettings() { SettingsWindowController.shared.show(model: model) }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension StatusItemController {
    func menuNeedsUpdate(_ menu: NSMenu) {}

    /// The orange attention badge: a capsule with the count, drawn in colour (the robot beside it stays a template image).
    static func badge(_ n: Int, height: CGFloat = 15) -> NSImage {
        let text = n > 99 ? "99+" : "\(n)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: height * 0.72, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let size = (text as NSString).size(withAttributes: attrs)
        let w = max(height, size.width + height * 0.7)
        let image = NSImage(size: NSSize(width: w, height: height), flipped: false) { r in
            NSColor(red: 1.0, green: 0.54, blue: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: height / 2, yRadius: height / 2).fill()
            (text as NSString).draw(at: NSPoint(x: (w - size.width) / 2, y: (height - size.height) / 2), withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "\(n) need you"
        return image
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
