import Foundation

/// 界面语言。中文为默认；可在「设置」里切换到英文。
enum AppLanguage: String, Sendable, CaseIterable {
    case zh
    case en

    /// 设置里切换控件上的短名。
    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

/// 当前界面语言。仅在主线程（配置加载/保存时）写入，其余各处只读；
/// 一次原子的枚举读写竞争是良性的，故用 nonisolated(unsafe) 让任意上下文都能取用。
nonisolated(unsafe) var appLanguage: AppLanguage = .en

/// 按当前界面语言二选一。所有面向用户的文案都走它，把中英文就近写在调用处。
func L(_ zh: String, _ en: String) -> String {
    appLanguage == .en ? en : zh
}

/// 当前语言对应的 Locale —— 给日期格式化器用，让「周三」「Wed」各从其所。
func localeForLanguage() -> Locale {
    Locale(identifier: appLanguage == .en ? "en_US" : "zh_CN")
}
