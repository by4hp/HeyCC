import AppKit
import SwiftUI

// MARK: - 共享状态

@MainActor
final class PanelModel: ObservableObject {
    @Published var claude = ProviderState.initial(name: "Claude Code", prefix: "Cl")
    @Published var codex = ProviderState.initial(name: "Codex", prefix: "Cx")
    @Published var history = UsageHistory.empty
    @Published var lastUpdated: Date?
    /// 每月续费日，来自配置，可在「设置」里改。
    @Published var claudeRenewalDay = 3
    @Published var codexRenewalDay = 19
    /// DeepSeek 生成的俏皮总结；尚未生成时为 nil。
    @Published var quip: String?
    /// 文案生成失败时的错误描述。
    @Published var quipError: String?
    /// 正在调用 DeepSeek 生成文案。
    @Published var quipLoading = false
    @Published var expanded = false
    /// 鼠标相对悬浮面板中心的水平位置，-1 看左、1 看右；由 NotchController 轮询更新。
    @Published var petGaze: CGFloat = 0
    /// 戳一下宠物时触发（由 AppDelegate 注入：刷新俏皮总结）。
    var onPokePet: (() -> Void)?
    /// 点击面板元素「问」小精灵时触发（由 AppDelegate 注入：调 DeepSeek 回应）。
    var onAsk: ((String) -> Void)?
    /// 用户希望被称呼的名字（喂给俏皮总结），来自配置。
    var userName = ""
    /// 当前屏幕刘海尺寸，面板顶部用它在刘海两侧排版。
    @Published var notchHeight: CGFloat = 38
    @Published var notchWidth: CGFloat = 220
    /// 图表时间范围（周/月），来自配置、可在图表顶部切换。
    @Published var chartRange: ChartRange = .week
    /// 图表里 Claude / Codex 的区分方式，来自配置、在「设置」里改。
    @Published var chartProviderMode: ChartProviderMode = .combined
    /// 供应商行展示 5 小时还是周额度，来自配置、可在面板顶部切换。
    @Published var quotaWindow: QuotaWindow = .weekly
    /// 面板底部的像素宠物样式，来自配置、在「设置」里改。
    @Published var petVariant: PetVariant = .mascot
    /// 在图表顶部切换时间范围时触发（由 AppDelegate 注入：写回配置）。
    var onChartRangeChanged: ((ChartRange) -> Void)?
    /// 在面板顶部切换额度口径时触发（由 AppDelegate 注入：写回配置）。
    var onQuotaWindowChanged: ((QuotaWindow) -> Void)?
}

// MARK: - 尺寸常量

enum NotchMetrics {
    static let panelWidth: CGFloat = 392
    /// 刘海下方的内容区高度（窗口总高 = 刘海高度 + 此值）。
    /// 留足空间让周/月热力图的方块足够大、能舒展铺开。
    static let contentHeight: CGFloat = 476
    static let cornerRadius: CGFloat = 24
}

private let claudeRGB = (r: 0.86, g: 0.47, b: 0.24)
private let codexRGB = (r: 0.30, g: 0.80, b: 0.74)
private let claudeAccent = Color(red: claudeRGB.r, green: claudeRGB.g, blue: claudeRGB.b)
private let codexAccent = Color(red: codexRGB.r, green: codexRGB.g, blue: codexRGB.b)

/// 在 Codex 青 ↔ Claude 橙 之间按 Claude 占比插值，用于「双色合并」热力图。
private func blendAccent(claudeRatio: Double) -> Color {
    let t = min(max(claudeRatio, 0), 1)
    return Color(
        red: codexRGB.r + (claudeRGB.r - codexRGB.r) * t,
        green: codexRGB.g + (claudeRGB.g - codexRGB.g) * t,
        blue: codexRGB.b + (claudeRGB.b - codexRGB.b) * t)
}

// MARK: - 面板根视图

struct NotchPanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let totalHeight = model.notchHeight + NotchMetrics.contentHeight
        VStack(spacing: 0) {
            panelCard(totalHeight: totalHeight)
                .frame(height: model.expanded ? totalHeight : 0, alignment: .top)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: NotchMetrics.cornerRadius,
                        bottomTrailingRadius: NotchMetrics.cornerRadius,
                        topTrailingRadius: 0))
                .opacity(model.expanded ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(width: NotchMetrics.panelWidth, height: totalHeight, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: model.expanded)
    }

    private func panelCard(totalHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            notchBar
            VStack(alignment: .leading, spacing: 10) {
                ProviderRow(
                    state: model.claude,
                    subscription: Subscription(renewalDay: model.claudeRenewalDay),
                    window: model.quotaWindow,
                    accent: claudeAccent)
                ProviderRow(
                    state: model.codex,
                    subscription: Subscription(renewalDay: model.codexRenewalDay),
                    window: model.quotaWindow,
                    accent: codexAccent)
                InsightStrip(model: model)
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                ChartSection(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                QuipFooter(model: model)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .frame(
            width: NotchMetrics.panelWidth,
            height: totalHeight,
            alignment: .top)
        .background(Color.black)
    }

    /// 刘海一行：左耳放 5h/周额度切换、右耳放更新时间，中间避开物理刘海。
    private var notchBar: some View {
        HStack(spacing: 0) {
            MiniSegmented(
                items: QuotaWindow.allCases.map { (value: $0, label: $0.shortName) },
                isActive: { $0 == model.quotaWindow }) { picked in
                    model.quotaWindow = picked
                    model.onQuotaWindowChanged?(picked)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("切换 5 小时 / 周额度")
            Spacer()
                .frame(width: model.notchWidth + 8)
            Group {
                if let updated = model.lastUpdated {
                    Text("更新 " + clockText(updated))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: model.notchHeight)
    }

}

// MARK: - 底部俏皮总结

/// 刘海面板底部：像素宠物 + DeepSeek 俏皮总结。
/// 宠物会浮动眨眼，文案以打字机逐字浮现，像宠物在对话气泡里说话。
struct QuipFooter: View {
    @ObservedObject var model: PanelModel

    private static let footerHeight: CGFloat = 88
    private static let bubbleHeight: CGFloat = 60

    @State private var displayed = ""
    @State private var shown = ""
    @State private var loadingLine = "让我瞅瞅你今天写了多少…"
    @State private var thinkingHold = false
    @State private var thinkingTask: Task<Void, Never>?
    @State private var celebrating = false
    @State private var celebrationTask: Task<Void, Never>?

    /// 生成文案期间气泡里的台词 —— 由小精灵第一人称说出，别用「正在生成」这类旁白。
    private static let loadingLines = [
        "让我瞅瞅你今天写了多少…",
        "唔…我看看你的额度哈…",
        "等等，我扒拉一下数据…",
        "我盘盘你这周的账哦…",
        "让我眯起眼睛看看哈…",
    ]

    private enum Mode { case loading, quip, error }
    private var mode: Mode {
        if model.quipLoading { return .loading }
        if let quip = model.quip, !quip.isEmpty { return .quip }
        if model.quipError != nil { return .error }
        return .loading
    }

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            PixelPet(
                pixel: 2.5,
                mood: petMood,
                variant: model.petVariant,
                gaze: model.petGaze,
                gazeActive: model.expanded,
                onPoke: { model.onPokePet?() })
            bubble
        }
        .frame(height: Self.footerHeight)
        .task(id: typeKey) { await typewriter() }
        .onChange(of: model.quipLoading) { loading in
            holdThinkingIfNeeded(loading)
        }
        .onChange(of: model.quip ?? "") { quip in
            celebrateIfNeeded(quip)
        }
    }

    /// 生成文案时小精灵进入思考态；报错/额度临界时优先示警；新文案生成完短暂庆祝；深夜会打盹。
    private var petMood: PetMood {
        if model.quipLoading || thinkingHold { return .thinking }
        if model.claude.error != nil || model.codex.error != nil { return .critical }
        let claude = model.claude.fiveHour?.percent ?? 0
        let codex = model.codex.fiveHour?.percent ?? 0
        let maxPercent = max(claude, codex)
        if maxPercent >= 95 { return .critical }
        if maxPercent >= 85 { return .worried }
        if celebrating { return .celebrate }
        return isLateNight ? .sleepy : .idle
    }

    /// DeepSeek 失败太快时，仍保留一点思考态，避免肉眼看不到。
    private func holdThinkingIfNeeded(_ loading: Bool) {
        thinkingTask?.cancel()
        if loading {
            thinkingHold = true
            return
        }
        thinkingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled {
                thinkingHold = false
            }
        }
    }

    /// 新俏皮话出现时，让小精灵短暂庆祝一下。
    private func celebrateIfNeeded(_ quip: String) {
        guard !quip.isEmpty, !model.quipLoading else { return }
        celebrationTask?.cancel()
        celebrating = true
        celebrationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            if !Task.isCancelled {
                celebrating = false
            }
        }
    }

    private var isLateNight: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 6 || hour >= 23
    }

    /// 宠物的对话气泡，按状态切换文字。
    @ViewBuilder private var bubble: some View {
        switch mode {
        case .loading:
            // 生成中：文字按正弦呼吸。
            TimelineView(.animation) { context in
                let wave = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2.6)
                speechBubble(loadingLine, opacity: 0.32 + 0.26 * wave)
            }
        case .quip:
            speechBubble(displayed, opacity: 0.74)
        case .error:
            speechBubble(model.quipError ?? "", opacity: 0.42)
        }
    }

    /// 半透明圆角对话气泡。
    private func speechBubble(_ text: String, opacity: Double) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(opacity))
            .lineSpacing(3)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(height: Self.bubbleHeight, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)))
    }

    /// task 的触发键：生成中用固定值，出文案后变成文案本身，从而重新触发打字机。
    private var typeKey: String {
        model.quipLoading ? "\u{1}loading" : (model.quip ?? "\u{1}none")
    }

    /// 逐字浮现新文案。
    private func typewriter() async {
        guard !model.quipLoading else {
            shown = ""
            loadingLine = Self.loadingLines.randomElement() ?? loadingLine
            return
        }
        guard let quip = model.quip, !quip.isEmpty else { return }
        guard quip != shown else {
            displayed = quip
            return
        }
        shown = quip
        displayed = ""
        for character in quip {
            if Task.isCancelled { return }
            displayed.append(character)
            try? await Task.sleep(for: .milliseconds(33))
        }
        displayed = quip
    }
}

// MARK: - 供应商行

struct ProviderRow: View {
    let state: ProviderState
    let subscription: Subscription
    /// 当前展示 5 小时还是周额度。
    let window: QuotaWindow
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Circle()
                .fill(accent)
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(state.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    if let plan = state.plan, !plan.isEmpty {
                        Text(plan.capitalized)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    Spacer()
                    Text(window.badge)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(valueText)
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(valueColor)
                }
                ProgressBar(fraction: fraction, color: valueColor)
                Text(usageLine)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                Text(subscription.renewalText)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.34))
                    .lineLimit(1)
            }
        }
    }

    /// 当前口径选中的额度窗口。
    private var activeWindow: UsageWindow? {
        window == .weekly ? state.weekly : state.fiveHour
    }

    /// 另一口径的额度窗口，作 usageLine 里的补充信息。
    private var otherWindow: UsageWindow? {
        window == .weekly ? state.fiveHour : state.weekly
    }

    private var activePercent: Double? { activeWindow?.percent }
    private var fraction: Double { min(max((activePercent ?? 0) / 100, 0), 1) }

    private var valueText: String {
        if state.isLoading { return "…" }
        if let activePercent { return "\(Int(activePercent.rounded()))%" }
        return "—"
    }

    private var valueColor: Color {
        guard let activePercent else { return .white.opacity(0.4) }
        switch activePercent {
        case ..<50: return .white
        case ..<80: return Color(red: 1, green: 0.72, blue: 0.24)
        default: return Color(red: 1, green: 0.40, blue: 0.36)
        }
    }

    private var usageLine: String {
        if state.isLoading { return "读取中…" }
        if let error = state.error { return error }
        var parts: [String] = []
        if let reset = activeWindow?.resetAt {
            parts.append((window == .weekly ? "周额度重置 " : "5h 重置 ") + relativeText(reset))
        }
        if let other = otherWindow?.percent {
            parts.append((window == .weekly ? "5h 用量 " : "周用量 ")
                + "\(Int(other.rounded()))%")
        }
        return parts.isEmpty ? "暂无数据" : parts.joined(separator: "  ·  ")
    }
}

struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: max(3, geo.size.width * fraction))
            }
        }
        .frame(height: 5)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fraction)
    }
}

// MARK: - 洞察条

/// 一次燃尽预测的结果。
private struct BurnEstimate {
    let name: String
    /// 距离触顶（100%）还有多久。
    let timeToExhaust: TimeInterval
    /// 距离窗口重置还有多久。
    let resetIn: TimeInterval
    /// 是否会在重置前就见底。
    let exhaustsBeforeReset: Bool
}

/// 供应商行下方的一行小字：左为「今日脉搏」，右为「燃尽预测」。
struct InsightStrip: View {
    @ObservedObject var model: PanelModel

    private static let upColor = Color(red: 1, green: 0.72, blue: 0.30)
    private static let downColor = Color(red: 0.45, green: 0.78, blue: 0.95)
    private static let safeColor = Color(red: 0.46, green: 0.83, blue: 0.58)
    private static let warnColor = Color(red: 1, green: 0.72, blue: 0.24)
    private static let urgentColor = Color(red: 1, green: 0.40, blue: 0.36)

    var body: some View {
        HStack(spacing: 8) {
            pulse
                .contentShape(Rectangle())
                .onTapGesture { model.onAsk?(pulseQuestion) }
                .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
            Spacer(minLength: 6)
            burn
                .contentShape(Rectangle())
                .onTapGesture { model.onAsk?(burnQuestion) }
                .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
        }
        .font(.system(size: 9.5).monospacedDigit())
        .lineLimit(1)
        .frame(height: 17)
    }

    // MARK: 今日脉搏

    private var pulse: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill").font(.system(size: 8))
            Text("今日 \(shortTokens(todaySoFar))")
                .foregroundStyle(.white.opacity(0.55))
            if let delta = todayDelta {
                let up = delta >= 0
                Text("\(up ? "↑" : "↓")\(Int(abs(delta).rounded()))%")
                    .foregroundStyle(up ? Self.upColor : Self.downColor)
            }
        }
        .foregroundStyle(.white.opacity(0.4))
        .help("今日累计用量，与近 7 天同一时段的均值相比 · 点我问问小精灵")
    }

    /// 今日截至当前小时的累计 token。
    private var todaySoFar: Int {
        let history = model.history
        guard history.dayCount > 0 else { return 0 }
        return history.dayTotalUpToHour(history.dayCount - 1, currentHour)
    }

    /// 今日 vs 近 7 天同时段均值的涨跌百分比；样本不足时为 nil。
    private var todayDelta: Double? {
        let history = model.history
        guard history.dayCount >= 8 else { return nil }
        let today = history.dayCount - 1
        let avg = (1 ... 7).reduce(0) {
            $0 + history.dayTotalUpToHour(today - $1, currentHour)
        } / 7
        guard avg > 0 else { return nil }
        return (Double(todaySoFar) - Double(avg)) / Double(avg) * 100
    }

    private var currentHour: Int {
        Calendar.current.component(.hour, from: Date())
    }

    /// 点击今日脉搏时抛给小精灵的话。
    private var pulseQuestion: String {
        var s = "用户点了面板上的『今日脉搏』：今天到现在累计约 \(shortTokens(todaySoFar)) token"
        if let delta = todayDelta {
            let pct = Int(abs(delta).rounded())
            s += delta >= 0 ? "，比近 7 天同时段均值高 \(pct)%" : "，比近 7 天同时段均值低 \(pct)%"
        }
        return s + "。"
    }

    // MARK: 燃尽预测

    @ViewBuilder private var burn: some View {
        if let worst = worstBurn {
            let urgent = worst.timeToExhaust < worst.resetIn * 0.5
            Label {
                Text("\(worst.name) \(windowWord)约 "
                    + relativeText(Date().addingTimeInterval(worst.timeToExhaust))
                    + " 后见底")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8.5))
            }
            .foregroundStyle(urgent ? Self.urgentColor : Self.warnColor)
            .help("按本窗口当前的消耗速度线性外推 · 点我问问小精灵")
        } else if hasWindowData {
            Label {
                Text("额度够用到重置")
            } icon: {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 8.5))
            }
            .foregroundStyle(Self.safeColor)
            .help("按当前消耗速度，本窗口额度够撑到重置 · 点我问问小精灵")
        }
    }

    private var windowWord: String {
        model.quotaWindow == .weekly ? "周额度" : "5h 额度"
    }

    /// 点击燃尽预测时抛给小精灵的话。
    private var burnQuestion: String {
        if let worst = worstBurn {
            let when = relativeText(Date().addingTimeInterval(worst.timeToExhaust))
            return "用户点了面板上的『燃尽预测』：按当前消耗速度，"
                + "\(worst.name) 的\(windowWord)大约 \(when) 后见底，会赶在重置前用完。"
        }
        return "用户点了面板上的『燃尽预测』：按当前消耗速度，"
            + "Claude 和 Codex 的\(windowWord)目前都够撑到重置。"
    }

    private var hasWindowData: Bool {
        burnWindow(model.claude) != nil || burnWindow(model.codex) != nil
    }

    private func burnWindow(_ state: ProviderState) -> UsageWindow? {
        model.quotaWindow == .weekly ? state.weekly : state.fiveHour
    }

    /// 会提前见底的供应商里，挑最早见底的那个；都安全则为 nil。
    private var worstBurn: BurnEstimate? {
        [burnEstimate(model.claude), burnEstimate(model.codex)]
            .compactMap { $0 }
            .filter { $0.exhaustsBeforeReset }
            .min { $0.timeToExhaust < $1.timeToExhaust }
    }

    /// 按当前窗口里的消耗速度，线性外推这一供应商何时触顶。
    private func burnEstimate(_ state: ProviderState) -> BurnEstimate? {
        guard let window = burnWindow(state), let resetAt = window.resetAt else { return nil }
        let windowLength: TimeInterval = model.quotaWindow == .weekly ? 7 * 86400 : 5 * 3600
        let now = Date()
        let resetIn = resetAt.timeIntervalSince(now)
        guard resetIn > 0 else { return nil }                       // 数据过期
        let elapsed = windowLength - resetIn
        guard elapsed > max(60, windowLength * 0.06) else { return nil } // 窗口刚开，样本太少
        let percent = window.percent
        guard percent > 0 else {
            return BurnEstimate(name: state.name, timeToExhaust: .infinity,
                                resetIn: resetIn, exhaustsBeforeReset: false)
        }
        let rate = percent / elapsed                                // 每秒消耗的百分比
        let timeToExhaust = max(0, (100 - percent) / rate)
        return BurnEstimate(name: state.name, timeToExhaust: timeToExhaust,
                            resetIn: resetIn, exhaustsBeforeReset: timeToExhaust < resetIn)
    }
}

// MARK: - 迷你分段控件

/// 通用迷你分段控件：胶囊高亮当前项；面板顶部的额度切换与图表头部的范围切换共用。
struct MiniSegmented<T: Equatable>: View {
    let items: [(value: T, label: String)]
    let isActive: (T) -> Bool
    let onPick: (T) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let active = isActive(item.value)
                Button { onPick(item.value) } label: {
                    Text(item.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(active ? 0.95 : 0.4))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.white.opacity(active ? 0.16 : 0)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 图表区块

/// 热力图要展示的数据序列。
enum ChartSeries: Sendable, Equatable {
    /// Claude 与 Codex 合计（双色着色）。
    case both
    /// 只看 Claude。
    case claude
    /// 只看 Codex。
    case codex
}

/// 月视图热力图上要圈出的一次续费（上一次或下一次）。
struct RenewalMark {
    /// 续费发生的日期。
    let date: Date
    /// 供应商主色，用来画标注环。
    let accent: Color
    /// 供应商名，进格子的悬停提示。
    let label: String
    /// true = 已发生的上一次续费（实线环）；false = 即将到来的下一次续费（虚线环）。
    let isPast: Bool
}

/// 刘海面板里的用量图表：顶部「周 / 月」切换 + 按设置区分 Claude / Codex 的热力图。
struct ChartSection: View {
    @ObservedObject var model: PanelModel
    /// 「切换显示」模式下当前选中的序列。
    @State private var toggleSeries: ChartSeries = .both

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if model.chartProviderMode == .toggle {
                providerSelector
            }
            chartBody
        }
    }

    private var range: ChartRange { model.chartRange }

    /// Claude / Codex 的续费位置，月视图里圈出来：
    /// 上一次（实线环）总会落在窗口内；下一次（虚线环）只有落进可视网格时才画得出。
    private var renewalMarks: [RenewalMark] {
        let providers: [(day: Int, accent: Color, label: String)] = [
            (model.claudeRenewalDay, claudeAccent, "Claude"),
            (model.codexRenewalDay, codexAccent, "Codex"),
        ]
        let calendar = Calendar.current
        var marks: [RenewalMark] = []
        for provider in providers {
            let sub = Subscription(renewalDay: provider.day)
            marks.append(RenewalMark(date: sub.lastRenewal, accent: provider.accent,
                                     label: provider.label, isPast: true))
            // 今天恰为续费日时上一次/下一次同日，只保留上一次，避免同格双环。
            if !calendar.isDate(sub.nextRenewal, inSameDayAs: sub.lastRenewal) {
                marks.append(RenewalMark(date: sub.nextRenewal, accent: provider.accent,
                                         label: provider.label, isPast: false))
            }
        }
        return marks
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 0) {
            Text(range == .week ? "最近 7 天用量" : "最近三个月用量")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            segmented(ChartRange.allCases.map { ($0, $0.displayName) },
                      isActive: { $0 == range }) { picked in
                model.chartRange = picked
                model.onChartRangeChanged?(picked)
            }
        }
    }

    private var providerSelector: some View {
        segmented([(ChartSeries.both, "合计"),
                   (ChartSeries.claude, "Claude"),
                   (ChartSeries.codex, "Codex")],
                  isActive: { $0 == toggleSeries }) { toggleSeries = $0 }
    }

    // MARK: 图表主体

    @ViewBuilder private var chartBody: some View {
        if model.history.dayCount == 0 {
            Text("暂无用量数据")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch model.chartProviderMode {
            case .combined:
                HeatmapGrid(history: model.history, range: range,
                            series: .both, renewals: renewalMarks, onAsk: model.onAsk)
            case .toggle:
                HeatmapGrid(history: model.history, range: range,
                            series: toggleSeries, renewals: renewalMarks, onAsk: model.onAsk)
            }
        }
    }

    // MARK: 迷你分段控件

    private func segmented<T: Equatable>(_ items: [(T, String)],
                                         isActive: @escaping (T) -> Bool,
                                         onPick: @escaping (T) -> Void) -> some View {
        MiniSegmented(items: items.map { (value: $0.0, label: $0.1) },
                      isActive: isActive,
                      onPick: onPick)
    }
}

// MARK: - 热力图

// MARK: - 热力格

/// 单个热力格：用量底色 + 可选续费标注环 + 鼠标悬停高亮。
struct HeatCell: View {
    /// 用量底色（空格子为淡白）。
    let color: Color
    let side: CGFloat
    /// 悬停时的原生气泡提示。
    let tooltip: String
    /// 非 nil 时画续费环；isPast 决定实线（上次）还是虚线（下次）。
    var renewal: (accent: Color, isPast: Bool)?
    /// 点击格子时把它的内容抛给小精灵。
    var onAsk: ((String) -> Void)?

    @State private var hovering = false

    private var corner: CGFloat { max(1.5, side * 0.22) }

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(color)
            .frame(width: side, height: side)
            .overlay { renewalRing }
            .overlay { hoverOutline }
            .scaleEffect(hovering ? 1.18 : 1)
            .zIndex(hovering ? 1 : 0)
            .help(onAsk == nil ? tooltip : tooltip + " · 点我问问小精灵")
            .onHover { inside in
                hovering = inside
                guard onAsk != nil else { return }
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture { onAsk?("用户在用量热力图上点了一格：「\(tooltip)」。") }
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: hovering)
    }

    /// 续费标注环：套在格子外圈缝隙里。上一次实线、下一次虚线。
    @ViewBuilder private var renewalRing: some View {
        if let renewal {
            RoundedRectangle(cornerRadius: corner + 2.3, style: .continuous)
                .stroke(renewal.accent,
                        style: renewal.isPast
                            ? StrokeStyle(lineWidth: 1.7)
                            : StrokeStyle(lineWidth: 1.7, dash: [2.6, 2.2]))
                .padding(-2.3)
        }
    }

    /// 悬停时格子描一圈白边（GitHub 贡献图同款交互）。
    @ViewBuilder private var hoverOutline: some View {
        if hovering {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.92), lineWidth: max(1, side * 0.05))
        }
    }
}

/// 单张热力图：周视图为 7 天 × 24 小时，月视图为按周对齐的 30 天格子。
struct HeatmapGrid: View {
    let history: UsageHistory
    let range: ChartRange
    let series: ChartSeries
    /// 月视图里要圈出的续费日（周视图忽略）。
    var renewals: [RenewalMark] = []
    /// 点击格子时把它的内容抛给小精灵。
    var onAsk: ((String) -> Void)?

    private static let weekdayNames = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        switch range {
        case .week: weekGrid
        case .month: monthGrid
        }
    }

    // MARK: 周视图（7 天 × 12 个 2 小时段）

    /// 周视图把 24 小时合成 12 个 2 小时段 —— 格子更大、能方正铺满面板。
    private static let weekBlocks = 12

    private var weekGrid: some View {
        GeometryReader { geo in
            let gap: CGFloat = 3
            let labelW: CGFloat = 24
            let axisH: CGFloat = 12
            let rows = min(7, history.dayCount)
            let cols = Self.weekBlocks
            let maxValue = normMax
            // 边长取「铺满高度」与「铺满宽度」里较小者，格子保持正方形且尽量填满。
            let fillW = (geo.size.width - labelW - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let fillH = (geo.size.height - axisH - gap * CGFloat(rows - 1)) / CGFloat(max(rows, 1))
            let side = max(3, min(fillW, fillH))
            VStack(spacing: gap) {
                ForEach(0 ..< rows, id: \.self) { row in
                    let day = history.dayCount - rows + row
                    HStack(spacing: gap) {
                        Text(weekDayLabel(day))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: labelW, alignment: .leading)
                        ForEach(0 ..< cols, id: \.self) { block in
                            let usage = weekBlock(day: day, block: block)
                            HeatCell(
                                color: cellColor(claude: usage.claude, codex: usage.codex,
                                                  normMax: maxValue),
                                side: side,
                                tooltip: weekTooltip(day: day, block: block,
                                                     claude: usage.claude, codex: usage.codex),
                                onAsk: onAsk)
                        }
                    }
                }
                blockAxis(labelW: labelW, side: side, gap: gap)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// 第 block 个 2 小时段（[block*2, block*2+2) 时）的 Claude / Codex 用量。
    private func weekBlock(day: Int, block: Int) -> (claude: Int, codex: Int) {
        let hour = block * 2
        let first = history.bucket(day: day, hour: hour)
        let second = history.bucket(day: day, hour: hour + 1)
        return ((first?.claudeTokens ?? 0) + (second?.claudeTokens ?? 0),
                (first?.codexTokens ?? 0) + (second?.codexTokens ?? 0))
    }

    private func blockAxis(labelW: CGFloat, side: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            Color.clear.frame(width: labelW, height: 1)
            ForEach(0 ..< Self.weekBlocks, id: \.self) { block in
                Group {
                    if (block * 2) % 6 == 0 {
                        Text("\(block * 2)")
                            .font(.system(size: 7.5))
                            .foregroundStyle(.white.opacity(0.32))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: side)
            }
        }
        .frame(height: 9)
    }

    // MARK: 月视图（GitHub 贡献图样式，按周对齐的近三个月）

    /// 月视图展示的周数（列数）—— 13 周 ≈ 近三个月，正好铺满主面板宽度。
    private static let monthColumns = 13

    private var monthGrid: some View {
        GeometryReader { geo in
            let gap: CGFloat = 3
            let labelW: CGFloat = 18
            let rows = 7
            let cols = Self.monthColumns
            let maxValue = normMax
            // 边长取「铺满高度」与「铺满宽度」里较小者，格子保持正方形。
            let fillH = (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let fillW = (geo.size.width - labelW - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let side = max(3, min(fillH, fillW))
            // 最右一列是本周；今天所在的星期决定本周已过的格子。
            let todayIndex = history.dayCount - 1
            let todayWeekday = mondayIndex(history.dayStart(todayIndex))
            VStack(spacing: gap) {
                ForEach(0 ..< rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        Text(Self.weekdayNames[row])
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: labelW, alignment: .leading)
                        ForEach(0 ..< cols, id: \.self) { col in
                            let weeksAgo = cols - 1 - col
                            monthCell(dayIndex: todayIndex - todayWeekday - weeksAgo * 7 + row,
                                      side: side, normMax: maxValue)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func monthCell(dayIndex: Int, side: CGFloat, normMax: Int) -> some View {
        if dayIndex >= 0, dayIndex < history.dayCount {
            let claude = history.dayClaude(dayIndex)
            let codex = history.dayCodex(dayIndex)
            HeatCell(
                color: cellColor(claude: claude, codex: codex, normMax: normMax),
                side: side,
                tooltip: monthTooltip(dayIndex: dayIndex, claude: claude, codex: codex),
                renewal: renewalDecor(forDayIndex: dayIndex),
                onAsk: onAsk)
        } else if let mark = renewalMark(forDayIndex: dayIndex) {
            // 未来日且正好是下次续费：画一个空格子 + 虚线环。
            HeatCell(
                color: cellColor(claude: 0, codex: 0, normMax: normMax),
                side: side,
                tooltip: futureTooltip(date: monthCellDate(dayIndex), mark: mark),
                renewal: (accent: mark.accent, isPast: mark.isPast),
                onAsk: onAsk)
        } else {
            Color.clear.frame(width: side, height: side)
        }
    }

    /// 命中某次续费的那一天，返回对应标记（仅月视图；支持本周内的未来日）。
    private func renewalMark(forDayIndex dayIndex: Int) -> RenewalMark? {
        guard range == .month, let date = monthCellDate(dayIndex) else { return nil }
        let calendar = Calendar.current
        return renewals.first { calendar.isDate($0.date, inSameDayAs: date) }
    }

    /// 某天若命中续费，返回画环用的 (主色, 是否上一次)。
    private func renewalDecor(forDayIndex dayIndex: Int) -> (accent: Color, isPast: Bool)? {
        renewalMark(forDayIndex: dayIndex).map { (accent: $0.accent, isPast: $0.isPast) }
    }

    /// 月视图某格对应的日期 —— 支持超出 history 末端的未来日（本周剩余几天）。
    private func monthCellDate(_ dayIndex: Int) -> Date? {
        guard dayIndex >= 0, history.dayCount > 0 else { return nil }
        if dayIndex < history.dayCount { return history.dayStart(dayIndex) }
        guard let today = history.dayStart(history.dayCount - 1) else { return nil }
        return Calendar.current.date(byAdding: .day,
                                     value: dayIndex - (history.dayCount - 1), to: today)
    }

    // MARK: 着色

    /// 当前序列下某格的取值。
    private func value(claude: Int, codex: Int) -> Int {
        switch series {
        case .both: return claude + codex
        case .claude: return claude
        case .codex: return codex
        }
    }

    /// 当前视图里的最大单格取值，用于明暗归一化。
    private var normMax: Int {
        var maxValue = 0
        switch range {
        case .week:
            let rows = min(7, history.dayCount)
            for row in 0 ..< rows {
                let day = history.dayCount - rows + row
                for block in 0 ..< Self.weekBlocks {
                    let usage = weekBlock(day: day, block: block)
                    maxValue = max(maxValue, value(claude: usage.claude, codex: usage.codex))
                }
            }
        case .month:
            for day in 0 ..< history.dayCount {
                maxValue = max(maxValue, value(claude: history.dayClaude(day),
                                               codex: history.dayCodex(day)))
            }
        }
        return maxValue
    }

    private func cellColor(claude: Int, codex: Int, normMax: Int) -> Color {
        let amount = value(claude: claude, codex: codex)
        // 空格子用淡白描出网格底，有用量的格子从供应商主色由浅入深。
        guard amount > 0, normMax > 0 else { return Color.white.opacity(0.07) }
        let intensity = log(Double(amount) + 1) / log(Double(normMax) + 1)
        let base: Color
        switch series {
        case .claude: base = claudeAccent
        case .codex: base = codexAccent
        case .both:
            let total = claude + codex
            base = blendAccent(claudeRatio: total > 0 ? Double(claude) / Double(total) : 0.5)
        }
        return base.opacity(0.32 + 0.68 * intensity)
    }

    // MARK: 标签与提示

    /// 周一为 0、周日为 6 的星期序号。
    private func mondayIndex(_ date: Date?) -> Int {
        guard let date else { return 0 }
        let weekday = Calendar.current.component(.weekday, from: date) // 1=周日…7=周六
        return (weekday + 5) % 7
    }

    private func weekDayLabel(_ day: Int) -> String {
        guard let date = history.dayStart(day) else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func weekTooltip(day: Int, block: Int, claude: Int, codex: Int) -> String {
        let label = weekDayLabel(day)
        let span = String(format: "%02d–%02d 时", block * 2, block * 2 + 2)
        guard claude + codex > 0 else { return "\(label) \(span) · 无用量" }
        return "\(label) \(span) · Claude \(shortTokens(claude)) / Codex \(shortTokens(codex))"
    }

    private func monthTooltip(dayIndex: Int, claude: Int, codex: Int) -> String {
        let dateText = history.dayStart(dayIndex).map(Self.monthDayText) ?? ""
        var line = claude + codex > 0
            ? "\(dateText) · Claude \(shortTokens(claude)) / Codex \(shortTokens(codex))"
            : "\(dateText) · 无用量"
        if let mark = renewalMark(forDayIndex: dayIndex) {
            line += mark.isPast ? " · \(mark.label) 续费日" : " · \(mark.label) 下次续费"
        }
        return line
    }

    /// 未来续费格的提示，如「6月3日 · Claude 下次续费」。
    private func futureTooltip(date: Date?, mark: RenewalMark) -> String {
        "\(date.map(Self.monthDayText) ?? "") · \(mark.label) 下次续费"
    }

    /// 「M月d日」中文日期文本。
    private static func monthDayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}
