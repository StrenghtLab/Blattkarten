import AppKit
import SwiftUI

@MainActor
final class FlameDesktop: ObservableObject {
    @Published private(set) var pet = StreakPet()
    @Published private(set) var now = Date.now
    private var panel: NSPanel?

    func update(pet: StreakPet, visible: Bool, close: @escaping () -> Void) {
        self.pet = pet
        now = .now
        guard visible else {
            panel?.orderOut(nil)
            panel = nil
            return
        }
        guard panel == nil else { return }

        let size = CGSize(width: 158, height: 174)
        let window = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.contentView = NSHostingView(rootView: FlameDesktopCard(state: self, close: close))
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            window.setFrameOrigin(CGPoint(x: frame.maxX - size.width - 26, y: frame.minY + 26))
        }
        panel = window
        window.orderFrontRegardless()
    }

    func refreshTime(_ time: Date) {
        if panel != nil { now = time }
    }
}

private struct FlameDesktopCard: View {
    @ObservedObject var state: FlameDesktop
    let close: () -> Void

    var body: some View {
        let streak = state.pet.streak(at: state.now)
        VStack(spacing: 3) {
            FlamePet(outfit: Outfit(state.pet.outfit)).frame(width: 99, height: 99)
            Text("\(streak) \(streak == 1 ? "Lerntag" : "Lerntage")").font(.headline.bold())
            Text("\(state.pet.unlocked) von 365 Outfits").font(.caption2).opacity(0.82)
        }
        .foregroundStyle(.white)
        .frame(width: 158, height: 174)
        .background {
            RoundedRectangle(cornerRadius: 23)
                .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.21, blue: 0.49), ink],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.63))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Schreibtisch-Flamme ausblenden")
            .padding(10)
        }
    }
}
