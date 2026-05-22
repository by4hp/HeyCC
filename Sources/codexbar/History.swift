import Foundation

// MARK: - 热力图模型

/// 某个自然小时内的 token 用量（按本地时区聚合）。
struct HourBucket: Sendable {
    let hourStart: Date
    var claudeTokens: Int
    var codexTokens: Int

    var total: Int { claudeTokens + codexTokens }
}

/// 最近 N 个自然日 × 24 小时的用量历史。
/// buckets 以「天为主序」排列：index = day * 24 + hour，day 0 为最早一天，day dayCount-1 为今天。
struct UsageHistory: Sendable {
    var buckets: [HourBucket]
    /// 覆盖的自然天数（buckets.count / 24）。
    var dayCount: Int
    /// 单个自然小时内的最大合计 token —— 判空与日志用。
    var maxHourTotal: Int

    static let empty = UsageHistory(buckets: [], dayCount: 0, maxHourTotal: 0)

    var hasData: Bool { maxHourTotal > 0 }

    func bucket(day: Int, hour: Int) -> HourBucket? {
        let index = day * 24 + hour
        return buckets.indices.contains(index) ? buckets[index] : nil
    }

    /// 某一天的起始时刻（用于行标签）。
    func dayStart(_ day: Int) -> Date? {
        bucket(day: day, hour: 0)?.hourStart
    }

    /// 某一天的 Claude token 合计。
    func dayClaude(_ day: Int) -> Int {
        (0 ..< 24).reduce(0) { $0 + (bucket(day: day, hour: $1)?.claudeTokens ?? 0) }
    }

    /// 某一天的 Codex token 合计。
    func dayCodex(_ day: Int) -> Int {
        (0 ..< 24).reduce(0) { $0 + (bucket(day: day, hour: $1)?.codexTokens ?? 0) }
    }

    /// 某一天的合计 token。
    func dayTotal(_ day: Int) -> Int { dayClaude(day) + dayCodex(day) }

    /// 某一天从 0 点到 hour 时（含）的累计 token —— 用于「今日 vs 日均」的同时段对比。
    func dayTotalUpToHour(_ day: Int, _ hour: Int) -> Int {
        let last = max(0, min(hour, 23))
        return (0 ... last).reduce(0) { $0 + (bucket(day: day, hour: $1)?.total ?? 0) }
    }

    /// 今天累计 token。
    var todayTotal: Int { dayCount > 0 ? dayTotal(dayCount - 1) : 0 }

    /// 最近 7 天累计 token。
    var lastWeekTotal: Int {
        guard dayCount > 0 else { return 0 }
        return (max(0, dayCount - 7) ..< dayCount).reduce(0) { $0 + dayTotal($1) }
    }
}

/// 历史回看天数：周视图取末 7 天，月视图取近 13 周（98 天含一周缓冲）。
let historyDayCount = 98

// MARK: - 扫描本地会话日志

/// 扫描 Claude 与 Codex 的本地会话日志，聚合最近 7 天每小时的「非缓存」token 用量。
/// 这是同步、可在后台线程调用的纯函数。
func scanUsageHistory() -> UsageHistory {
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: Date())
    guard let firstDay = calendar.date(
        byAdding: .day, value: -(historyDayCount - 1), to: startOfToday)
    else {
        return .empty
    }

    // 生成 historyDayCount * 24 个连续的本地整点桶
    var order: [Date] = []
    var claudeByHour: [Date: Int] = [:]
    var codexByHour: [Date: Int] = [:]
    for dayOffset in 0 ..< historyDayCount {
        guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: firstDay) else { continue }
        for hour in 0 ..< 24 {
            guard let slot = calendar.date(byAdding: .hour, value: hour, to: dayStart) else { continue }
            order.append(slot)
            claudeByHour[slot] = 0
            codexByHour[slot] = 0
        }
    }

    let isoFractional = ISO8601DateFormatter()
    isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoPlain = ISO8601DateFormatter()
    isoPlain.formatOptions = [.withInternetDateTime]
    func parseDate(_ text: String) -> Date? {
        isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }
    func hourSlot(of date: Date) -> Date? {
        calendar.dateInterval(of: .hour, for: date)?.start
    }

    let home = FileManager.default.homeDirectoryForCurrentUser

    // Claude：~/.claude/projects/<项目>/<会话>.jsonl
    let claudeRoot = home.appendingPathComponent(".claude/projects")
    for file in jsonlFiles(under: claudeRoot, modifiedAfter: firstDay) {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"assistant\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let timestamp = object["timestamp"] as? String,
                  let date = parseDate(timestamp),
                  let slot = hourSlot(of: date),
                  claudeByHour[slot] != nil,
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            let tokens = intValue(usage["input_tokens"])
                + intValue(usage["output_tokens"])
                + intValue(usage["cache_creation_input_tokens"])
            claudeByHour[slot, default: 0] += tokens
        }
    }

    // Codex：~/.codex/sessions/**/rollout-*.jsonl 与 archived_sessions
    let codexRoots = [
        home.appendingPathComponent(".codex/sessions"),
        home.appendingPathComponent(".codex/archived_sessions"),
    ]
    for root in codexRoots {
        for file in jsonlFiles(under: root, modifiedAfter: firstDay) {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.contains("token_count") else { continue }
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["type"] as? String == "event_msg",
                      let timestamp = object["timestamp"] as? String,
                      let date = parseDate(timestamp),
                      let slot = hourSlot(of: date),
                      codexByHour[slot] != nil,
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any]
                else { continue }
                let input = intValue(last["input_tokens"])
                let cached = intValue(last["cached_input_tokens"])
                let output = intValue(last["output_tokens"])
                codexByHour[slot, default: 0] += max(0, input - cached) + output
            }
        }
    }

    var buckets: [HourBucket] = []
    var maxTotal = 0
    for slot in order {
        let claude = claudeByHour[slot] ?? 0
        let codex = codexByHour[slot] ?? 0
        buckets.append(HourBucket(hourStart: slot, claudeTokens: claude, codexTokens: codex))
        maxTotal = max(maxTotal, claude + codex)
    }
    return UsageHistory(buckets: buckets, dayCount: historyDayCount, maxHourTotal: maxTotal)
}

// MARK: - 辅助

private func jsonlFiles(under directory: URL, modifiedAfter cutoff: Date) -> [URL] {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles])
    else {
        return []
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
        guard url.pathExtension == "jsonl" else { continue }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        if let modified = values?.contentModificationDate, modified < cutoff { continue }
        files.append(url)
    }
    return files
}

private func intValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let int = value as? Int { return int }
    if let double = value as? Double { return Int(double) }
    return 0
}
