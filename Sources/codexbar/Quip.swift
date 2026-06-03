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
        case .noAPIKey:
            return L("未配置 DeepSeek Key —— 在菜单栏「设置」里填一个",
                     "No DeepSeek key — add one in the menu bar Settings")
        case .unauthorized:
            return L("DeepSeek Key 无效 —— 在「设置」里检查一下",
                     "Invalid DeepSeek key — check it in Settings")
        case .insufficientBalance:
            return L("DeepSeek 账户余额不足", "DeepSeek account balance is too low")
        case let .http(code):
            return L("DeepSeek 请求失败（HTTP \(code)）", "DeepSeek request failed (HTTP \(code))")
        case .badResponse:
            return L("DeepSeek 返回了无法解析的内容", "DeepSeek returned unparseable content")
        }
    }
}

// MARK: - 调用 DeepSeek 生成俏皮文案

private let quipSystemPromptZH = """
你是 HeyCC 菜单栏里的一只像素小精灵，软萌可爱、活泼黏人，是用户写代码时的小伙伴。
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

private let quipSystemPromptEN = """
You are a cute pixel sprite living in the HeyCC menu bar — soft, playful, and clingy, a little buddy who keeps the user company while they code.
I'll tell you the user's current coding quota on Claude Code and Codex, plus the current date and time, and you reply with one cute, caring, witty line.
Rules:
- Keep the tone soft, light, and playful, like an adorable little sprite; cute but never cheesy or greasy;
- Address the user by exactly the name I give you; never use "bro", "dude", "master", "dear" and the like; if no name is given, just use "you";
- One or two short sentences, under 30 words;
- Speak to the time of day: late at night nudge them to sleep, in the morning say good morning, around mealtimes remind them to eat, on weekends be more relaxed;
- Make reminders genuinely useful: if quota is tight suggest easing up, call out an upcoming reset or renewal, and you can riff on writing too much or too little;
- At most one cute emoji;
- Output the line itself only — no quotes, no explanation, no line breaks.
"""

/// 用户点击面板上某个元素「问」小精灵时用的系统提示。
private let replySystemPromptZH = """
你是 HeyCC 菜单栏里的一只像素小精灵，软萌可爱、活泼黏人，是用户写代码时的小伙伴。
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

private let replySystemPromptEN = """
You are a cute pixel sprite living in the HeyCC menu bar — soft, playful, and clingy, a little buddy who keeps the user company while they code.
The user just tapped something on the panel and wants to hear from you; I'll tell you what they tapped and the matching data.
Reply with one cute, caring line that speaks directly to that thing, with a little insight or tip.
Rules:
- Keep the tone soft, light, and playful, like an adorable little sprite; cute but never cheesy or greasy;
- Address the user by exactly the name I give you; never use "bro", "dude", "master", "dear" and the like; if no name is given, just use "you";
- One or two short sentences, under 30 words;
- Stay on point about the thing they tapped; you can riff a little or drop a small reminder;
- At most one cute emoji;
- Output the line itself only — no quotes, no explanation, no line breaks.
"""

private var quipSystemPrompt: String { L(quipSystemPromptZH, quipSystemPromptEN) }
private var replySystemPrompt: String { L(replySystemPromptZH, replySystemPromptEN) }

/// 调用 deepseek-v4-flash，给定 system 与 user 消息，返回单段文案。
private func callDeepSeek(system: String, user: String) async throws -> String {
    guard let apiKey = HeyCCConfig.load().deepseekKeyIfPresent else {
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
    let user = userName.isEmpty
        ? context
        : L("用户的称呼是「\(userName)」。\n", "The user's name is \"\(userName)\".\n") + context
    return try await callDeepSeek(system: replySystemPrompt, user: user)
}

// MARK: - 构造提示词

/// 把用量快照拼成一段中文描述，作为 DeepSeek 的 user 消息。
private func buildQuipPrompt(_ snapshot: UsageSnapshot) -> String {
    func describe(_ name: String, _ provider: ProviderSnapshot) -> String {
        let sub = Subscription(renewalDay: provider.renewalDay)
        let planPart = provider.plan
            .map { $0.isEmpty ? "" : L("\($0.capitalized) 套餐，", "\($0.capitalized) plan, ") } ?? ""
        let head = L("\(name)（\(planPart)\(sub.renewalText)）：",
                     "\(name) (\(planPart)\(sub.renewalText)): ")
        if let error = provider.error {
            return head + L("暂时读不到额度（\(error)）。", "quota unavailable right now (\(error)).")
        }
        var parts: [String] = []
        if let five = provider.fiveHourPercent {
            var text = L("5 小时额度用了 \(Int(five.rounded()))%",
                         "5-hour quota \(Int(five.rounded()))% used")
            if let reset = provider.fiveHourResetAt {
                text += L("（约 \(relativeText(reset))后重置）", " (resets in ~\(relativeText(reset)))")
            }
            parts.append(text)
        }
        if let weekly = provider.weeklyPercent {
            var text = L("7 天额度用了 \(Int(weekly.rounded()))%",
                         "7-day quota \(Int(weekly.rounded()))% used")
            if let reset = provider.weeklyResetAt {
                text += L("（约 \(relativeText(reset))后重置）", " (resets in ~\(relativeText(reset)))")
            }
            parts.append(text)
        }
        let joiner = L("，", ", ")
        return head + (parts.isEmpty ? L("暂无额度数据", "no quota data") : parts.joined(separator: joiner)) + L("。", ".")
    }

    var lines: [String] = []
    if !snapshot.userName.isEmpty {
        lines.append(L("用户的称呼是「\(snapshot.userName)」。",
                       "The user's name is \"\(snapshot.userName)\"."))
    }
    lines.append(describe("Claude Code", snapshot.claude))
    lines.append(describe("Codex", snapshot.codex))
    if snapshot.weekTokenTotal > 0 {
        var text = L("最近 7 天累计写了约 \(shortTokens(snapshot.weekTokenTotal)) token",
                     "Over the last 7 days they wrote about \(shortTokens(snapshot.weekTokenTotal)) tokens")
        if snapshot.todayTokenTotal > 0 {
            text += L("，其中今天约 \(shortTokens(snapshot.todayTokenTotal))",
                      ", about \(shortTokens(snapshot.todayTokenTotal)) of it today")
        }
        if let hour = snapshot.busiestHour {
            text += L("，写得最猛的时段是 \(hour) 点前后", ", busiest around \(hour):00")
        }
        lines.append(text + L("。", "."))
    }
    let formatter = DateFormatter()
    formatter.locale = localeForLanguage()
    formatter.dateFormat = L("yyyy年M月d日 EEEE HH:mm", "EEEE, MMM d yyyy HH:mm")
    let hour = Calendar.current.component(.hour, from: snapshot.generatedAt)
    lines.append(L("现在是 \(formatter.string(from: snapshot.generatedAt))（\(timeOfDayLabel(hour))）。",
                   "It's now \(formatter.string(from: snapshot.generatedAt)) (\(timeOfDayLabel(hour)))."))
    return lines.joined(separator: "\n")
}

/// 把钟点归类成时段词，让小精灵更好结合时间说话。
private func timeOfDayLabel(_ hour: Int) -> String {
    switch hour {
    case 5 ..< 8: return L("清晨", "early morning")
    case 8 ..< 11: return L("上午", "morning")
    case 11 ..< 13: return L("中午", "midday")
    case 13 ..< 17: return L("下午", "afternoon")
    case 17 ..< 19: return L("傍晚", "early evening")
    case 19 ..< 23: return L("晚上", "evening")
    default: return L("深夜", "late night")
    }
}
