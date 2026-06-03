import Foundation

/// 距离某时刻还有多久（粗粒度）。
func relativeText(_ date: Date) -> String {
    let seconds = Int(date.timeIntervalSinceNow)
    if seconds <= 0 { return L("即将", "soon") }
    let days = seconds / 86400
    let hours = (seconds % 86400) / 3600
    let minutes = (seconds % 3600) / 60
    if days > 0 { return L("\(days)天\(hours)时", "\(days)d \(hours)h") }
    if hours > 0 { return L("\(hours)时\(minutes)分", "\(hours)h \(minutes)m") }
    return L("\(minutes)分", "\(minutes)m")
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
