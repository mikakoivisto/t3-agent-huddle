import AppKit
import SwiftUI
import Combine
import HuddleCore

/// Floating, non-activating, all-Spaces panel in the top-right corner (SPEC §9.1).
final class HuddlePanel: NSPanel {
    override var canBecomeKey: Bool { true }     // needed for the token paste field only
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: HuddlePanel
    private let model: HuddleModel
    private let hosting: NSHostingView<HuddleRootView>
    private var bag = Set<AnyCancellable>()
    private var resizing = false
    private var userResizing = false
    /// Smallest the user can drag the panel to, and the width is fixed.
    private static let minHeight: CGFloat = 140
    private static let defaultMaxHeight: CGFloat = 640
    private var maxHeight: CGFloat = PanelController.defaultMaxHeight

    init(model: HuddleModel) {
        self.model = model
        hosting = NSHostingView(rootView: HuddleRootView(model: model))
        panel = HuddlePanel(contentRect: NSRect(x: 0, y: 0, width: Theme.width, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
                            backing: .buffered, defer: false)
        super.init()
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.minSize = NSSize(width: Theme.width, height: Self.minHeight)
        panel.maxSize = NSSize(width: Theme.width, height: 10_000)
        maxHeight = model.savedPanelMaxHeight.map { CGFloat($0) } ?? Self.defaultMaxHeight
        position()
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.fit(); self?.syncVisibility() }
        }.store(in: &bag)
    }

    func show() { fit(); panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    var isVisible: Bool { panel.isVisible }

    private func syncVisibility() {
        if model.widgetHidden, panel.isVisible { hide() }
        else if !model.widgetHidden, !panel.isVisible { show() }
    }

    private func position() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        if let saved = model.savedPanelOrigin, screen.frame.contains(CGPoint(x: saved.x, y: saved.y - 10)) {
            panel.setFrameTopLeftPoint(NSPoint(x: saved.x, y: saved.y))
        } else {
            let vf = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: vf.maxX - Theme.width - 16, y: vf.maxY - 8))
        }
    }

    /// Resize to the content, keeping the top edge fixed.
    func fit() {
        guard !resizing, !userResizing else { return }
        resizing = true; defer { resizing = false }
        let size = hosting.fittingSize
        guard size.height > 10 else { return }
        var f = panel.frame
        let top = f.maxY
        let screenCap = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = max(Self.minHeight, min(size.height, maxHeight, screenCap - 16)).rounded()
        f.size = NSSize(width: Theme.width, height: min(height, size.height))
        f.origin.y = top - f.size.height
        if f != panel.frame { panel.setFrame(f, display: true) }
    }

    /// Dragging the bottom (or top) edge sets the tallest the panel may be; it still shrinks to fit less content.
    func windowWillStartLiveResize(_ notification: Notification) { userResizing = true }
    func windowDidEndLiveResize(_ notification: Notification) {
        userResizing = false
        maxHeight = panel.frame.height
        model.savePanelMaxHeight(Double(panel.frame.height))
        fit()
    }

    // Demo recorder only: what dragging the bottom edge does, in steps it can capture. Same delegate methods the window calls.
    func beginDemoResize() { windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification)) }
    func demoResize(toHeight h: CGFloat) {
        var f = panel.frame
        let top = f.maxY
        f.size.height = h; f.origin.y = top - h
        panel.setFrame(f, display: true)
    }
    func endDemoResize() { windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification)) }
    /// The tallest the panel grows before it scrolls (what a drag sets; the demo starts tall enough for its story).
    func setMaxHeight(_ h: CGFloat) { maxHeight = h; fit() }

    func windowDidMove(_ notification: Notification) {
        model.savePanelOrigin(x: panel.frame.minX, y: panel.frame.maxY)
    }
}
