import SwiftUI
import IOKit.ps
import Combine
import WidgetKit

final class Model: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var updated: Date?
    @Published var fetching = false
    @Published var problem: String?
    @Published var now = Date()
    @Published var sharingProblem: String?
    @Published var history = WeekHistory.load()
    @Published var onAC = Power.onAC
    @Published private(set) var settings = GuardSettings()
    @Published private(set) var serviceLoaded = false
    @Published private(set) var legacyService = false
    @Published private(set) var report: GuardReport?
    @Published private(set) var applying = false
    @Published var settingsProblem: String?
    private let reader = Reader()
    private let reads = DispatchQueue(label: "quota.sync", qos: .utility)
    private var powerSource: CFRunLoopSource?
    private var timer: Timer?
    private var pollTimer: Timer?
    private var observer: NSObjectProtocol?
    private var generation = 0
    private var requestTime: Date?
    private var lastServiceCheck = Date.distantPast
    var stale: Bool { updated.map { now.timeIntervalSince($0) >= staleAfter } ?? false }
    private var backgroundProvidesSamples: Bool { settings.enabled && serviceLoaded && !legacyService }

    var protectionStatus: String {
        if legacyService { return "旧版后台正在运行" }
        if !settings.enabled { return "已关闭" }
        guard serviceLoaded else { return "后台未运行" }
        if report?.error != nil { return "读取异常" }
        guard let checked = report?.checked_at,
              abs(now.timeIntervalSince1970 - checked) <= Double(settings.interval * 2 + 30)
        else { return "等待读数" }
        switch report?.phase {
        case "triggered": return "本周已触发"
        case "stopping": return "正在断开"
        default: return "低于 " + String(settings.threshold) + "% 时断开"
        }
    }

    private func restore(_ cached: WidgetData) {
        snapshot = Snapshot(accountId: nil, rateLimits: Limit(planType: cached.planType,
                            primary: cached.week, secondary: cached.otherWindow), rateLimitsByLimitId: nil)
        updated = cached.synced
        history = WeekHistory.load()
    }

    func start() {
        if let cached = WidgetData.load() { restore(cached) }
        powerSource = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let model = Unmanaged<Model>.fromOpaque(context).takeUnretainedValue()
            model.onAC = Power.onAC
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        observer = DistributedNotificationCenter.default().addObserver(forName: QuotaArchive.notification,
                              object: Bundle.main.bundleIdentifier, queue: .main) { [weak self] _ in
            self?.readBackgroundSample()
        }
        reconcile(forceCheck: true, restart: true)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            now = Date()
            guard !applying else { return }
            reconcile()
            readBackgroundSample()
        }
    }

    deinit {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        timer?.invalidate()
        pollTimer?.invalidate()
    }

    func reconcile(forceCheck: Bool = false, restart: Bool = false) {
        let disk = Protection.settings()
        var policy = disk ?? GuardSettings()
        let shouldInspect = forceCheck || policy != settings ||
            ((settings.enabled || serviceLoaded) && Date().timeIntervalSince(lastServiceCheck) >= 60)
        let loaded = shouldInspect ? Protection.isLoaded() : serviceLoaded
        if shouldInspect { lastServiceCheck = Date() }
        let legacy = loaded && disk?.enabled != true
        if legacy { policy.enabled = true }
        guard restart || policy != settings || loaded != serviceLoaded || legacy != legacyService else { return }
        settings = policy
        serviceLoaded = loaded
        legacyService = legacy
        generation += 1
        fetching = false
        requestTime = nil
        pollTimer?.invalidate()
        report = settings.enabled ? Protection.report() : nil
        if backgroundProvidesSamples {
            reads.async { [reader] in reader.close() }
            readBackgroundSample()
        } else {
            refresh()
            pollTimer = Timer.scheduledTimer(withTimeInterval: Double(policy.interval), repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    private func readBackgroundSample() {
        guard backgroundProvidesSamples else { return }
        now = Date()
        report = Protection.report()
        if let cached = WidgetData.load(), cached.fromGuard == true, cached.synced != updated {
            restore(cached)
        }
        problem = report?.error
        sharingProblem = report?.display_error
        if let requestTime {
            let arrived = (updated ?? .distantPast) >= requestTime
            if arrived || problem != nil || now.timeIntervalSince(requestTime) > 40 {
                if !arrived && problem == nil { problem = "后台尚未返回新的读数。" }
                fetching = false
                self.requestTime = nil
            }
        }
    }

    func refresh() {
        guard !fetching, !applying else { return }
        fetching = true
        if backgroundProvidesSamples {
            requestTime = Date()
            do { try Protection.requestSample() }
            catch {
                problem = "后台刷新失败：" + error.localizedDescription
                requestTime = nil
                fetching = false
            }
            return
        }
        let current = generation
        reads.async { [weak self, reader] in
            let result = Result { try reader.read() }
            let date = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                fetching = false
                now = date
                switch result {
                case let .success(value):
                    snapshot = value
                    updated = date
                    problem = nil
                    sharingProblem = QuotaArchive.publish(value, at: date, fromGuard: false)
                    history = WeekHistory.load()
                case .failure(let error): problem = error.localizedDescription
                }
            }
        }
    }

    func apply(_ policy: GuardSettings, completion: @escaping (Bool) -> Void) {
        guard !applying else { return }
        applying = true
        settingsProblem = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Protection.apply(policy) }
            DispatchQueue.main.async {
                self.applying = false
                self.reconcile(forceCheck: true, restart: true)
                switch result {
                case .success: completion(true)
                case .failure(let error):
                    self.settingsProblem = "保存失败：" + error.localizedDescription
                    completion(false)
                }
            }
        }
    }

    func publishWidget() {
        let monthly = (UserDefaults.standard.object(forKey: "monthlyCNY") as? Double) ?? Cost.defaultMonthly
        do { try QuotaArchive.updateMonthly(monthly); sharingProblem = nil }
        catch { sharingProblem = "小组件数据同步失败。" }
    }
}

private let ink = Color(red: 0.09, green: 0.18, blue: 0.18)
private let teal = Color(red: 0.02, green: 0.40, blue: 0.38)
private let brass = Color(red: 0.54, green: 0.31, blue: 0.10)
private let paper = Color(red: 0.97, green: 0.97, blue: 0.95)

private struct PaceScale: View {
    let pace: Pace
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(teal.opacity(0.12)).frame(height: 10)
                    Capsule().fill(teal).frame(width: w * pace.used, height: 10)
                    RoundedRectangle(cornerRadius: 1).fill(brass)
                        .frame(width: 3, height: 21)
                        .offset(x: (w - 3) * pace.elapsed)
                }
            }.frame(height: 21)
            HStack(spacing: 16) {
                Label("实际已用 " + pct(pace.used), systemImage: "circle.fill").foregroundStyle(teal)
                Label("按时间应已用 " + pct(pace.elapsed), systemImage: "line.diagonal").foregroundStyle(brass)
            }.font(.system(size: 12, weight: .medium))
        }
    }
}

struct Panel: View {
    @ObservedObject var model: Model
    @Binding var showMenuBarQuota: Bool
    @AppStorage("monthlyCNY") private var monthly = Cost.defaultMonthly
    @Binding var showDesktopFee: Bool
    @State private var showProtection = false
    @State private var comparisonInfo = false
    @State private var editing = false
    @State private var draft = ""
    private var amount: Double? {
        guard let v = Double(draft.trimmingCharacters(in: .whitespacesAndNewlines)), v.isFinite,
              v >= 0, v <= 1000000 else { return nil }
        return v
    }
    private func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日 HH:mm"
        return f.string(from: date)
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "clock.badge.checkmark").foregroundStyle(teal)
                Text("Codex 额度时钟").font(.system(size: 20, weight: .bold))
                Spacer()
                Button {
                    model.reconcile(forceCheck: true)
                    model.settingsProblem = nil
                    showProtection = true
                } label: {
                    Label("保护与刷新", systemImage: "shield")
                }
                Button { model.refresh() } label: {
                    Label(model.fetching ? "读取中" : "刷新", systemImage: "arrow.clockwise")
                }.disabled(model.fetching)
            }
            if let week = model.snapshot?.week, let p = week.progress(at: model.now), let reset = week.resetsAt {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("本周剩余额度").font(.callout)
                                if model.stale { Text("待更新").font(.caption.bold()).foregroundStyle(brass) }
                            }
                            Text(pct(1 - p.used)).font(.system(size: 53, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(teal)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("距离重置还有 " + durationText(p.remaining)).fontWeight(.medium)
                            Text(dateText(Date(timeIntervalSince1970: reset)) + " 重置").font(.caption).foregroundStyle(.secondary)
                        }.padding(.bottom, 7)
                    }
                    PaceScale(pace: p)
                    if let plus = PlusComparison.estimatedWeeks(used: p.used, plan: model.snapshot?.codexLimit.planType) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("折合 Plus 周额度").fontWeight(.medium)
                                Text("约 " + pct(plus)).bold().monospacedDigit()
                                Spacer()
                                Button { comparisonInfo.toggle() } label: {
                                    Image(systemName: "info.circle")
                                }.buttonStyle(.plain).accessibilityLabel("Plus 额度换算说明")
                                .popover(isPresented: $comparisonInfo) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Plus 额度怎么读").font(.headline)
                                        Text("Pro 100 原标准用量为 Plus 的 5 倍，10 月 29 日翻倍。这里按约 10 倍估算，每 100% 代表一份 Plus 周额度。")
                                        Text("近 5 小时取相同周周期的累计用量差。采样间有空档时显示范围或已观测用量。")
                                        Text("Plus 的 5 小时窗口从上一窗口结束后的首条消息起算。官方举例：GPT-6 Astra 约 5–45 条本地消息，GPT-6.1 Sol 约 15–160 条，随任务变化。")
                                        Link("OpenAI 套餐调整记录", destination: URL(string: "https://help.openai.com/en/articles/6825453-chatgpt-release-notes")!)
                                        Link("OpenAI 五小时额度说明", destination: URL(string: "https://help.openai.com/en/articles/20001516")!)
                                    }.font(.callout).fixedSize(horizontal: false, vertical: true).padding(14).frame(width: 310)
                                }
                            }
                            if let updated = model.updated, let recent = model.history.recentUsage(through: updated, week: week) {
                                Text("近 5 小时 · Pro " + recent).foregroundStyle(.secondary)
                            }
                        }.font(.callout)
                    }
                    Divider()
                    HStack {
                        stat("已用额度折合时间", durationText(p.timeEquivalent))
                        stat("本周实际已过", durationText(p.elapsed * p.duration))
                    }
                    Text(abs(p.gap) < 0.0005 ? "用量与均匀进度基本一致" :
                            "比均匀进度" + (p.gap > 0 ? "快 " : "慢 ") + durationText(p.gapTime)
                            + String(format: "  ·  相差 %.1f 个百分点", abs(p.gap) * 100))
                        .font(.callout.weight(.medium)).foregroundStyle(p.gap > 0 ? brass : teal)
                }.padding(19).background(.white, in: RoundedRectangle(cornerRadius: 14))
                if let clock = week.feeClock(monthly: monthly) {
                    UsageChart(points: model.history.reset == week.resetsAt ? model.history.points : [], clock: clock)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("订阅费折算").font(.headline)
                        Spacer()
                        Button("月费 " + Cost.cny(monthly) + "  ✎") {
                            draft = String(format: "%.2f", monthly)
                            editing = true
                        }.buttonStyle(.plain).foregroundStyle(teal)
                    }
                    HStack {
                        stat("平均每周", Cost.cny(Cost.weekly(monthly)))
                        stat("已用额度对应", Cost.cny(Cost.weekly(monthly) * p.used))
                        if let clock = week.feeClock(monthly: monthly) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("本周按时间分摊").font(.caption).foregroundStyle(.secondary)
                                LiveFee(clock: clock, onAC: model.onAC, now: model.now, size: 17)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .background(ink, in: RoundedRectangle(cornerRadius: 5))
                            }.font(.system(size: 17, weight: .semibold)).monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("按一年 52 周分摊月费，金额单位为人民币。").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 3)
            } else {
                if model.stale { Text("待更新").font(.caption.bold()).foregroundStyle(brass) }
                Text(model.snapshot == nil ? (model.fetching ? "正在读取 Codex 账户额度…" : "周额度暂不可用") :
                        (model.snapshot?.week == nil ? "当前账户未返回七天额度。" : "本周期数据已到期或缺少重置时间，请刷新。"))
                    .padding(.vertical, 35)
            }
            if let limit = model.snapshot {
                ForEach(Array(limit.windows.enumerated()), id: \.offset) { _, window in
                    if let mins = window.windowDurationMins, mins != 10080, let p = window.progress(at: model.now) {
                        Text("\(mins) 分钟窗口 · 剩余 \(pct(1 - p.used)) · \(durationText(p.remaining))后重置").font(.callout)
                    }
                }
            }
            if let problem = model.sharingProblem { Text(problem).foregroundStyle(brass) }
            if let problem = model.problem {
                Text(problem + (model.updated != nil ? " 显示上次成功读取的数据。" : "")).font(.callout).foregroundStyle(brass)
            }
            HStack {
                Toggle("在菜单栏显示额度", isOn: $showMenuBarQuota)
                Spacer()
                Toggle("桌面实时金额卡", isOn: $showDesktopFee)
            }.toggleStyle(.switch).controlSize(.small)
            HStack {
                Circle().fill(!model.stale && model.problem == nil && model.updated != nil ? teal : brass).frame(width: 6, height: 6)
                Text(model.updated.map { "同步 " + $0.formatted(.dateTime.hour().minute().second()) } ?? "尚未同步")
                Spacer()
                Text("每 " + refreshIntervalText(model.settings.interval) + " · 保护" + model.protectionStatus)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 485).foregroundStyle(ink).background(paper)
        .preferredColorScheme(.light)
        .onChange(of: monthly) { _, _ in model.publishWidget() }
        .sheet(isPresented: $showProtection) {
            ProtectionPanel(model: model, settings: model.settings)
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 15) {
                Text("每月实付订阅费").font(.headline)
                HStack { Text("人民币 ¥"); TextField("690.00", text: $draft).textFieldStyle(.roundedBorder) }
                HStack {
                    Spacer()
                    Button("取消") { editing = false }.keyboardShortcut(.cancelAction)
                    Button("保存") { if let amount { monthly = amount; editing = false } }
                        .keyboardShortcut(.defaultAction).disabled(amount == nil)
                }
            }.padding(22).frame(width: 280)
        }
    }
}
