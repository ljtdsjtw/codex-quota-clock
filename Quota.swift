import Foundation

struct Limit: Decodable {
    var planType: String? = nil
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    var windows: [QuotaWindow] { [primary, secondary].compactMap { $0 } }
}
struct Snapshot: Decodable {
    let accountId: String?
    let rateLimits: Limit
    let rateLimitsByLimitId: [String: Limit]?
    var codexLimit: Limit { rateLimitsByLimitId?["codex"] ?? rateLimits }
    var windows: [QuotaWindow] { codexLimit.windows }
    var week: QuotaWindow? { windows.first { $0.windowDurationMins == 7 * 24 * 60 } }
}

struct QuotaError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Reader {
    static func read() throws -> Snapshot {
        let bundled = ["ChatGPT", "Codex"].map {
            "/Applications/\($0).app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        }
        let candidates = bundled + ["/Applications/Codex.app/Contents/Resources/codex",
                                     "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw QuotaError("找不到 Codex，请检查 Mac 上的 Codex 安装。")
        }

        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 22, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo":
                    ["name": "quota_clock", "title": "Codex 额度时钟", "version": "1.0"]]])
        var pending = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw QuotaError("读取中断或超时，请检查 Codex 登录和网络后重试。") }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = msg["id"] as? Int, id == 1 || id == 2 else { continue }
                if msg["error"] != nil { throw QuotaError("Codex 未能返回额度，请检查登录状态和网络。") }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                } else if let result = msg["result"] as? [String: Any] {
                    return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: result))
                } else { throw QuotaError("Codex 返回了无法识别的额度数据。") }
            }
        }
    }
}
