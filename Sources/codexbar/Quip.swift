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
你是 CodexBar 菜单栏里的一只像素小精灵，软萌可爱、活泼黏人，是用户写代码时的小伙伴。
我会告诉你用户此刻在 Claude Code 与 Codex 上的编程额度，以及当前的日期和时间，你要回一句又萌又贴心的俏皮话。
要求：
- 语气软乎乎、轻松俏皮，像只会撒娇的小精灵；可爱但别肉麻、别油腻；
- 称呼用户就直接喊我给的那个名字，绝对不要用「老哥」「兄弟」「主人」「亲」这类称呼；没给名字就用「你」；
- 一到两句话，45 个汉字以内；
- 结合时间说话：深夜劝早点睡、清晨道声早、饭点喊吃饭、周末松弛点；
- 提醒要真实有用：额度紧张提醒省着点、临近重置或续费要点出来、写太猛或太闲都能玩梗；
- 最多用一个可爱的 emoji；
- 直接输出文案本身，不要加引号、不要解释、不要换行。
"""

/// 用户点击面板上某个元素「问」小精灵时用的系统提示。
private let replySystemPrompt = """
你是 CodexBar 菜单栏里的一只像素小精灵，软萌可爱、活泼黏人，是用户写代码时的小伙伴。
用户刚在面板上点了某个东西想听你说说，我会告诉你他点的是什么、对应的数据。
你要紧扣他点的这件事，回一句又萌又贴心、带点小见解或小建议的话。
要求：
- 语气软乎乎、轻松俏皮，像只会撒娇的小精灵；可爱但别肉麻、别油腻；
- 称呼用户就直接喊我给的那个名字，绝对不要用「老哥」「兄弟」「主人」「亲」这类称呼；没给名字就用「你」；
- 一到两句话，45 个汉字以内；
- 就事论事，针对他点的那件事说，可以玩个小梗或给个小提醒；
- 最多用一个可爱的 emoji；
- 直接输出文案本身，不要加引号、不要解释、不要换行。
"""

/// 调用 deepseek-v4-flash，给定 system 与 user 消息，返回单段文案。
private func callDeepSeek(system: String, user: String) async throws -> String {
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
            ["role": "system", "content": system],
            ["role": "user", "content": user],
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

    let text = content
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
    guard !text.isEmpty else { throw QuipError.badResponse }
    return text
}

/// 根据用量快照生成一段周期性的俏皮总结。
func generateQuip(from snapshot: UsageSnapshot) async throws -> String {
    try await callDeepSeek(system: quipSystemPrompt, user: buildQuipPrompt(snapshot))
}

/// 针对用户在面板上点击的内容（热力图某天、今日脉搏、燃尽预测等）回应一句。
func generateReply(about context: String, userName: String) async throws -> String {
    let user = userName.isEmpty ? context : "用户的称呼是「\(userName)」。\n" + context
    return try await callDeepSeek(system: replySystemPrompt, user: user)
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
    formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm"
    let hour = Calendar.current.component(.hour, from: snapshot.generatedAt)
    lines.append("现在是 \(formatter.string(from: snapshot.generatedAt))（\(timeOfDayLabel(hour))）。")
    return lines.joined(separator: "\n")
}

/// 把钟点归类成时段词，让小精灵更好结合时间说话。
private func timeOfDayLabel(_ hour: Int) -> String {
    switch hour {
    case 5 ..< 8: return "清晨"
    case 8 ..< 11: return "上午"
    case 11 ..< 13: return "中午"
    case 13 ..< 17: return "下午"
    case 17 ..< 19: return "傍晚"
    case 19 ..< 23: return "晚上"
    default: return "深夜"
    }
}
