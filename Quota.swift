import Foundation

struct Limit: Codable {
    var limitId: String? = nil
    var planType: String? = nil
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    var windows: [QuotaWindow] { [primary, secondary].compactMap { $0 } }
}
struct Snapshot: Codable {
    let accountId: String?
    let rateLimits: Limit
    let rateLimitsByLimitId: [String: Limit]?
    var codexLimit: Limit {
        if let codex = rateLimitsByLimitId?["codex"] { return codex }
        if rateLimits.limitId == nil || rateLimits.limitId == "codex" { return rateLimits }
        return Limit(primary: nil, secondary: nil)
    }
    var windows: [QuotaWindow] { codexLimit.windows }
    var week: QuotaWindow? { windows.first { $0.windowDurationMins == 7 * 24 * 60 } }
}

struct QuotaError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Access each reader on a single serial queue. Reuse the read-only connection between polls.
final class Reader {
    private var client: QuotaConnection?
    private var authStamp: Date?
    private var opened = Date.distantPast

    func close() { client = nil }

    func read() throws -> Snapshot {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let stamp = (try? FileManager.default.attributesOfItem(atPath: home + "/auth.json"))?[.modificationDate] as? Date
        if authStamp != stamp || Date().timeIntervalSince(opened) >= 900 { close() }
        if client == nil {
            client = try QuotaConnection()
            authStamp = stamp
            opened = Date()
        }
        guard let client else { throw QuotaError("额度连接未建立。") }
        do { return try client.sample() }
        catch { close(); throw error }
    }
}

private final class QuotaConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var sequence = 0
    private var pending = Data()

    init() throws {
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        var paths = [String]()
        for directory in ["/Applications", userApps] {
            for app in ["ChatGPT", "Codex"] {
                let resources = "\(directory)/\(app).app/Contents/Resources"
                paths += [resources + "/codex-cli/CodexCLI.app/Contents/MacOS/codex", resources + "/codex"]
            }
        }
        paths += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw QuotaError("找不到 Codex，请检查 Mac 上的 Codex 安装。")
        }
        let info = ["name": "quota_clock", "title": "Codex 额度时钟", "version": "1.8"]
        let marker = try JSONEncoder().encode(info)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio", "--startup-client-info", String(decoding: marker, as: UTF8.self)]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        _ = try request("initialize", params: ["clientInfo": info])
        try send(["method": "initialized"])
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func sample() throws -> Snapshot {
        let result = try request("account/rateLimits/read", params: [:])
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: result))
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        sequence += 1
        let timeout = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 18, execute: timeout)
        defer { timeout.cancel() }
        try send(["id": sequence, "method": method, "params": params])
        while true {
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      message["id"] as? Int == sequence else { continue }
                guard let result = message["result"] as? [String: Any] else {
                    throw QuotaError("Codex 读取失败，请检查登录状态和网络。")
                }
                return result
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw QuotaError("读取中断或超时，请检查 Codex 登录和网络后重试。") }
            pending.append(chunk)
        }
    }
}
