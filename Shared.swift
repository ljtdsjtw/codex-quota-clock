import Foundation

struct QuotaWindow: Codable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    func progress(at now: Date) -> Pace? {
        guard let minutes = windowDurationMins, minutes > 0,
              let reset = resetsAt, reset > now.timeIntervalSince1970,
              (0...100).contains(usedPercent) else { return nil }
        let duration = Double(minutes) * 60
        let remaining = min(duration, reset - now.timeIntervalSince1970)
        return Pace(duration: duration, remaining: remaining, used: usedPercent / 100)
    }
}

struct Pace {
    let duration: Double
    let remaining: Double
    let used: Double
    var elapsed: Double { 1 - remaining / duration }
    var gap: Double { used - elapsed }
    var timeEquivalent: Double { used * duration }
    var gapTime: Double { abs(gap) * duration }
}

func durationText(_ seconds: Double) -> String {
    let minutes = max(0, Int((seconds / 60).rounded(.down)))
    if minutes < 1 { return "不足 1 分钟" }
    let hours = minutes / 60
    if hours >= 24 { return "\(hours / 24) 天 \(hours % 24) 小时" }
    return hours > 0 ? "\(hours) 小时 \(minutes % 60) 分" : "\(minutes) 分钟"
}
func pct(_ fraction: Double) -> String {
    return (fraction * 100).formatted(.number.precision(.fractionLength(0...1))) + "%"
}

enum PlusComparison {
    // Pro 100 had a standard 5× allowance. It doubled on October 29, 2026.
    static func estimatedWeeks(used: Double, plan: String?) -> Double? {
        guard plan == "prolite" else { return nil }
        return used * 10
    }
}

let widgetKind = "CodexWeeklyQuota"

enum Cost {
    static let defaultMonthly = 690.0
    static func weekly(_ monthly: Double) -> Double { monthly * 12 / 52 }
    static func cny(_ value: Double) -> String { String(format: "¥%.2f", value) }
}

struct WidgetData: Codable {
    let week: QuotaWindow?
    let synced: Date
    let monthly: Double
    var planType: String? = nil

    static func sharedFile(_ name: String) throws -> URL {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "QuotaGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { throw CocoaError(.fileNoSuchFile) }
        return container.appendingPathComponent(name)
    }
    func save() throws {
        try JSONEncoder().encode(self).write(to: Self.sharedFile("week.json"), options: .atomic)
    }
    static func load() -> WidgetData? {
        try? JSONDecoder().decode(Self.self, from: Data(contentsOf: sharedFile("week.json")))
    }
}

let staleAfter: TimeInterval = 30 * 60
