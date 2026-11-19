import SwiftUI
import Combine

final class QuotaAppDelegate: NSObject, NSApplicationDelegate {
    private var desktopWindow: NSPanel?
    private var feeController: AnyCancellable?

    func attach(model: Model) {
        let prefs = UserDefaults.standard
        prefs.register(defaults: ["showDesktopFee": true])
        let apply = { [weak self] in self?.setCard(prefs.bool(forKey: "showDesktopFee"), model: model) }
        apply()
        feeController = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { _ in apply() }
    }
    private func setCard(_ show: Bool, model: Model) {
        guard show else {
            desktopWindow?.orderOut(nil)
            return
        }
        if let desktopWindow {
            if !desktopWindow.isVisible { desktopWindow.orderFrontRegardless() }
            return
        }
        let rect = NSRect(x: 0, y: 0, width: 218, height: 116)
        let window = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.title = "桌面实时金额卡"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: DesktopFeeCard(model: model))
        if let area = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: area.minX + 20, y: area.minY + 22))
        }
        window.setFrameAutosaveName("QuotaDesktopFee")
        desktopWindow = window
        window.orderFrontRegardless()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuControls: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if let p = model.snapshot?.week?.progress(at: model.now) {
            Text("已用 " + pct(p.used) + "   ·   应已用 " + pct(p.elapsed))
        }
        Button("打开额度面板") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "quota")
        }
        Button("立即刷新") { model.refresh() }.disabled(model.fetching)
        Divider()
        Button("退出额度时钟") { NSApp.terminate(nil) }
    }
}

@main
struct QuotaClock: App {
    @NSApplicationDelegateAdaptor(QuotaAppDelegate.self) private var delegate
    @AppStorage("showMenuBarQuota") private var showMenuBarQuota = true
    @AppStorage("showDesktopFee") private var showDesktopFee = true
    @StateObject private var model: Model
    init() {
        signal(SIGPIPE, SIG_IGN)
        let source = Model()
        _model = StateObject(wrappedValue: source)
        source.start()
    }
    var body: some Scene {
        Window("Codex 额度时钟", id: "quota") {
            Panel(model: model, showMenuBarQuota: $showMenuBarQuota, showDesktopFee: $showDesktopFee)
                .onAppear { delegate.attach(model: model) }
        }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
        MenuBarExtra(isInserted: $showMenuBarQuota) {
            MenuControls(model: model)
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
            if let p = model.snapshot?.week?.progress(at: model.now) {
                Text("余 " + pct(1 - p.used) + (model.problem == nil ? "" : " ·"))
            } else { Text("额度") }
        }
    }
}
