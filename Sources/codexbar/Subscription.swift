import Foundation

/// 订阅套餐与每月续费日。
struct Subscription: Sendable {
    let plan: String
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

    /// 如「续费 6月3日 · 13 天后」。
    var renewalText: String {
        let calendar = Calendar.current
        let date = nextRenewal
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        let dateString = formatter.string(from: date)
        if days <= 0 { return "今日续费 · " + dateString }
        return "续费 \(dateString) · \(days) 天后"
    }
}

let claudeSubscription = Subscription(plan: "5× Max", renewalDay: 3)
let codexSubscription = Subscription(plan: "Plus", renewalDay: 19)
