import Foundation

/// 距离某时刻还有多久（中文，粗粒度）。
func relativeText(_ date: Date) -> String {
    let seconds = Int(date.timeIntervalSinceNow)
    if seconds <= 0 { return "即将" }
    let days = seconds / 86400
    let hours = (seconds % 86400) / 3600
    let minutes = (seconds % 3600) / 60
    if days > 0 { return "\(days)天\(hours)时" }
    if hours > 0 { return "\(hours)时\(minutes)分" }
    return "\(minutes)分"
}

/// token 数量缩写，如 12345 → "12.3k"。
func shortTokens(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
    return "\(count)"
}

/// HH:mm:ss 时钟文本。
func clockText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}
