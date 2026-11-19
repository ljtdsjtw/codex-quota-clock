import SwiftUI
import CryptoKit

struct Observation: Codable {
    let date: Date
    let fraction: Double
}

struct WeekHistory: Codable {
    var reset: Double?
    var owner: String?
    var points = [Observation]()

    static func load() -> Self {
        guard let url = try? WidgetData.sharedFile("history.json"),
              let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return history
    }

    // A cumulative meter brackets usage at the cutoff between the adjacent readings.
    func recentUsage(through end: Date, week: QuotaWindow) -> String? {
        guard reset == week.resetsAt, let latest = points.last, latest.date == end else { return nil }
        let cutoff = end.addingTimeInterval(-5 * 3600)
        guard let after = points.first(where: { $0.date >= cutoff }) else { return nil }
        let before = points.last(where: { $0.date <= cutoff })
        let lower = latest.fraction - after.fraction
        let upper = latest.fraction - (before?.fraction ?? 0)
        guard lower >= 0, upper >= lower else { return "采样读数有变，等待同步" }
        let crossedReset = (reset ?? 0) - 7 * 86400 > cutoff.timeIntervalSince1970
        if crossedReset { return "本周期已用 " + pct(latest.fraction) + " · 跨周" }
        if abs(upper - lower) < 0.00001 { return "约 " + pct(lower) + " 周额度" }
        if before == nil { return "已观测 " + pct(lower) + " 周额度（" + durationText(end.timeIntervalSince(after.date)) + "）" }
        return pct(lower) + "–" + pct(upper) + " 周额度"
    }

    mutating func record(week: QuotaWindow, account: String?, at date: Date) throws {
        guard let end = week.resetsAt, let pace = week.progress(at: date) else { return }
        let key = account.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        if reset != end || owner != key || (points.last.map { $0.fraction > pace.used || $0.date > date } ?? false) {
            reset = end
            owner = key
            points.removeAll()
        }
        let point = Observation(date: date, fraction: pace.used)
        if let last = points.last, date.timeIntervalSince(last.date) < 60 {
            points[points.count - 1] = point
        } else { points.append(point) }
        try JSONEncoder().encode(self).write(to: WidgetData.sharedFile("history.json"), options: .atomic)
    }
}

struct UsageChart: View {
    let points: [Observation]
    let clock: FeeClock
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("本周用量").font(.headline)
                Spacer()
                Text("实线  实际已用　／　虚线  均匀进度").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                VStack(alignment: .trailing) { Text("100%"); Spacer(); Text("0%") }
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Canvas { ctx, size in
                    let area = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
                    func xy(_ x: Double, _ y: Double) -> CGPoint {
                        CGPoint(x: area.minX + x * area.width, y: area.maxY - y * area.height)
                    }
                    for y in [0.0, 0.5, 1] {
                        var grid = Path(); grid.move(to: xy(0,y)); grid.addLine(to: xy(1,y))
                        ctx.stroke(grid, with: .color(.gray.opacity(0.2)), lineWidth: 0.7)
                    }
                    var guide = Path(); guide.move(to: xy(0,0)); guide.addLine(to: xy(1,1))
                    ctx.stroke(guide, with: .color(.brown), style: StrokeStyle(lineWidth: 1.4, dash: [4,4]))
                    var path = Path(), previous: Date?
                    for point in points {
                        let x = point.date.timeIntervalSince(clock.start) / clock.end.timeIntervalSince(clock.start)
                        guard (0...1).contains(x) else { continue }
                        let pos = xy(x, point.fraction)
                        if let previous, point.date.timeIntervalSince(previous) <= 900 {
                            path.addLine(to: pos)
                        } else { path.move(to: pos) }
                        ctx.fill(Path(ellipseIn: CGRect(x: pos.x-1.6, y: pos.y-1.6, width: 3.2, height: 3.2)), with: .color(.teal))
                        previous = point.date
                    }
                    ctx.stroke(path, with: .color(.teal), lineWidth: 2)
                }
            }.frame(height: 56)
            HStack {
                Text(clock.start, format: .dateTime.month().day())
                Spacer()
                if points.count < 2 { Text("开始记录 · 同步后逐步连线") }
                Spacer()
                Text(clock.end, format: .dateTime.month().day())
            }.font(.caption2).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}
