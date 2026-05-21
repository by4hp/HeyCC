import SwiftUI

// MARK: - 共享状态

@MainActor
final class PanelModel: ObservableObject {
    @Published var claude = ProviderState.initial(name: "Claude Code", prefix: "Cl")
    @Published var codex = ProviderState.initial(name: "Codex", prefix: "Cx")
    @Published var history = UsageHistory.empty
    @Published var lastUpdated: Date?
    /// DeepSeek 生成的俏皮总结；尚未生成时为 nil。
    @Published var quip: String?
    /// 文案生成失败时的错误描述。
    @Published var quipError: String?
    /// 正在调用 DeepSeek 生成文案。
    @Published var quipLoading = false
    @Published var expanded = false
    /// 当前屏幕刘海尺寸，面板顶部用它在刘海两侧排版。
    @Published var notchHeight: CGFloat = 38
    @Published var notchWidth: CGFloat = 220
}

// MARK: - 尺寸常量

enum NotchMetrics {
    static let panelWidth: CGFloat = 392
    /// 刘海下方的内容区高度（窗口总高 = 刘海高度 + 此值）。
    static let contentHeight: CGFloat = 346
    static let cornerRadius: CGFloat = 24
}

private let claudeAccent = Color(red: 0.86, green: 0.47, blue: 0.24)
private let codexAccent = Color(red: 0.30, green: 0.80, blue: 0.74)

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
                ProviderRow(state: model.claude, subscription: claudeSubscription, accent: claudeAccent)
                ProviderRow(state: model.codex, subscription: codexSubscription, accent: codexAccent)
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                HeatmapView(history: model.history)
                Spacer(minLength: 0)
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

/// 刘海面板底部：DeepSeek 生成的俏皮总结。
/// 动效：新文案逐字浮现（打字机），✨ 随之转一圈；生成中时 ✨ 与文字呼吸闪动。
struct QuipFooter: View {
    @ObservedObject var model: PanelModel

    @State private var displayed = ""
    @State private var shown = ""
    @State private var sparkleAngle: Double = 0

    private let sparkleColor = Color(red: 1, green: 0.82, blue: 0.42)

    private enum Mode { case loading, quip, error }
    private var mode: Mode {
        if model.quipLoading { return .loading }
        if let quip = model.quip, !quip.isEmpty { return .quip }
        if model.quipError != nil { return .error }
        return .loading
    }

    var body: some View {
        content
            .task(id: typeKey) { await typewriter() }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .loading:
            // 生成中：✨ 与文字按正弦呼吸。
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate * 2.6
                let wave = 0.5 + 0.5 * sin(phase)
                row(sparkleScale: 1 + 0.18 * wave,
                    text: "正在生成俏皮总结…",
                    textOpacity: 0.30 + 0.26 * wave)
            }
        case .quip:
            row(sparkleScale: 1, text: displayed, textOpacity: 0.64)
        case .error:
            row(sparkleScale: 1, text: model.quipError ?? "", textOpacity: 0.34)
        }
    }

    private func row(sparkleScale: CGFloat, text: String, textOpacity: Double) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 9))
                .foregroundStyle(sparkleColor)
                .scaleEffect(sparkleScale)
                .rotationEffect(.degrees(sparkleAngle))
                .padding(.top, 1.5)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(textOpacity))
                .lineSpacing(2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// task 的触发键：生成中用固定值，出文案后变成文案本身，从而重新触发打字机。
    private var typeKey: String {
        model.quipLoading ? "\u{1}loading" : (model.quip ?? "\u{1}none")
    }

    /// 逐字浮现新文案，并让 ✨ 转一圈。
    private func typewriter() async {
        guard !model.quipLoading else {
            shown = ""
            return
        }
        guard let quip = model.quip, !quip.isEmpty else { return }
        guard quip != shown else {
            displayed = quip
            return
        }
        shown = quip
        withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) {
            sparkleAngle += 360
        }
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
                    Text(subscription.plan)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
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

// MARK: - 热力图

struct HeatmapView: View {
    let history: UsageHistory

    private let cell: CGFloat = 11
    private let gap: CGFloat = 2
    private let labelWidth: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("最近 7 天用量")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            VStack(spacing: gap) {
                ForEach(0 ..< 7, id: \.self) { day in
                    HStack(spacing: gap) {
                        Text(dayLabel(day))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: labelWidth, alignment: .leading)
                        ForEach(0 ..< 24, id: \.self) { hour in
                            cellView(day: day, hour: hour)
                        }
                    }
                }
                hourAxis
            }
        }
    }

    private func cellView(day: Int, hour: Int) -> some View {
        let bucket = history.bucket(day: day, hour: hour)
        return RoundedRectangle(cornerRadius: 2.5)
            .fill(heatColor(bucket?.total ?? 0))
            .frame(width: cell, height: cell)
            .help(tooltip(bucket, day: day, hour: hour))
    }

    private var hourAxis: some View {
        HStack(spacing: gap) {
            Color.clear.frame(width: labelWidth, height: 1)
            ForEach(0 ..< 24, id: \.self) { hour in
                Group {
                    if hour % 6 == 0 {
                        Text("\(hour)")
                            .font(.system(size: 7.5))
                            .foregroundStyle(.white.opacity(0.3))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: cell)
            }
        }
    }

    private func heatColor(_ total: Int) -> Color {
        guard total > 0, history.maxHourTotal > 0 else {
            return Color.white.opacity(0.05)
        }
        let intensity = log(Double(total) + 1) / log(Double(history.maxHourTotal) + 1)
        return Color(
            hue: 0.46,
            saturation: 0.32 + 0.52 * intensity,
            brightness: 0.34 + 0.60 * intensity)
    }

    private func dayLabel(_ day: Int) -> String {
        guard let date = history.dayStart(day) else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func tooltip(_ bucket: HourBucket?, day: Int, hour: Int) -> String {
        let label = dayLabel(day)
        let clock = String(format: "%02d:00", hour)
        guard let bucket, bucket.total > 0 else {
            return "\(label) \(clock) · 无用量"
        }
        return "\(label) \(clock) · Claude \(shortTokens(bucket.claudeTokens))"
            + " / Codex \(shortTokens(bucket.codexTokens))"
    }
}
