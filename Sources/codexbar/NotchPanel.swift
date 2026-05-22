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
    /// 用户希望被称呼的名字（喂给俏皮总结），来自配置。
    var userName = ""
    /// 当前屏幕刘海尺寸，面板顶部用它在刘海两侧排版。
    @Published var notchHeight: CGFloat = 38
    @Published var notchWidth: CGFloat = 220
    /// 图表时间范围（周/月），来自配置、可在图表顶部切换。
    @Published var chartRange: ChartRange = .week
    /// 图表里 Claude / Codex 的区分方式，来自配置、在「设置」里改。
    @Published var chartProviderMode: ChartProviderMode = .combined
    /// 面板底部的像素宠物样式，来自配置、在「设置」里改。
    @Published var petVariant: PetVariant = .mascot
    /// 在图表顶部切换时间范围时触发（由 AppDelegate 注入：写回配置）。
    var onChartRangeChanged: ((ChartRange) -> Void)?
}

// MARK: - 尺寸常量

enum NotchMetrics {
    static let panelWidth: CGFloat = 392
    /// 刘海下方的内容区高度（窗口总高 = 刘海高度 + 此值）。
    /// 留足空间让周/月热力图的方块足够大、能舒展铺开。
    static let contentHeight: CGFloat = 448
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
                    accent: claudeAccent)
                ProviderRow(
                    state: model.codex,
                    subscription: Subscription(renewalDay: model.codexRenewalDay),
                    accent: codexAccent)
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

    /// 刘海一行：左右两耳分别放标题与更新时间，中间避开物理刘海。
    private var notchBar: some View {
        HStack(spacing: 0) {
            Text("周额度总览")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text("7 天")
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

    private var weeklyPercent: Double? { state.weekly?.percent }
    private var fivehPercent: Double? { state.fiveHour?.percent }
    private var fraction: Double { min(max((weeklyPercent ?? 0) / 100, 0), 1) }

    private var valueText: String {
        if state.isLoading { return "…" }
        if let weeklyPercent { return "\(Int(weeklyPercent.rounded()))%" }
        return "—"
    }

    private var valueColor: Color {
        guard let weeklyPercent else { return .white.opacity(0.4) }
        switch weeklyPercent {
        case ..<50: return .white
        case ..<80: return Color(red: 1, green: 0.72, blue: 0.24)
        default: return Color(red: 1, green: 0.40, blue: 0.36)
        }
    }

    private var usageLine: String {
        if state.isLoading { return "读取中…" }
        if let error = state.error { return error }
        var parts: [String] = []
        if let reset = state.weekly?.resetAt {
            parts.append("周额度重置 " + relativeText(reset))
        }
        if let fivehPercent {
            parts.append("5h 用量 \(Int(fivehPercent.rounded()))%")
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
                HeatmapGrid(history: model.history, range: range, series: .both)
            case .toggle:
                HeatmapGrid(history: model.history, range: range, series: toggleSeries)
            }
        }
    }

    // MARK: 迷你分段控件

    private func segmented<T: Equatable>(_ items: [(T, String)],
                                         isActive: @escaping (T) -> Bool,
                                         onPick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let active = isActive(item.0)
                Button { onPick(item.0) } label: {
                    Text(item.1)
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

// MARK: - 热力图

/// 单张热力图：周视图为 7 天 × 24 小时，月视图为按周对齐的 30 天格子。
struct HeatmapGrid: View {
    let history: UsageHistory
    let range: ChartRange
    let series: ChartSeries

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
                            cell(claude: usage.claude, codex: usage.codex,
                                 normMax: maxValue, side: side)
                                .help(weekTooltip(day: day, block: block,
                                                  claude: usage.claude, codex: usage.codex))
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
            cell(claude: claude, codex: codex, normMax: normMax, side: side)
                .help(monthTooltip(dayIndex: dayIndex, claude: claude, codex: codex))
        } else {
            Color.clear.frame(width: side, height: side)
        }
    }

    /// 一个正方形热力格，圆角随边长成比例。
    private func cell(claude: Int, codex: Int, normMax: Int, side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: max(1.5, side * 0.22), style: .continuous)
            .fill(cellColor(claude: claude, codex: codex, normMax: normMax))
            .frame(width: side, height: side)
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
        let dateText: String
        if let date = history.dayStart(dayIndex) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            dateText = formatter.string(from: date)
        } else {
            dateText = ""
        }
        guard claude + codex > 0 else { return "\(dateText) · 无用量" }
        return "\(dateText) · Claude \(shortTokens(claude)) / Codex \(shortTokens(codex))"
    }
}
