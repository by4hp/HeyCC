import Foundation

// MARK: - 配置文件 ~/.dee_codexbar/config.json

/// CodexBar 个人版的本地配置。目前只存 DeepSeek 的 API Key。
/// 用独立目录 ~/.dee_codexbar/，避免和原版 CodexBar 的 ~/.codexbar/ 撞文件。
struct CodexBarConfig: Sendable {
    let deepseekAPIKey: String

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dee_codexbar/config.json")

    /// 读取配置；文件缺失或 Key 为空时返回 nil。
    static func load() -> CodexBarConfig? {
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawKey = root["deepseek_api_key"] as? String
        else { return nil }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return CodexBarConfig(deepseekAPIKey: key)
    }

    /// 首次运行时写一份带说明的空配置模板；已存在则不动（不会覆盖用户填好的 Key）。
    static func createTemplateIfMissing() {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let template = """
        {
          "_说明": "把 DeepSeek 的 API Key 填到下面的 deepseek_api_key（从 https://platform.deepseek.com/api_keys 获取）。填好后重启 CodexBar，刘海面板底部就会出现俏皮总结。",
          "deepseek_api_key": ""
        }

        """
        try? Data(template.utf8).write(to: path)
    }
}

// MARK: - 喂给 DeepSeek 的用量快照

/// 单个供应商的用量切片，纯数据，可安全跨线程传递。
struct ProviderSnapshot: Sendable {
    var fiveHourPercent: Double?
    var weeklyPercent: Double?
    var weeklyResetAt: Date?
    var error: String?
}

/// 一次文案生成所需的全部信息。
struct UsageSnapshot: Sendable {
    var claude: ProviderSnapshot
    var codex: ProviderSnapshot
    var peakHourTotal: Int
    var generatedAt: Date
}

// MARK: - 错误

enum QuipError: LocalizedError, Sendable {
    case noAPIKey
    case unauthorized
    case insufficientBalance
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "未配置 DeepSeek Key，请编辑 ~/.dee_codexbar/config.json"
        case .unauthorized: return "DeepSeek Key 无效，请检查 ~/.dee_codexbar/config.json"
        case .insufficientBalance: return "DeepSeek 账户余额不足"
        case let .http(code): return "DeepSeek 请求失败（HTTP \(code)）"
        case .badResponse: return "DeepSeek 返回了无法解析的内容"
        }
    }
}

// MARK: - 调用 DeepSeek 生成俏皮文案

private let quipSystemPrompt = """
你是 macOS 菜单栏小工具 CodexBar 的吉祥物，性格俏皮、嘴碎、爱玩梗。
我会给你用户当前的 Claude Code 与 Codex 的 AI 编程额度数据，你要写一句中文俏皮总结加贴心提醒。
要求：
- 一到两句话，控制在 45 个汉字以内；
- 口语化、带点梗、可以调侃用户，但提醒必须真实有用：额度紧张就提醒省着点，临近重置或临近续费要点出来，用得太猛或太闲都可以调侃；
- 最多用一个 emoji，别堆表情；
- 直接输出文案本身，不要加引号、不要解释、不要换行。
"""

/// 调用 deepseek-v4-flash，根据用量快照生成一段俏皮总结。
func generateQuip(from snapshot: UsageSnapshot) async throws -> String {
    guard let config = CodexBarConfig.load() else { throw QuipError.noAPIKey }

    var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(config.deepseekAPIKey)", forHTTPHeaderField: "Authorization")

    let body: [String: Any] = [
        "model": "deepseek-v4-flash",
        // 关闭思考模式：只要一句俏皮话，不需要推理链，否则 token 全耗在 reasoning_content 上、content 为空。
        "thinking": ["type": "disabled"],
        "messages": [
            ["role": "system", "content": quipSystemPrompt],
            ["role": "user", "content": buildQuipPrompt(snapshot)],
        ],
        "temperature": 1.3,
        "max_tokens": 200,
        "stream": false,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw QuipError.badResponse }
    switch http.statusCode {
    case 200 ..< 300: break
    case 401: throw QuipError.unauthorized
    case 402: throw QuipError.insufficientBalance
    default: throw QuipError.http(http.statusCode)
    }

    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = root["choices"] as? [[String: Any]],
          let message = choices.first?["message"] as? [String: Any],
          let content = message["content"] as? String
    else { throw QuipError.badResponse }

    let quip = content
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
    guard !quip.isEmpty else { throw QuipError.badResponse }
    return quip
}

// MARK: - 构造提示词

/// 把用量快照拼成一段中文描述，作为 DeepSeek 的 user 消息。
private func buildQuipPrompt(_ snapshot: UsageSnapshot) -> String {
    func describe(_ name: String, _ provider: ProviderSnapshot, _ sub: Subscription) -> String {
        let head = "\(name)（\(sub.plan) 套餐，\(sub.renewalText)）："
        if let error = provider.error {
            return head + "暂时读不到额度（\(error)）。"
        }
        var parts: [String] = []
        if let five = provider.fiveHourPercent {
            parts.append("5 小时额度用了 \(Int(five.rounded()))%")
        }
        if let weekly = provider.weeklyPercent {
            parts.append("7 天额度用了 \(Int(weekly.rounded()))%")
        }
        if let reset = provider.weeklyResetAt {
            parts.append("7 天额度约 \(relativeText(reset))后重置")
        }
        return head + (parts.isEmpty ? "暂无额度数据" : parts.joined(separator: "，")) + "。"
    }

    var lines = [
        describe("Claude Code", snapshot.claude, claudeSubscription),
        describe("Codex", snapshot.codex, codexSubscription),
    ]
    if snapshot.peakHourTotal > 0 {
        lines.append("最近 7 天单小时 token 用量峰值约 \(shortTokens(snapshot.peakHourTotal))。")
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "EEEE HH:mm"
    lines.append("现在是 \(formatter.string(from: snapshot.generatedAt))。")
    return lines.joined(separator: "\n")
}
