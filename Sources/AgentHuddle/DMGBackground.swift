import SwiftUI
import AppKit

/// The DMG window's background: the wordmark, a lime arrow from the app to Applications, and a few buddies peeking in.
/// Rendered by `AgentHuddle --dmg-background DIR` at 1x and 2x; `scripts/make-dmg.sh` lays the window out to match.
/// Finder draws the icon labels itself, black in light mode and white in dark mode, and a DMG cannot set their colour,
/// so each label sits on a mid-grey plate that keeps both readable (about 4.5:1 either way).
struct DMGBackgroundView: View {
    /// Window content size and icon centres; `make-dmg.sh` uses the same numbers.
    static let size = CGSize(width: 660, height: 400)
    static let appCentre = CGPoint(x: 170, y: 220)
    static let applicationsCentre = CGPoint(x: 490, y: 220)
    static let iconSize: CGFloat = 128
    /// Where Finder puts the label's centre, below the icon centre (128 px icons, 13 pt text); checked on a mounted DMG.
    static let labelDrop: CGFloat = 80
    /// Wide enough for "Agent Huddle.app", for Finder set to show every extension.
    static let plateSize = CGSize(width: 124, height: 22)

    var version: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.106, green: 0.110, blue: 0.122), Color(red: 0.071, green: 0.075, blue: 0.082)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.lime.opacity(0.16), .clear], center: UnitPoint(x: 0.15, y: 1.2),
                           startRadius: 0, endRadius: 520)

            HStack(spacing: 12) {
                Circle().fill(Theme.lime).frame(width: 12, height: 12).shadow(color: Theme.lime.opacity(0.6), radius: 6)
                Text(verbatim: "Agent Huddle").font(.system(size: 36, weight: .semibold, design: .serif)).foregroundStyle(.white)
            }
            .offset(x: 40, y: 30)
            RoundedRectangle(cornerRadius: 2).fill(Theme.lime).frame(width: 56, height: 4).offset(x: 64, y: 84)
            Text(verbatim: "Drag the app onto Applications to install.").font(.system(size: 14)).foregroundStyle(Color(white: 0.62))
                .offset(x: 64, y: 98)
            if let version {
                Text(verbatim: "v\(version)").font(.system(size: 11)).tracking(0.5).foregroundStyle(Color(white: 0.42))
                    .frame(width: Self.size.width - 20, alignment: .trailing).offset(y: 22)
            }

            Arrow().stroke(Theme.lime, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [2, 9]))
            ArrowHead().stroke(Theme.lime, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))

            ForEach([Self.appCentre, Self.applicationsCentre], id: \.x) { c in
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(red: 0.463, green: 0.478, blue: 0.439))
                    .frame(width: Self.plateSize.width, height: Self.plateSize.height)
                    .offset(x: c.x - Self.plateSize.width / 2, y: c.y + Self.labelDrop - Self.plateSize.height / 2)
            }

            HStack(alignment: .bottom, spacing: 8) {
                BuddyView(index: 1, size: 38)
                BuddyView(index: 2, size: 48)
                BuddyView(index: 3, size: 34)
                BuddyView(index: 4, size: 42)
            }
            // Standing clear of the bottom 34 pt: Finder's path bar (a global Finder setting) covers about 28.
            .frame(width: Self.size.width - 28, height: Self.size.height - 34, alignment: .bottomTrailing)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
    }

    /// From just right of the app icon, arching up, to just left of Applications.
    private struct Arrow: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 260, y: 228))
            p.addQuadCurve(to: CGPoint(x: 390, y: 220), control: CGPoint(x: 330, y: 178))
            return p
        }
    }
    private struct ArrowHead: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 378, y: 208)); p.addLine(to: CGPoint(x: 394, y: 223)); p.addLine(to: CGPoint(x: 374, y: 228))
            return p
        }
    }
}

enum DMGBackground {
    /// Writes `background.png` (660×400) and `background@2x.png` into `dir`. The version comes from the bundle, so a
    /// release build shows its own; a bare binary (no bundle version) shows none.
    @MainActor static func write(to dir: URL) {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = (v?.isEmpty == false && v != "0.0.0") ? v : nil
        for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
            let r = ImageRenderer(content: DMGBackgroundView(version: version).environment(\.colorScheme, .dark))
            r.scale = scale
            guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("dmg background render failed\n".utf8)); exit(1)
            }
            do { try png.write(to: dir.appendingPathComponent(name)) } catch {
                FileHandle.standardError.write(Data("dmg background write failed\n".utf8)); exit(1)
            }
        }
    }
}
