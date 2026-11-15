// Renders demo/social-preview.png (1280×640, GitHub's repository social preview) from two demo stills.
// Usage: swift scripts/make-social-preview.swift demo/stills/29-app-icon.png demo/stills/01-list-two-machines.png demo/social-preview.png
// Everything that matters stays inside GitHub's 40 px safe border; only the panel's lower part bleeds off the bottom.
import AppKit
let args = CommandLine.arguments
let icon = NSImage(contentsOfFile: args[1])!, hero = NSImage(contentsOfFile: args[2])!, out = args[3]
let W: CGFloat = 1280, H: CGFloat = 640, safe: CGFloat = 40
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// Flipped drawing: y from the top.
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
NSGradient(colors: [NSColor(white: 0.04, alpha: 1), NSColor(red: 0.07, green: 0.08, blue: 0.03, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
let lime = NSColor(red: 0.80, green: 0.94, blue: 0.25, alpha: 1)
// Right: the panel, top part inside the safe area, bleeding off the bottom edge.
let pw: CGFloat = 430, ph = hero.size.height * pw / hero.size.width
let pr = NSRect(x: W - safe - 40 - pw, y: safe + 28, width: pw, height: ph)
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.6); sh.shadowBlurRadius = 30; sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
NSColor.black.setFill(); NSBezierPath(roundedRect: pr.insetBy(dx: 14, dy: 14), xRadius: 24, yRadius: 24).fill()
NSGraphicsContext.restoreGraphicsState()
hero.draw(in: pr, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
// Left: icon, name, bar, tagline, features.
let x = safe + 50
icon.draw(in: NSRect(x: x, y: 108, width: 116, height: 116), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
func text(_ s: String, _ font: NSFont, _ color: NSColor, _ y: CGFloat, width: CGFloat = 600) {
    let p = NSMutableParagraphStyle(); p.lineSpacing = 4
    (s as NSString).draw(with: NSRect(x: x, y: y, width: width, height: 200), options: [.usesLineFragmentOrigin],
                         attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
}
let serif = NSFont(descriptor: NSFont.systemFont(ofSize: 76, weight: .bold).fontDescriptor.withDesign(.serif)!, size: 76)!
text("Agent Huddle", serif, .white, 238)
NSColor(red: 0.80, green: 0.94, blue: 0.25, alpha: 1).setFill(); NSRect(x: x, y: 348, width: 92, height: 5).fill()
text("Every running T3 Code thread, on every machine, in one floating panel.", .systemFont(ofSize: 27, weight: .regular), NSColor(white: 0.78, alpha: 1), 378, width: 560)
text("Answer questions  ·  Allow or Deny  ·  Message  ·  Start threads", .systemFont(ofSize: 18, weight: .medium), lime, 486, width: 600)
text("Native macOS  ·  Open source (MIT)", .systemFont(ofSize: 17), NSColor(white: 0.5, alpha: 1), 520, width: 600)
NSGraphicsContext.current?.flushGraphics()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
