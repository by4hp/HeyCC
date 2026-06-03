import Foundation

/// 每月续费日的日期计算。
/// 续费日来自配置（可在设置里改）；套餐名不在这里 —— 由接口/凭证自动识别。
struct Subscription: Sendable {
    /// 每月几号续费，1...31。
    let renewalDay: Int

    /// 下一次续费日期（含今天）。
    var nextRenewal: Date {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        var components = calendar.dateComponents([.year, .month], from: now)
        components.day = renewalDay
        components.hour = 0
        let thisMonth = calendar.date(from: components) ?? now
        if thisMonth >= today { return thisMonth }
        return calendar.date(byAdding: .month, value: 1, to: thisMonth) ?? thisMonth
    }

    /// 上一次续费日期（含今天）。
    var lastRenewal: Date {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        var components = calendar.dateComponents([.year, .month], from: now)
        components.day = renewalDay
        components.hour = 0
        let thisMonth = calendar.date(from: components) ?? now
        if thisMonth <= today { return thisMonth }
        return calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
    }

    /// 如「续费 6月3日 · 13 天后」。
    var renewalText: String {
        let calendar = Calendar.current
        let date = nextRenewal
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = localeForLanguage()
        formatter.dateFormat = L("M月d日", "MMM d")
        let dateString = formatter.string(from: date)
        if days <= 0 { return L("今日续费 · ", "Renews today · ") + dateString }
        return L("续费 \(dateString) · \(days) 天后",
                 "Renews \(dateString) · in \(days)d")
    }
}
