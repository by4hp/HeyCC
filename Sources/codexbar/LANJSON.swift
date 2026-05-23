import Foundation

// MARK: - JSON 序列化

/// 给移动端 `fetch('/api/snapshot.json')` 用的快照序列化。
func renderSnapshotJSON(_ s: LANSnapshot) -> Data {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]

    func providerDict(_ p: LANSnapshot.Provider) -> [String: Any] {
        var dict: [String: Any] = [
            "name": p.name,
            "plan": p.plan ?? NSNull(),
            "fiveHourPercent": p.fiveHourPercent ?? NSNull(),
            "weeklyPercent": p.weeklyPercent ?? NSNull(),
            "error": p.error ?? NSNull(),
        ]
        if let date = p.fiveHourResetAt {
            dict["fiveHourResetAt"] = iso.string(from: date)
            dict["fiveHourResetIn"] = Int(date.timeIntervalSinceNow)
        } else {
            dict["fiveHourResetAt"] = NSNull()
            dict["fiveHourResetIn"] = NSNull()
        }
        if let date = p.weeklyResetAt {
            dict["weeklyResetAt"] = iso.string(from: date)
            dict["weeklyResetIn"] = Int(date.timeIntervalSinceNow)
        } else {
            dict["weeklyResetAt"] = NSNull()
            dict["weeklyResetIn"] = NSNull()
        }
        return dict
    }

    let dailyArray: [[String: Any]] = s.dailyPoints.map { point in
        [
            "dayStart": iso.string(from: point.dayStart),
            "claude": point.claudeTokens,
            "codex": point.codexTokens,
            "total": point.total,
        ]
    }

    let root: [String: Any] = [
        "generatedAt": iso.string(from: s.generatedAt),
        "lastUpdatedAt": s.lastUpdated.map { iso.string(from: $0) } ?? NSNull(),
        "claude": providerDict(s.claude),
        "codex": providerDict(s.codex),
        "quip": s.quip ?? NSNull(),
        "hourlyTokens": s.hourlyTokens,
        "hourlyClaude": s.hourlyClaudeTokens,
        "hourlyCodex": s.hourlyCodexTokens,
        "daily": dailyArray,
        "todayTokens": s.todayTokens,
        "weekTokens": s.weekTokens,
        "renewal": [
            "claudeDay": s.claudeRenewalDay,
            "codexDay": s.codexRenewalDay,
            "claudeDaysLeft": daysUntilRenewal(day: s.claudeRenewalDay),
            "codexDaysLeft": daysUntilRenewal(day: s.codexRenewalDay),
        ],
        "petVariant": s.petVariant,
    ]

    guard let data = try? JSONSerialization.data(
        withJSONObject: root,
        options: [.prettyPrinted, .withoutEscapingSlashes])
    else {
        return Data("{}".utf8)
    }
    return data
}
