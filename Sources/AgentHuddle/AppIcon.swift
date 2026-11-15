import SwiftUI
import AppKit

/// App icon: a dark rounded tile with the four "buddies" huddled together and a lime status dot.
/// Rendered by `AgentHuddle --icon FILE.png` (1024×1024); `scripts/build-app.sh` turns it into AppIcon.icns.
struct AppIconView: View {
    var body: some View {
        ZStack {
            Color.clear
            ZStack {
                RoundedRectangle(cornerRadius: 186, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.16), Color(red: 0.06, green: 0.065, blue: 0.075)],
                                         startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 186, style: .continuous)
                    .stroke(Theme.lime.opacity(0.9), lineWidth: 14).padding(7)
                BuddyView(index: 0, size: 560).offset(y: 20)
                Circle().fill(Theme.lime).frame(width: 64, height: 64).offset(x: -280, y: -290)
            }
            .frame(width: 824, height: 824)
        }
        .frame(width: 1024, height: 1024)
    }
}

enum AppIcon {
    @MainActor static func writePNG(to url: URL) {
        let r = ImageRenderer(content: AppIconView()); r.scale = 1
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("icon render failed\n".utf8)); exit(1)
        }
        try? png.write(to: url)
    }
}
