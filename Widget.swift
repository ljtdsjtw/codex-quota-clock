import SwiftUI
import WidgetKit

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetData?
    var onAC = false
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        let now = Date()
        return QuotaEntry(date: now, snapshot: WidgetData(
            week: QuotaWindow(usedPercent: 35, windowDurationMins: 10080,
                              resetsAt: now.addingTimeInterval(4 * 86400).timeIntervalSince1970),
            synced: now, monthly: Cost.defaultMonthly))
    }
    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: Date(), snapshot: WidgetData.load(), onAC: Power.onAC))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let data = WidgetData.load(), now = Date()
        let ac = Power.onAC
        let horizon = now.addingTimeInterval(1800)
        var dates = [now]
        if ac, let data, let clock = data.week?.feeClock(monthly: data.monthly), clock.total > 0 {
            var cursor = now
            while let next = clock.nextMilestone(after: cursor), next < horizon {
                dates.append(next)
                cursor = next
            }
        } else {
            dates += (1..<6).map { now.addingTimeInterval(Double($0) * 300) }
        }
        if let data {
            let stale = data.synced.addingTimeInterval(staleAfter)
            if stale > now { dates.append(stale) }
            if let reset = data.week?.resetsAt.map(Date.init(timeIntervalSince1970:)), reset > now { dates.append(reset) }
        }
        let entries = Set(dates).sorted().map { QuotaEntry(date: $0, snapshot: data, onAC: ac) }
        completion(Timeline(entries: entries, policy: .after(horizon)))
    }
}

struct ClockFace: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let entry: QuotaEntry
    private let mint = Color(red: 0.48, green: 0.93, blue: 0.77)
    private let sand = Color(red: 1, green: 0.82, blue: 0.53)
    private func line(_ caption: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(caption).foregroundStyle(.white.opacity(0.78))
            Spacer(minLength: 2)
            Text(value).bold().monospacedDigit()
        }.font(.system(size: 12))
    }
    private func feeRow(_ clock: FeeClock) -> some View {
        HStack(spacing: 2) {
            Text("时间分摊").foregroundStyle(.white.opacity(0.78))
            Spacer(minLength: 1)
            let value = clock.value(at: entry.date)
            Text(Cost.cny(value))
                .contentTransition(entry.onAC && !reduceMotion ? .numericText(value: value) : .identity)
        }.font(.system(size: 12, weight: .medium)).monospacedDigit()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(mint)
                Text("Codex 周额度").bold()
                Spacer()
                if let data = entry.snapshot, entry.date.timeIntervalSince(data.synced) >= staleAfter {
                    Text("待更新").bold().foregroundStyle(sand)
                }
                if family == .systemMedium, let data = entry.snapshot {
                    Text(data.synced, format: .dateTime.month().day().hour().minute())
                    Text("同步")
                }
            }.font(.caption2)
            if let data = entry.snapshot, let p = data.week?.progress(at: entry.date) {
                let week = Cost.weekly(data.monthly)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(pct(1 - p.used)).font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(mint)
                    Text("剩余").font(.caption)
                    Spacer()
                    if family == .systemMedium { Text("距重置 " + durationText(p.remaining)).font(.caption) }
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(mint).frame(width: g.size.width * p.used)
                        Rectangle().fill(sand).frame(width: 2, height: 9).offset(x: (g.size.width - 2) * p.elapsed)
                    }
                }.frame(height: 6).padding(.vertical, 3)
                if family == .systemMedium {
                    if let plus = PlusComparison.estimatedWeeks(used: p.used, plan: data.planType) {
                        line("折合 Plus 周额度", "约 " + pct(plus))
                    }
                    HStack(spacing: 12) {
                        VStack { line("实际已用", pct(p.used)); line("已用折合", durationText(p.timeEquivalent)); line("已用分摊", Cost.cny(week * p.used)) }
                        Divider().overlay(.white.opacity(0.4))
                        VStack { line("均匀应已用", pct(p.elapsed)); line("每周均摊", Cost.cny(week)); if let clock = data.week?.feeClock(monthly: data.monthly) { feeRow(clock) } }
                    }.fixedSize(horizontal: false, vertical: true)
                } else {
                    line("已用 / 应已用", pct(p.used) + " / " + pct(p.elapsed))
                    line("已用分摊", Cost.cny(week * p.used))
                    if let clock = data.week?.feeClock(monthly: data.monthly) { feeRow(clock) }
                    Text(data.synced, format: .dateTime.month().day().hour().minute()).font(.caption2)
                }
                if entry.onAC && !reduceMotion, let clock = data.week?.feeClock(monthly: data.monthly), let end = clock.nextMilestone(after: entry.date) {
                    HStack(spacing: 4) {
                        ProgressView(timerInterval: entry.date...end, countsDown: false) {
                            EmptyView()
                        } currentValueLabel: { EmptyView() }
                            .progressViewStyle(.linear).tint(sand)
                        Text("→ " + Cost.cny(clock.value(at: end))).font(.system(size: 9))
                    }.accessibilityLabel("时间分摊的增长进度")
                }
            } else {
                Spacer()
                Text("等待周额度").font(.headline)
                Text("打开额度时钟同步最新数据").font(.caption)
                Spacer()
            }
        }.lineLimit(1).minimumScaleFactor(0.75)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { Color(red: 0.055, green: 0.18, blue: 0.18) }
    }
}

@main
struct QuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: Provider()) { ClockFace(entry: $0) }
            .configurationDisplayName("Codex 周额度")
            .description("对照实际用量和均匀进度，查看人民币订阅费分摊。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
