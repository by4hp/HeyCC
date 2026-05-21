import Foundation

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

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dee_codexbar/config.json")

    static let defaults = CodexBarConfig(
        deepseekAPIKey: "", claudeRenewalDay: 3, codexRenewalDay: 19, userName: "")

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
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 写回配置文件（带中文说明字段）。
    func save() throws {
        try FileManager.default.createDirectory(
            at: Self.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let root: [String: Any] = [
            "_说明": "deepseek_api_key 从 https://platform.deepseek.com/api_keys 获取；"
                + "*_renewal_day 是每月续费日；user_name 是小精灵对你的称呼。"
                + "也可在 App 菜单的「设置」里改。套餐等级由接口自动识别，无需配置。",
            "deepseek_api_key": deepseekAPIKey,
            "claude_renewal_day": claudeRenewalDay,
            "codex_renewal_day": codexRenewalDay,
            "user_name": userName,
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
