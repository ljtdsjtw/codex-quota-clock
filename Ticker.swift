import Foundation
import IOKit.ps

enum Power {
    static var onAC: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return type as String == kIOPMACPowerKey
    }
}

struct FeeClock: Codable, Hashable {
    let start: Date
    let end: Date
    let total: Double

    func value(at date: Date) -> Double {
        let seconds = floor(date.timeIntervalSince(start))
        return total * min(1, max(0, seconds / end.timeIntervalSince(start)))
    }
    // A one-cent boundary at the default price. Larger fees use coarser steps
    // to keep the number of archived widget entries bounded.
    func nextMilestone(after date: Date) -> Date? {
        guard total > 0, date < end else { return nil }
        let duration = end.timeIntervalSince(start)
        let step = max(1, ceil(total * 100 * 30 / duration))
        let cents = (value(at: date) * 100).rounded()
        let next = (floor(cents / step) + 1) * step
        let offset = ceil((next - 0.5) * duration / (total * 100))
        let result = min(end, start.addingTimeInterval(offset))
        return result > date ? result : nil
    }
    func digits(at date: Date) -> String {
        String(format: "¥%.4f", value(at: date))
    }
}

extension QuotaWindow {
    func feeClock(monthly: Double) -> FeeClock? {
        guard let reset = resetsAt, let minutes = windowDurationMins, minutes > 0 else { return nil }
        let end = Date(timeIntervalSince1970: reset)
        return FeeClock(start: end.addingTimeInterval(-Double(minutes) * 60), end: end, total: Cost.weekly(monthly))
    }
}
