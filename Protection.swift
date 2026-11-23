import Foundation
import WidgetKit

struct GuardSettings: Codable, Equatable {
    var enabled = false
    var threshold = 8
    var interval = 30

    static let intervals = [30, 60, 120, 300]
}

struct GuardReport: Decodable {
    let phase: String?
    let checked_at: TimeInterval?
    let error: String?
    let display_error: String?
}

enum Protection {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexQuotaGuard")
    static let target = "gui/\(getuid())/local.codex-weekly-quota-guard"

    static func settings() -> GuardSettings? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
              let settings = try? JSONDecoder().decode(GuardSettings.self, from: data),
              (1...100).contains(settings.threshold), GuardSettings.intervals.contains(settings.interval)
        else { return nil }
        return settings
    }

    static func report() -> GuardReport? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")) else { return nil }
        return try? JSONDecoder().decode(GuardReport.self, from: data)
    }

    static func isLoaded() -> Bool {
        (try? run("/bin/launchctl", ["print", target])) != nil
    }

    static func apply(_ settings: GuardSettings) throws {
        guard let script = Bundle.main.url(forResource: "quota_guard", withExtension: "py"),
              let executable = Bundle.main.executableURL else { throw QuotaError("安装包缺少额度保护组件。") }
        try run("/usr/bin/python3", ["-I", "-B", script.path, "configure",
            "--enabled", settings.enabled ? "on" : "off", "--threshold", String(settings.threshold),
            "--interval", String(settings.interval), "--sampler", executable.path])
        guard isLoaded() == settings.enabled else { throw QuotaError("后台服务状态尚未就绪，请再保存一次。") }
    }

    static func requestSample() throws {
        try run("/bin/launchctl", ["kill", "SIGUSR1", target])
    }

    private static func run(_ executable: String, _ args: [String]) throws {
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw QuotaError(message.isEmpty ? "后台服务操作失败。" : message)
        }
    }
}

enum QuotaArchive {
    static let notification = Notification.Name("CodexQuotaClockSampleReady")
    // Either the foreground clock or the login service normally publishes. Serialize
    // the handover and monthly-fee edits so an older sample cannot overwrite a new one.
    private static func withLock(_ body: () throws -> Void) throws {
        let path = try WidgetData.sharedFile("sample.lock").path
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw QuotaError("无法打开用量缓存。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw QuotaError("无法写入用量缓存。") }
        try body()
    }

    static func publish(_ snapshot: Snapshot, at date: Date, fromGuard: Bool) -> String? {
        var problem: String?
        do {
            try withLock {
                let previous = WidgetData.load()
                if let previous, previous.synced > date, previous.synced <= Date() { return }
                if let week = snapshot.week {
                    var history = WeekHistory.load()
                    do { try history.record(week: week, account: snapshot.accountId, at: date) }
                    catch { problem = "用量历史暂时无法存盘。" }
                }
                let monthly = (UserDefaults.standard.object(forKey: "monthlyCNY") as? Double) ?? Cost.defaultMonthly
                let data = WidgetData(week: snapshot.week, synced: date, monthly: monthly,
                                      planType: snapshot.codexLimit.planType,
                                      otherWindow: snapshot.windows.first { $0.windowDurationMins != 10080 },
                                      fromGuard: fromGuard, sampleInterval: Protection.settings()?.interval ?? 30)
                try data.save()
                // WidgetKit schedules redraws. Always persist the sample, but only
                // request a redraw for a visible change or a fresh five-minute stamp.
                if previous?.week != data.week || previous?.planType != data.planType || previous?.monthly != monthly ||
                    previous?.sampleInterval != data.sampleInterval ||
                    Int(previous?.synced.timeIntervalSince1970 ?? 0) / 300 != Int(date.timeIntervalSince1970) / 300 {
                    WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
                }
            }
            if fromGuard {
                DistributedNotificationCenter.default().postNotificationName(notification, object: Bundle.main.bundleIdentifier,
                                                                            userInfo: nil, deliverImmediately: true)
            }
        } catch { problem = "小组件数据同步失败。" }
        return problem
    }

    static func updateMonthly(_ monthly: Double) throws {
        try withLock {
            guard var data = WidgetData.load() else { return }
            data.monthly = monthly
            try data.save()
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        }
    }
}

enum QuotaFeed {
    private struct Success: Encodable {
        let result: Snapshot
        let checkedAt: TimeInterval
        let displayError: String?
    }

    // Headless entry point for the LaunchAgent, also usable when the UI is closed.
    // Each reply is a fresh server read. Only the local pipe contains the account ID.
    static func run() {
        let reader = Reader()
        while let line = readLine() {
            guard line == "sample" else { return }
            let data: Data
            do {
                let snapshot = try reader.read()
                let date = Date()
                let error = QuotaArchive.publish(snapshot, at: date, fromGuard: true)
                data = try JSONEncoder().encode(Success(result: snapshot, checkedAt: date.timeIntervalSince1970,
                                                        displayError: error))
            } catch {
                guard let failure = try? JSONEncoder().encode(["error": error.localizedDescription]) else { return }
                data = failure
            }
            do { try FileHandle.standardOutput.write(contentsOf: data + [10]) }
            catch { return }
        }
    }
}
