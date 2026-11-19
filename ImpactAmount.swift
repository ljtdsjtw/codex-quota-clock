import SwiftUI

// Trajectories are in units of the 100-point type used in the approved preview.
struct ImpactAmount: View {
    let previous: String
    let amount: String
    let tickSecond: Int
    let size: CGFloat
    let rounded: Bool
    private let ink = Color(red: 216/255, green: 1, blue: 228/255)

    var body: some View {
        let before = Array(previous.dropFirst())
        let after = Array(amount.dropFirst())
        let flights = ExitFlight.columns(for: after, tick: tickSecond)
        let schedule = CarrySchedule(before: before, after: after)
        Color.clear.keyframeAnimator(initialValue: 1.0, trigger: amount) { _, phase in
            HStack(spacing: 0) {
                Text("¥")
                ForEach(after.indices, id: \.self) { i in
                    let prior = i + before.count - after.count
                    let old = before.indices.contains(prior) ? String(before[prior]) : ""
                    let new = String(after[i])
                    if let start = schedule.starts[i] {
                        let elapsed = phase * CarrySchedule.duration - start
                        let weight = schedule.weights[i]
                        if elapsed <= 0 {
                            Text(new).hidden().overlay { Text(old) }
                        } else if elapsed < schedule.fall + CarrySchedule.settle {
                            ImpactDigit(old: old, new: new, elapsed: elapsed, fall: schedule.fall,
                                        weight: weight, unit: size / 100, flight: flights[i])
                        } else { Text(new) }
                    } else { Text(new) }
                }
            }
            .font(.system(size: size, weight: .semibold, design: rounded ? .rounded : .default))
            .monospacedDigit()
            .foregroundStyle(ink)
            .padding(.top, size * 0.27)
            .padding(.bottom, size * 0.07)
            .padding(.trailing, size * 0.32)
            .clipped()
        } keyframes: { _ in
            MoveKeyframe(0.0)
            LinearKeyframe(1.0, duration: CarrySchedule.duration)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: amount))
    }
}

// Finish the whole carry before the next one-second clock tick. Each falling
// digit reaches the baseline before the next one departs; exits may overlap.
private struct CarrySchedule {
    static let settle = 0.285
    static let duration = 0.95
    let starts: [Double?]
    let weights: [Double]
    let fall: Double

    init(before: [Character], after: [Character]) {
        let places = after.indices.reversed().filter { after[$0].isNumber }
        let changed = places.filter { i in
            let prior = i + before.count - after.count
            return !before.indices.contains(prior) || before[prior] != after[i]
        }
        let slot = min(0.100, 0.65 / Double(max(1, changed.count)))
        fall = slot * 0.86
        var starts = [Double?](repeating: nil, count: after.count)
        var weights = [Double](repeating: 0, count: after.count)
        for (order, i) in changed.enumerated() { starts[i] = Double(order) * slot }
        for (place, i) in places.enumerated() { weights[i] = 1 - pow(0.73, Double(place)) }
        self.starts = starts
        self.weights = weights
    }
}

private struct ExitFlight {
    let horizontal: Double
    let vertical: Double
    let spin: Double

    static func columns(for digits: [Character], tick: Int) -> [ExitFlight] {
        var vertical = 0.0
        let stationary = ExitFlight(horizontal: 0, vertical: 0, spin: 0)
        var flights = Array(repeating: stationary, count: digits.count)
        for (rank, i) in digits.indices.reversed().filter({ digits[$0].isNumber }).enumerated() {
            var hasher = Hasher()
            hasher.combine(tick)
            hasher.combine(rank)
            let bits = UInt(bitPattern: hasher.finalize())
            let power = Double((bits >> 16) & 0xffff) / 65535
            let direction = Double(bits & 0xffff) / 65535 * 2 - 1
            let angle = direction * .pi / 6
            vertical = rank == 0 ? 160 + 150 * power : vertical + (505 - vertical) * (0.10 + 0.30 * power)
            flights[i] = ExitFlight(horizontal: vertical * tan(angle), vertical: vertical,
                                    spin: (angle < 0 ? -1 : 1) * (1.2 + abs(sin(angle)) * 2.5))
        }
        return flights
    }
}

private struct ImpactDigit: View {
    let old: String
    let new: String
    let elapsed: Double
    let fall: Double
    let weight: Double
    let unit: Double
    let flight: ExitFlight

    // Mix the tint in sRGB according to the height, including the return to rest.
    private func gradient(lift: Double, outgoing: Bool = false) -> LinearGradient {
        let t = lift / (lift + 14)
        let weight = t * t * (3 - 2 * t)
        func color(_ depth: Double) -> Color {
            let w = weight * depth
            func channel(_ base: Double, _ tint: Double) -> Double { (base + (tint - base) * w) / 255 }
            return Color(red: channel(216, outgoing ? 255 : 136),
                         green: channel(255, outgoing ? 132 : 255),
                         blue: channel(228, outgoing ? 107 : 207))
        }
        return LinearGradient(colors: [color(0.62), color(1)], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        Text(new).hidden().overlay {
            if elapsed < fall {
                let u = elapsed / fall
                let lift = (62 + 112 * weight) * (1 - pow(u, 1.6 + weight))
                Text(old)
                Text(new).foregroundStyle(gradient(lift: lift))
                    .scaleEffect(x: 1, y: 1 + 0.15 * pow(sin(.pi * u), 2), anchor: .bottom)
                    .offset(y: -lift * unit).opacity(min(1, u * 3))
            } else {
                let u = (elapsed - fall) / CarrySchedule.settle
                let squash = sin(.pi * min(1, u / 0.23)) * (0.08 + 0.19 * weight)
                let bounce = (3 + 3 * weight) * pow(sin(.pi * min(1, max(0, (u - 0.23) / 0.38))), 2)
                Text(new).foregroundStyle(gradient(lift: bounce))
                    .scaleEffect(x: 1 + 0.8 * squash, y: 1 - squash, anchor: .bottom)
                    .offset(y: -bounce * unit)
                if u < 0.91 {
                    let lift = flight.vertical * u * (1 - u)
                    Text(old).foregroundStyle(gradient(lift: lift, outgoing: true))
                        .scaleEffect(1 - 0.35 * u)
                        .rotationEffect(.radians(flight.spin * (0.25 * u + 0.75 * u * u)))
                        .offset(x: flight.horizontal * u * unit, y: -lift * unit)
                        .opacity(min(1, (0.91 - u) / 0.38))
                }
            }
        }
    }
}
