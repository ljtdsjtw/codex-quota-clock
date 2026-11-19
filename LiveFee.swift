import SwiftUI

// Only schedule second ticks while the owning window can be seen.
private struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    final class Probe: NSView {
        var update: (Bool) -> Void = { _ in }
        private var observer: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window, queue: .main
                ) { [weak self] _ in self?.publish() }
            }
            publish()
        }
        func publish() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                update(window?.occlusionState.contains(.visible) == true)
            }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.update = { visible = $0 }
        return probe
    }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

struct LiveFee: View {
    let clock: FeeClock
    let onAC: Bool
    let now: Date
    let size: CGFloat
    var rounded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var firstTick = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    var body: some View {
        Group {
            if onAC && visible && !reduceMotion {
                TimelineView(.periodic(from: firstTick, by: 1)) { tick in
                    ImpactAmount(previous: clock.digits(at: tick.date.addingTimeInterval(-1)),
                                 amount: clock.digits(at: tick.date), tickSecond: Int(tick.date.timeIntervalSince1970),
                                 size: size, rounded: rounded)
                }
            } else {
                Text(Cost.cny(clock.value(at: now)))
                    .font(.system(size: size, weight: .semibold, design: rounded ? .rounded : .default))
                    .padding(.top, size * 0.27).padding(.bottom, size * 0.07)
            }
        }.monospacedDigit().background(WindowVisibility(visible: $visible))
    }
}

struct DesktopFeeCard: View {
    @ObservedObject var model: Model
    @AppStorage("monthlyCNY") private var monthly = Cost.defaultMonthly

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Codex · 本周时间分摊")
                Spacer()
                Image(systemName: model.onAC ? "powerplug.fill" : "battery.75percent")
            }.font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.79))
            if let week = model.snapshot?.week,
               let pace = week.progress(at: model.now), let clock = week.feeClock(monthly: monthly) {
                LiveFee(clock: clock, onAC: model.onAC, now: model.now, size: 30, rounded: true)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 216/255, green: 1, blue: 228/255))
                Text("额度已用 " + pct(pace.used) + " · " + Cost.cny(clock.total * pace.used) +
                     (model.stale ? " · 待更新" : ""))
                    .font(.caption).foregroundStyle(.white)
            } else {
                Text("等待周额度").foregroundStyle(.white)
            }
        }.padding(15).frame(width: 218, height: 116)
            .background(Color(red: 0.055, green: 0.18, blue: 0.18), in: RoundedRectangle(cornerRadius: 18))
    }
}
