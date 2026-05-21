import Foundation

// MARK: - 喂给 DeepSeek 的用量快照

/// 单个供应商的用量切片，纯数据，可安全跨线程传递。
struct ProviderSnapshot: Sendable {
    var plan: String?
    var renewalDay: Int
    var fiveHourPercent: Double?
    var fiveHourResetAt: Date?
    var weeklyPercent: Double?
    var weeklyResetAt: Date?
    var error: String?
}

/// 一次文案生成所需的全部信息。
struct UsageSnapshot: Sendable {
    var claude: ProviderSnapshot
    var codex: ProviderSnapshot
    var peakHourTotal: Int
    var weekTokenTotal: Int
    var todayTokenTotal: Int
    /// 最近 7 天里最活跃的钟点（0...23），无数据时为 nil。
    var busiestHour: Int?
    /// 用户希望被称呼的名字，可为空。
    var userName: String
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
        case .noAPIKey: return "未配置 DeepSeek Key —— 在菜单栏「设置」里填一个"
        case .unauthorized: return "DeepSeek Key 无效 —— 在「设置」里检查一下"
        case .insufficientBalance: return "DeepSeek 账户余额不足"
        case let .http(code): return "DeepSeek 请求失败（HTTP \(code)）"
        case .badResponse: return "DeepSeek 返回了无法解析的内容"
        }
    }
}

// MARK: - 调用 DeepSeek 生成俏皮文案

private let quipSystemPrompt = """
你是 CodexBar 菜单栏里的一只像素小精灵，机灵、嘴碎、有点皮，是用户写代码时的搭子。
我会告诉你用户此刻在 Claude Code 与 Codex 上的编程额度情况，你要回一句俏皮话加贴心提醒。
要求：
- 说人话，像朋友之间随口搭话那样自然 —— 别端着、别肉麻，绝对不要用「主人」这类称呼；
- 一到两句话，45 个汉字以内；
- 口语化、可以带点梗和调侃，但提醒要真实有用：额度紧张提醒省着点、临近重置或续费要点出来、写太猛或太闲都能玩梗；
- 如果我给了用户的称呼，可以偶尔喊一下拉近距离，但别每句都喊；没给就用「你」；
- 最多用一个 emoji；
- 直接输出文案本身，不要加引号、不要解释、不要换行。
"""

/// 调用 deepseek-v4-flash，根据用量快照生成一段俏皮总结。
func generateQuip(from snapshot: UsageSnapshot) async throws -> String {
    guard let apiKey = CodexBarConfig.load().deepseekKeyIfPresent else {
        throw QuipError.noAPIKey
    }

    var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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
    func describe(_ name: String, _ provider: ProviderSnapshot) -> String {
        let sub = Subscription(renewalDay: provider.renewalDay)
        let planPart = provider.plan
            .map { $0.isEmpty ? "" : "\($0.capitalized) 套餐，" } ?? ""
        let head = "\(name)（\(planPart)\(sub.renewalText)）："
        if let error = provider.error {
            return head + "暂时读不到额度（\(error)）。"
        }
        var parts: [String] = []
        if let five = provider.fiveHourPercent {
            var text = "5 小时额度用了 \(Int(five.rounded()))%"
            if let reset = provider.fiveHourResetAt {
                text += "（约 \(relativeText(reset))后重置）"
            }
            parts.append(text)
        }
        if let weekly = provider.weeklyPercent {
            var text = "7 天额度用了 \(Int(weekly.rounded()))%"
            if let reset = provider.weeklyResetAt {
                text += "（约 \(relativeText(reset))后重置）"
            }
            parts.append(text)
        }
        return head + (parts.isEmpty ? "暂无额度数据" : parts.joined(separator: "，")) + "。"
    }

    var lines: [String] = []
    if !snapshot.userName.isEmpty {
        lines.append("用户的称呼是「\(snapshot.userName)」。")
    }
    lines.append(describe("Claude Code", snapshot.claude))
    lines.append(describe("Codex", snapshot.codex))
    if snapshot.weekTokenTotal > 0 {
        var text = "最近 7 天累计写了约 \(shortTokens(snapshot.weekTokenTotal)) token"
        if snapshot.todayTokenTotal > 0 {
            text += "，其中今天约 \(shortTokens(snapshot.todayTokenTotal))"
        }
        if let hour = snapshot.busiestHour {
            text += "，写得最猛的时段是 \(hour) 点前后"
        }
        lines.append(text + "。")
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "EEEE HH:mm"
    lines.append("现在是 \(formatter.string(from: snapshot.generatedAt))。")
    return lines.joined(separator: "\n")
}
