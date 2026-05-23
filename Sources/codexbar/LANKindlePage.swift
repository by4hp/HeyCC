import Foundation

// MARK: - Kindle 墨水屏视图

/// 渲染整页 Kindle 友好的用量看板。纯黑白衬线、零 JS、meta 自动刷新。
/// `range` 决定中部图表展示哪个周期；用户通过底部链接切换。
func renderKindlePage(_ s: LANSnapshot, range: LANRange, token: String) -> String {
    let quipBlock = kindleQuipBlock(s.quip)
    let claudeBlock = kindleProviderBlock(s.claude)
    let codexBlock = kindleProviderBlock(s.codex)
    let chartBlock = kindleChartBlock(s, range: range)
    let rangeTabs = kindleRangeTabs(current: range, token: token)
    let updated = s.lastUpdated.map { clockText($0) } ?? "尚未更新"
    let generated = clockText(s.generatedAt)
    let dateLine = dayMonthText(s.generatedAt)
    let claudeDays = daysUntilRenewal(day: s.claudeRenewalDay)
    let codexDays = daysUntilRenewal(day: s.codexRenewalDay)

    return """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="refresh" content="180">
    <title>HeyCC · Code Companion</title>
    <style>
      * { box-sizing: border-box; }
      html, body { background: #fff; color: #000; }
      body {
        margin: 0 auto;
        padding: 22px 18px 28px;
        max-width: 760px;
        font-family: Georgia, "Times New Roman", "Songti SC", "STSong", serif;
        line-height: 1.45;
      }
      .brand { text-align: center; margin-bottom: 6px; }
      .brand .pet-static {
        display: block; margin: 0 auto 6px;
        image-rendering: pixelated;
        image-rendering: -webkit-optimize-contrast;
      }
      .brand h1 {
        margin: 0; font-size: 36px; letter-spacing: 8px; font-weight: normal;
      }
      .brand .sub { font-style: italic; font-size: 14px; letter-spacing: 1px; }
      hr.rule { border: 0; border-top: 1.5px solid #000; margin: 14px 0; }
      hr.thin { border: 0; border-top: 1px dashed #000; margin: 12px 0; }
      .quip {
        text-align: center; font-style: italic; font-size: 15px;
        padding: 10px 6px;
        border-top: 1px dashed #000; border-bottom: 1px dashed #000;
        margin: 12px 0;
      }
      .provider .head {
        display: flex; justify-content: space-between;
        font-size: 12px; text-transform: uppercase; letter-spacing: 3px;
        margin: 4px 0 8px;
      }
      .row {
        font-family: "Menlo", "Courier New", monospace;
        font-size: 13px; margin: 4px 0;
        display: flex; align-items: center;
      }
      .row .lbl { width: 46px; }
      .row .bar {
        flex: 1; height: 12px; border: 1.5px solid #000;
        margin: 0 8px; background: #fff; position: relative;
      }
      .row .bar > i { display: block; height: 100%; background: #000; }
      .row .pct { width: 44px; text-align: right; }
      .row .reset {
        width: 110px; text-align: right; font-size: 11px; margin-left: 6px;
      }
      .errline {
        font-family: "Menlo", "Courier New", monospace; font-size: 12px;
        padding: 6px 8px; border: 1.5px solid #000; margin: 6px 0;
      }
      .workshop {
        display: flex; justify-content: space-around;
        text-align: center; margin: 14px 0 4px;
      }
      .workshop .num {
        display: block; font-size: 30px; font-weight: bold;
        letter-spacing: 2px; line-height: 1.1;
      }
      .workshop .cap {
        font-size: 11px; text-transform: uppercase; letter-spacing: 3px;
      }
      .section-title {
        text-align: center; font-size: 11px;
        text-transform: uppercase; letter-spacing: 3px; margin: 6px 0 6px;
      }
      /* 范围切换：用文本 + 边框，避免任何动画 */
      .range-tabs {
        display: flex; justify-content: center; gap: 0; margin: 8px 0 14px;
      }
      .range-tabs a {
        display: inline-block; padding: 5px 18px;
        font-family: Georgia, serif; font-size: 13px;
        color: #000; text-decoration: none;
        border: 1.5px solid #000; border-right-width: 0;
      }
      .range-tabs a:last-child { border-right-width: 1.5px; }
      .range-tabs a.active { background: #000; color: #fff; font-weight: bold; }
      /* 柱状图：用嵌套 div 画黑色矩形；纯静态，e-ink 友好 */
      .chart {
        display: flex; align-items: flex-end; justify-content: space-between;
        height: 160px; margin: 6px 0; padding: 0 4px;
        border-bottom: 1.5px solid #000;
      }
      .chart .col {
        flex: 1; height: 100%;
        display: flex; flex-direction: column; justify-content: flex-end;
        align-items: center;
      }
      .chart .bar {
        width: 70%; background: #000;
        min-height: 1px; max-width: 22px;
      }
      .chart .bar.empty { background: transparent; border-bottom: 1px solid #000; }
      .chart-axis {
        display: flex; justify-content: space-between;
        font-family: "Menlo", "Courier New", monospace; font-size: 10px;
        margin: 4px 4px 0;
        letter-spacing: 1px;
      }
      .chart-axis span { flex: 1; text-align: center; }
      .chart-peak {
        text-align: right; font-size: 10px; color: #000;
        font-family: "Menlo", monospace; margin: -2px 4px 6px;
      }
      .renewal {
        display: flex; justify-content: space-around;
        text-align: center; margin: 10px 0 4px;
      }
      .renewal .num {
        display: block; font-size: 22px; font-weight: bold;
        letter-spacing: 1px; line-height: 1.1;
      }
      .renewal .cap {
        font-size: 11px; text-transform: uppercase; letter-spacing: 2px;
      }
      footer {
        text-align: center; font-size: 11px; margin-top: 16px;
        letter-spacing: 1px;
      }
      footer .switch {
        display: inline-block; margin-left: 8px;
        color: #000; text-decoration: underline;
      }
    </style>
    </head>
    <body>
    <div class="brand">
      <img class="pet-static" width="72" height="72"
           src="/pets/\(s.petVariant)/idle.png?t=\(token)" alt="HeyCC">
      <h1>NIBBI</h1>
      <div class="sub">Code Companion · 墨水屏</div>
    </div>
    \(quipBlock)
    <hr class="rule">
    \(claudeBlock)
    <hr class="thin">
    \(codexBlock)
    <hr class="rule">
    <div class="section-title">Today's Workshop</div>
    <div class="workshop">
      <div><span class="num">\(shortTokens(s.todayTokens))</span><span class="cap">tokens · 今日</span></div>
      <div><span class="num">\(shortTokens(s.weekTokens))</span><span class="cap">tokens · 7 天</span></div>
    </div>
    <hr class="rule">
    <div class="section-title">Token Trend</div>
    \(rangeTabs)
    \(chartBlock)
    <hr class="rule">
    <div class="section-title">Renewal Countdown</div>
    <div class="renewal">
      <div><span class="num">\(kindleRenewalText(claudeDays))</span><span class="cap">Claude · \(s.claudeRenewalDay) 号</span></div>
      <div><span class="num">\(kindleRenewalText(codexDays))</span><span class="cap">Codex · \(s.codexRenewalDay) 号</span></div>
    </div>
    <footer>
      Updated \(updated) · Rendered \(generated) · \(dateLine)
      <a class="switch" href="?view=mobile&t=\(token)">↗ 切到彩色版</a>
    </footer>
    </body>
    </html>
    """
}

// MARK: - 各区块

private func kindleQuipBlock(_ quip: String?) -> String {
    guard let quip, !quip.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
    return "<div class=\"quip\">\(htmlEscape(quip))</div>"
}

private func kindleProviderBlock(_ p: LANSnapshot.Provider) -> String {
    let plan = (p.plan?.isEmpty == false) ? p.plan! : "—"
    var rows = ""
    rows += kindleRow(label: "5h", percent: p.fiveHourPercent, resetAt: p.fiveHourResetAt)
    rows += kindleRow(label: "周", percent: p.weeklyPercent, resetAt: p.weeklyResetAt)
    var errBlock = ""
    if let err = p.error, !err.isEmpty {
        errBlock = "<div class=\"errline\">⚠ \(htmlEscape(err))</div>"
    }
    return """
    <div class="provider">
      <div class="head"><span>\(htmlEscape(p.name))</span><span>\(htmlEscape(plan))</span></div>
      \(rows)
      \(errBlock)
    </div>
    """
}

private func kindleRow(label: String, percent: Double?, resetAt: Date?) -> String {
    guard let percent else {
        return """
        <div class="row">
          <span class="lbl">\(label)</span>
          <span class="bar"><i style="width:0%"></i></span>
          <span class="pct">—</span>
          <span class="reset"></span>
        </div>
        """
    }
    let clamped = min(max(percent, 0), 100)
    let pctText = String(format: "%3d%%", Int(clamped.rounded()))
    let resetText = resetAt.map { "重置 " + relativeText($0) } ?? ""
    return """
    <div class="row">
      <span class="lbl">\(label)</span>
      <span class="bar"><i style="width:\(Int(clamped.rounded()))%"></i></span>
      <span class="pct">\(pctText)</span>
      <span class="reset">\(htmlEscape(resetText))</span>
    </div>
    """
}

/// 日/周/月切换 tab —— 纯 `<a>` 链接，URL 保留 token + 自身。
private func kindleRangeTabs(current: LANRange, token: String) -> String {
    func tab(_ r: LANRange, _ label: String) -> String {
        let active = (r == current) ? " active" : ""
        let href = "?view=kindle&range=\(r.rawValue)&t=\(token)"
        return "<a class=\"tab\(active)\" href=\"\(href)\">\(label)</a>"
    }
    return """
    <div class="range-tabs">
      \(tab(.day, "24 小时"))
      \(tab(.week, "7 天"))
      \(tab(.month, "30 天"))
    </div>
    """
}

/// 渲染中部那张柱状图：日 24 柱、周 7 柱、月 30 柱。
private func kindleChartBlock(_ s: LANSnapshot, range: LANRange) -> String {
    let bars: [(label: String, value: Int, claude: Int, codex: Int)]
    let calendar = Calendar.current

    switch range {
    case .day:
        var items: [(String, Int, Int, Int)] = []
        items.reserveCapacity(24)
        let now = Date()
        let nowHour = calendar.component(.hour, from: now)
        for i in 0 ..< 24 {
            // 列对应的小时（24 小时前 → 当前），label 只在 6 的倍数处显示
            let hourOffset = -(23 - i)
            let hourValue = (nowHour + hourOffset + 48) % 24
            let label = (i % 6 == 0 || i == 23) ? String(format: "%02d", hourValue) : ""
            items.append((
                label,
                s.hourlyTokens[i],
                s.hourlyClaudeTokens[i],
                s.hourlyCodexTokens[i]))
        }
        bars = items
    case .week:
        // 取 dailyPoints 末 7 天
        let count = min(s.dailyPoints.count, 7)
        let slice = s.dailyPoints.suffix(count)
        var items: [(String, Int, Int, Int)] = []
        for point in slice {
            let label = weekdayLabel(point.dayStart)
            items.append((label, point.total, point.claudeTokens, point.codexTokens))
        }
        bars = items
    case .month:
        // 取 dailyPoints 末 30 天
        let count = min(s.dailyPoints.count, 30)
        let slice = s.dailyPoints.suffix(count)
        var items: [(String, Int, Int, Int)] = []
        for (idx, point) in slice.enumerated() {
            // 月视图柱多，每 5 列才标一次日期
            let label = (idx == 0 || idx == count - 1 || idx % 5 == 0)
                ? "\(calendar.component(.day, from: point.dayStart))"
                : ""
            items.append((label, point.total, point.claudeTokens, point.codexTokens))
        }
        bars = items
    }

    let peak = bars.map(\.value).max() ?? 0
    var cols = ""
    for bar in bars {
        let height = peak > 0 ? Int((Double(bar.value) / Double(peak)) * 150) : 0
        let cls = height == 0 ? "bar empty" : "bar"
        let title = "title=\"\(htmlEscape(barTooltip(bar)))\""
        cols += """
        <div class="col">
          <div class="\(cls)" style="height:\(max(height, height == 0 ? 0 : 2))px" \(title)></div>
        </div>
        """
    }

    var axis = ""
    for bar in bars {
        axis += "<span>\(htmlEscape(bar.label))</span>"
    }

    let peakLabel = peak > 0 ? "峰值 \(shortTokens(peak))" : "暂无数据"
    return """
    <div class="chart">\(cols)</div>
    <div class="chart-axis">\(axis)</div>
    <div class="chart-peak">\(peakLabel)</div>
    """
}

private func barTooltip(_ bar: (label: String, value: Int, claude: Int, codex: Int)) -> String {
    "Cl \(shortTokens(bar.claude)) · Cx \(shortTokens(bar.codex)) · 合计 \(shortTokens(bar.value))"
}

private func weekdayLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "EEE"
    return formatter.string(from: date)
}

private func kindleRenewalText(_ days: Int) -> String {
    if days < 0 { return "—" }
    if days == 0 { return "今天" }
    return "\(days) 天"
}
