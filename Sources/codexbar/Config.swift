import Foundation

/// 悬浮窗图表里 Claude 与 Codex 用量的区分方式。
enum ChartProviderMode: String, Sendable, CaseIterable {
    /// 一张热力图，每格按当时主导的一方双色着色。
    case combined
    /// 一张热力图，顶部切换只看 Claude / Codex / 合计。
    case toggle

    /// 设置面板里展示的名字。
    var displayName: String {
        switch self {
        case .combined: return "双色合并"
        case .toggle: return "切换显示"
        }
    }
}

/// 悬浮窗图表的时间范围。
enum ChartRange: String, Sendable, CaseIterable {
    /// 最近 7 天 × 12 个 2 小时段。
    case week
    /// 最近 13 周（约近三个月），按天聚合、GitHub 贡献图样式。
    case month

    /// 图表顶部分段控件上的短名。
    var displayName: String {
        switch self {
        case .week: return "周"
        case .month: return "月"
        }
    }
}

/// 悬浮弹窗里供应商额度的展示口径（5 小时滚动额度 / 7 天周额度）。
enum QuotaWindow: String, Sendable, CaseIterable {
    /// 5 小时滚动额度。
    case fiveHour = "five_hour"
    /// 7 天 / 周额度。
    case weekly

    /// 面板顶部分段控件上的短名。
    var shortName: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "周"
        }
    }

    /// 供应商行里数值旁的小标签。
    var badge: String {
        switch self {
        case .fiveHour: return "5 小时"
        case .weekly: return "7 天"
        }
    }
}

/// 面板底部可选的像素宠物样式。
enum PetVariant: String, Sendable, CaseIterable {
    case mascot
    case flowerPortrait = "flower_portrait"
    case chibiPortrait = "chibi_portrait"
    case opossum

    var displayName: String {
        switch self {
        case .mascot: return "小精灵"
        case .flowerPortrait: return "花间像素人"
        case .chibiPortrait: return "卡通大头"
        case .opossum: return "负鼠"
        }
    }
}

/// CodexBar 个人版的本地配置，存于 ~/.dee_codexbar/config.json。
/// 用独立目录，避免和原版 CodexBar 的 ~/.codexbar/ 撞文件。
/// 套餐等级不在这里 —— 由各家接口/凭证自动识别。
struct CodexBarConfig: Sendable {
    /// DeepSeek API Key，可为空字符串（空 = 关闭俏皮总结）。
    var deepseekAPIKey: String
    /// Claude 每月续费日，1...31。
    var claudeRenewalDay: Int
    /// Codex 每月续费日，1...31。
    var codexRenewalDay: Int
    /// 用户希望小精灵怎么称呼自己，可为空。
    var userName: String
    /// 悬浮窗图表里 Claude / Codex 的区分方式。
    var chartProviderMode: ChartProviderMode
    /// 悬浮窗图表默认的时间范围（也可在图表顶部切换）。
    var chartRange: ChartRange
    /// 悬浮弹窗供应商行默认的额度口径（也可在面板顶部切换）。
    var quotaWindow: QuotaWindow
    /// 面板底部像素宠物的形象。
    var petVariant: PetVariant

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dee_codexbar/config.json")

    static let defaults = CodexBarConfig(
        deepseekAPIKey: "", claudeRenewalDay: 3, codexRenewalDay: 19, userName: "",
        chartProviderMode: .combined, chartRange: .week, quotaWindow: .weekly,
        petVariant: .chibiPortrait)

    /// API Key 非空时返回，否则 nil。
    var deepseekKeyIfPresent: String? {
        deepseekAPIKey.isEmpty ? nil : deepseekAPIKey
    }

    /// 读取配置；文件缺失或字段不全时用默认值补齐，始终返回可用配置。
    static func load() -> CodexBarConfig {
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return defaults }
        let key = (root["deepseek_api_key"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexBarConfig(
            deepseekAPIKey: key,
            claudeRenewalDay: clampDay(root["claude_renewal_day"], fallback: 3),
            codexRenewalDay: clampDay(root["codex_renewal_day"], fallback: 19),
            userName: (root["user_name"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            chartProviderMode: ChartProviderMode(rawValue: root["chart_provider_mode"] as? String ?? "")
                ?? .combined,
            chartRange: ChartRange(rawValue: root["chart_range"] as? String ?? "") ?? .week,
            quotaWindow: QuotaWindow(rawValue: root["quota_window"] as? String ?? "") ?? .weekly,
            petVariant: PetVariant(rawValue: root["pet_variant"] as? String ?? "") ?? .chibiPortrait)
    }

    /// 写回配置文件（带中文说明字段）。
    func save() throws {
        try FileManager.default.createDirectory(
            at: Self.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let root: [String: Any] = [
            "_说明": "deepseek_api_key 从 https://platform.deepseek.com/api_keys 获取；"
                + "*_renewal_day 是每月续费日；user_name 是小精灵对你的称呼；"
                + "chart_provider_mode 是图表区分方式（combined/toggle）；"
                + "chart_range 是图表默认时间范围（week/month）；"
                + "quota_window 是悬浮弹窗额度口径（five_hour/weekly）；"
                + "pet_variant 是底部像素宠物形象（mascot/flower_portrait/chibi_portrait/opossum）。"
                + "也可在 App 菜单的「设置」里改。套餐等级由接口自动识别，无需配置。",
            "deepseek_api_key": deepseekAPIKey,
            "claude_renewal_day": claudeRenewalDay,
            "codex_renewal_day": codexRenewalDay,
            "user_name": userName,
            "chart_provider_mode": chartProviderMode.rawValue,
            "chart_range": chartRange.rawValue,
            "quota_window": quotaWindow.rawValue,
            "pet_variant": petVariant.rawValue,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: Self.path)
    }

    /// 首次运行写出一份默认配置，方便填 Key；已存在则不动。
    static func createTemplateIfMissing() {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        try? defaults.save()
    }
}

/// 把任意类型的「日」值收敛到 1...31，无法解析时用 fallback。
private func clampDay(_ value: Any?, fallback: Int) -> Int {
    let day: Int
    switch value {
    case let number as NSNumber: day = number.intValue
    case let int as Int: day = int
    case let text as String: day = Int(text) ?? fallback
    default: return fallback
    }
    return min(max(day, 1), 31)
}
