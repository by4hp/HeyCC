import Foundation

// MARK: - 模型

struct UsageWindow: Sendable {
    var percent: Double
    var resetAt: Date?
}

struct ClaudeUsage: Sendable {
    var plan: String?
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
}

struct CodexUsage: Sendable {
    var plan: String?
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
}

enum UsageError: LocalizedError, Sendable {
    case notLoggedIn(String)
    case unauthorized(String)
    case rateLimited(String, retryAfter: TimeInterval?)
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case let .notLoggedIn(message): return message
        case let .unauthorized(message): return message
        case let .rateLimited(who, retryAfter):
            if let retryAfter, retryAfter > 0 {
                let secs = Int(retryAfter.rounded(.up))
                return "\(who) 用量接口繁忙，\(secs) 秒后自动重试"
            }
            return "\(who) 用量接口繁忙，稍后自动重试"
        case let .http(code, who): return "\(who) 请求失败（HTTP \(code)）"
        case let .badResponse(message): return message
        }
    }

    /// 下一次刷新最早可以发生的相对延迟（仅限流时有意义）。
    var rateLimitDelay: TimeInterval? {
        if case let .rateLimited(_, retryAfter) = self { return retryAfter }
        return nil
    }
}

/// 解析 HTTP `Retry-After` 头：可能是秒数，也可能是 HTTP-date。
private func parseRetryAfter(_ raw: String?) -> TimeInterval? {
    guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    if let seconds = TimeInterval(raw) {
        return max(seconds, 0)
    }
    // HTTP-date 形如 "Wed, 21 Oct 2026 07:28:00 GMT"
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = formatter.date(from: raw) {
        return max(date.timeIntervalSinceNow, 0)
    }
    return nil
}

// MARK: - 凭证读取

private func homeURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
}

private struct CodexCreds {
    let accessToken: String
    let accountId: String?
}

private func loadCodexCreds() throws -> CodexCreds {
    let url = homeURL().appendingPathComponent(".codex/auth.json")
    guard let data = try? Data(contentsOf: url) else {
        throw UsageError.notLoggedIn("未找到 ~/.codex/auth.json，请先在终端运行 codex 登录")
    }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = root["tokens"] as? [String: Any],
          let token = tokens["access_token"] as? String, !token.isEmpty
    else {
        throw UsageError.notLoggedIn("无法解析 Codex 凭证，请重新运行 codex 登录")
    }
    return CodexCreds(accessToken: token, accountId: tokens["account_id"] as? String)
}

private struct ClaudeCreds {
    let accessToken: String
    /// 已格式化好的套餐名（如 "Max 5×"），读不到时为 nil。
    let plan: String?
}

private func loadClaudeCreds() throws -> ClaudeCreds {
    // 优先读 macOS 钥匙串（Claude Code 默认存这里）
    if let data = readClaudeKeychain(), let creds = parseClaudeCreds(data) {
        return creds
    }
    // 回退到凭证文件
    let url = homeURL().appendingPathComponent(".claude/.credentials.json")
    if let data = try? Data(contentsOf: url), let creds = parseClaudeCreds(data) {
        return creds
    }
    throw UsageError.notLoggedIn("未找到 Claude 凭证，请先在终端运行 claude 登录")
}

private func readClaudeKeychain() -> Data? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    do {
        try proc.run()
    } catch {
        return nil
    }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    let raw = out.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: raw, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else {
        return nil
    }
    return Data(text.utf8)
}

private func parseClaudeCreds(_ data: Data) -> ClaudeCreds? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    // 钥匙串结构：{ "claudeAiOauth": { accessToken, subscriptionType, rateLimitTier, … } }
    if let oauth = root["claudeAiOauth"] as? [String: Any],
       let token = oauth["accessToken"] as? String, !token.isEmpty
    {
        return ClaudeCreds(accessToken: token, plan: formatClaudePlan(
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String))
    }
    if let token = root["accessToken"] as? String, !token.isEmpty {
        return ClaudeCreds(accessToken: token, plan: formatClaudePlan(
            subscriptionType: root["subscriptionType"] as? String,
            rateLimitTier: root["rateLimitTier"] as? String))
    }
    return nil
}

/// 把 subscriptionType / rateLimitTier 拼成展示用套餐名。
/// 例：subscriptionType="max" + rateLimitTier="default_claude_max_5x" → "Max 5×"。
private func formatClaudePlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
    guard let raw = subscriptionType?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
        return nil
    }
    let name = raw.replacingOccurrences(of: "_", with: " ").capitalized
    if let tier = rateLimitTier,
       let range = tier.range(of: #"\d+x"#, options: .regularExpression)
    {
        return "\(name) \(tier[range].dropLast())×"
    }
    return name
}

// MARK: - 接口响应

private struct CodexResponse: Decodable {
    struct Window: Decodable {
        let used_percent: Double
        let reset_at: Double?
    }

    struct RateLimit: Decodable {
        let primary_window: Window?
        let secondary_window: Window?
    }

    let plan_type: String?
    let rate_limit: RateLimit?
}

private struct ClaudeResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    let five_hour: Window?
    let seven_day: Window?
}

private func parseISODate(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}

// MARK: - 拉取使用量

func fetchCodexUsage() async throws -> CodexUsage {
    let creds = try loadCodexCreds()
    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    request.httpMethod = "GET"
    request.timeoutInterval = 25
    request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(AppBrand.name, forHTTPHeaderField: "User-Agent")
    if let account = creds.accountId, !account.isEmpty {
        request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw UsageError.badResponse("Codex 返回异常响应")
    }
    if http.statusCode == 401 || http.statusCode == 403 {
        throw UsageError.unauthorized("Codex 登录已过期，请重新运行 codex")
    }
    if http.statusCode == 429 {
        let retryAfter = parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
        throw UsageError.rateLimited("Codex", retryAfter: retryAfter)
    }
    guard (200 ..< 300).contains(http.statusCode) else {
        throw UsageError.http(http.statusCode, "Codex")
    }

    let decoded = try JSONDecoder().decode(CodexResponse.self, from: data)
    func toWindow(_ window: CodexResponse.Window?) -> UsageWindow? {
        guard let window else { return nil }
        let reset = window.reset_at.map { Date(timeIntervalSince1970: $0) }
        return UsageWindow(percent: window.used_percent, resetAt: reset)
    }
    return CodexUsage(
        plan: decoded.plan_type,
        fiveHour: toWindow(decoded.rate_limit?.primary_window),
        weekly: toWindow(decoded.rate_limit?.secondary_window))
}

func fetchClaudeUsage() async throws -> ClaudeUsage {
    let creds = try loadClaudeCreds()
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    request.httpMethod = "GET"
    request.timeoutInterval = 25
    request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw UsageError.badResponse("Claude 返回异常响应")
    }
    if http.statusCode == 401 {
        throw UsageError.unauthorized("Claude 登录已过期，请重新运行 claude")
    }
    if http.statusCode == 429 {
        let retryAfter = parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
        throw UsageError.rateLimited("Claude", retryAfter: retryAfter)
    }
    guard (200 ..< 300).contains(http.statusCode) else {
        throw UsageError.http(http.statusCode, "Claude")
    }

    let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
    func toWindow(_ window: ClaudeResponse.Window?) -> UsageWindow? {
        guard let window else { return nil }
        return UsageWindow(percent: window.utilization ?? 0, resetAt: parseISODate(window.resets_at))
    }
    return ClaudeUsage(
        plan: creds.plan,
        fiveHour: toWindow(decoded.five_hour),
        weekly: toWindow(decoded.seven_day))
}
