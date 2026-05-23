import AppKit

struct ProviderState {
    var name: String
    var prefix: String
    var plan: String?
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    var error: String?
    var isLoading: Bool

    static func initial(name: String, prefix: String) -> ProviderState {
        ProviderState(
            name: name, prefix: prefix, plan: nil,
            fiveHour: nil, weekly: nil, error: nil, isLoading: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let model = PanelModel()
    private var notchController: NotchController?
    private var settingsController: SettingsController?
    private let lanServer = LANServer()
    private var lanConfig: (enabled: Bool, port: Int, token: String) = (false, 0, "")

    private var isRefreshing = false
    private var isQuipRefreshing = false
    private var menuIsOpen = false
    private var pendingMenuRebuild = false

    private let refreshInterval: Duration = .seconds(120)
    private let historyInterval: Duration = .seconds(300)
    private let quipInterval: Duration = .seconds(1800)

    // 命中 429 后的退避调度：下一次刷新最早可发生的时刻 + 连续命中次数（用于指数退避）。
    private var nextAllowedRefresh: Date = .distantPast
    private var rateLimitStreak: Int = 0
    private let rateLimitBackoffCap: TimeInterval = 5 * 60  // 5 分钟（即便服务端 Retry-After 更长，本地也不超过这个上限）

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.applicationIconImage = AppBrand.logo
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateUI()

        // 首次运行写出配置模板，并把续费日等设置读进来。
        HeyCCConfig.createTemplateIfMissing()
        applyConfig(HeyCCConfig.load())

        // 戳宠物 → 刷新俏皮总结。
        model.onPokePet = { [weak self] in
            Task { @MainActor in await self?.refreshQuip() }
        }

        // 在图表顶部切换周/月 → 写回配置，下次启动记住。
        model.onChartRangeChanged = { [weak self] range in
            self?.persistChartRange(range)
        }

        // 在面板顶部切换 5h/周额度 → 写回配置，下次启动记住。
        model.onQuotaWindowChanged = { [weak self] window in
            self?.persistQuotaWindow(window)
        }

        // 点击面板上的格子 / 今日脉搏 / 燃尽预测 → 让小精灵针对它回应一句。
        model.onAsk = { [weak self] context in
            Task { @MainActor in await self?.askAI(context) }
        }

        // 钉住 / 取消钉住面板 → 写回配置，下次启动记住。
        model.onPinnedChanged = { [weak self] pinned in
            self?.persistPinned(pinned)
        }

        notchController = NotchController(model: model)
        notchController?.start()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            openSettings()
        }

        Task { @MainActor in
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: refreshInterval)
            }
        }
        Task { @MainActor in
            while !Task.isCancelled {
                await scanHistory()
                try? await Task.sleep(for: historyInterval)
            }
        }
        Task { @MainActor in
            // 等首次用量数据到位（最多 20 秒）再生成文案，让第一条俏皮总结有真实数据可说。
            for _ in 0 ..< 20 {
                if model.lastUpdated != nil { break }
                try? await Task.sleep(for: .seconds(1))
            }
            while !Task.isCancelled {
                await refreshQuip()
                try? await Task.sleep(for: quipInterval)
            }
        }
    }

    // MARK: - 刷新实时用量

    func refresh(thenRefreshQuip: Bool = false, force: Bool = false) {
        if isRefreshing { return }
        // 退避未到点时跳过本次自动刷新；手动「立即刷新」走 force=true 可绕过。
        if !force, Date() < nextAllowedRefresh {
            return
        }
        isRefreshing = true
        Task { @MainActor in
            async let claudeResult = fetchClaudeUsage()
            async let codexResult = fetchCodexUsage()

            var hitRateLimit = false
            var maxRetryAfter: TimeInterval = 0

            do {
                let usage = try await claudeResult
                model.claude = ProviderState(
                    name: "Claude Code", prefix: "Cl", plan: usage.plan,
                    fiveHour: usage.fiveHour, weekly: usage.weekly,
                    error: nil, isLoading: false)
            } catch {
                if let usageError = error as? UsageError,
                   case let .rateLimited(_, retry) = usageError {
                    hitRateLimit = true
                    if let retry { maxRetryAfter = max(maxRetryAfter, retry) }
                }
                model.claude = ProviderState(
                    name: "Claude Code", prefix: "Cl", plan: model.claude.plan,
                    fiveHour: model.claude.fiveHour, weekly: model.claude.weekly,
                    error: error.localizedDescription, isLoading: false)
            }

            do {
                let usage = try await codexResult
                model.codex = ProviderState(
                    name: "Codex", prefix: "Cx", plan: usage.plan,
                    fiveHour: usage.fiveHour, weekly: usage.weekly,
                    error: nil, isLoading: false)
            } catch {
                if let usageError = error as? UsageError,
                   case let .rateLimited(_, retry) = usageError {
                    hitRateLimit = true
                    if let retry { maxRetryAfter = max(maxRetryAfter, retry) }
                }
                model.codex = ProviderState(
                    name: "Codex", prefix: "Cx", plan: model.codex.plan,
                    fiveHour: model.codex.fiveHour, weekly: model.codex.weekly,
                    error: error.localizedDescription, isLoading: false)
            }

            // 根据本轮结果更新退避时刻。
            if hitRateLimit {
                rateLimitStreak += 1
                // Retry-After 优先；缺失时用 60s * 2^(streak-1) 指数退避。
                // 不管哪个来源，最终都封顶到 rateLimitBackoffCap，避免被服务端要求等过久。
                let backoff: TimeInterval
                if maxRetryAfter > 0 {
                    backoff = min(maxRetryAfter, rateLimitBackoffCap)
                } else {
                    let exp = pow(2.0, Double(rateLimitStreak - 1))
                    backoff = min(60.0 * exp, rateLimitBackoffCap)
                }
                nextAllowedRefresh = Date().addingTimeInterval(backoff)
            } else {
                rateLimitStreak = 0
                nextAllowedRefresh = .distantPast
            }

            model.lastUpdated = Date()
            isRefreshing = false
            updateUI()
            logStatus()
            if thenRefreshQuip {
                await refreshQuip()
            }
        }
    }

    // MARK: - 扫描历史（热力图数据）

    private func scanHistory() async {
        let history = await Task.detached(priority: .utility) {
            scanUsageHistory()
        }.value
        model.history = history
        logStatus()
    }

    // MARK: - 生成俏皮总结（DeepSeek）

    private func refreshQuip() async {
        if isQuipRefreshing { return }
        isQuipRefreshing = true
        model.quipLoading = true
        defer {
            isQuipRefreshing = false
            model.quipLoading = false
        }

        do {
            model.quip = try await generateQuip(from: currentSnapshot())
            model.quipError = nil
        } catch {
            // 保留上一条文案，只更新错误信息。
            model.quipError = error.localizedDescription
        }
        let status = model.quip ?? model.quipError ?? "无"
        FileHandle.standardError.write(Data("[\(AppBrand.name)] 俏皮总结：\(status)\n".utf8))
    }

    /// 用户点击面板元素 → 让 DeepSeek 针对那段内容回应，结果显示在小精灵气泡里。
    private func askAI(_ context: String) async {
        if isQuipRefreshing { return }
        isQuipRefreshing = true
        model.quipLoading = true
        defer {
            isQuipRefreshing = false
            model.quipLoading = false
        }
        do {
            model.quip = try await generateReply(about: context, userName: model.userName)
            model.quipError = nil
        } catch {
            model.quipError = error.localizedDescription
        }
    }

    /// 把当前用量状态打包成喂给 DeepSeek 的快照。
    private func currentSnapshot() -> UsageSnapshot {
        func snap(_ state: ProviderState, renewalDay: Int) -> ProviderSnapshot {
            ProviderSnapshot(
                plan: state.plan,
                renewalDay: renewalDay,
                fiveHourPercent: state.fiveHour?.percent,
                fiveHourResetAt: state.fiveHour?.resetAt,
                weeklyPercent: state.weekly?.percent,
                weeklyResetAt: state.weekly?.resetAt,
                error: state.isLoading ? nil : state.error)
        }

        // 从热力图聚合更多上下文：本周累计、今日累计、最活跃钟点。
        // 仅统计最近 7 天 —— 文案上下文描述的是「最近 7 天」，别让一两个月前的高峰污染。
        let history = model.history
        let weekTotal = history.lastWeekTotal
        let todayTotal = history.todayTotal
        var hourTotals = [Int](repeating: 0, count: 24)
        let calendar = Calendar.current
        for day in max(0, history.dayCount - 7) ..< history.dayCount {
            for hour in 0 ..< 24 {
                guard let bucket = history.bucket(day: day, hour: hour) else { continue }
                let clockHour = calendar.component(.hour, from: bucket.hourStart)
                hourTotals[clockHour] += bucket.total
            }
        }
        let busiest = hourTotals.enumerated().max { $0.element < $1.element }
        let busiestHour = (busiest?.element ?? 0) > 0 ? busiest?.offset : nil

        return UsageSnapshot(
            claude: snap(model.claude, renewalDay: model.claudeRenewalDay),
            codex: snap(model.codex, renewalDay: model.codexRenewalDay),
            peakHourTotal: history.maxHourTotal,
            weekTokenTotal: weekTotal,
            todayTokenTotal: todayTotal,
            busiestHour: busiestHour,
            userName: model.userName,
            generatedAt: Date())
    }

    // MARK: - 菜单栏标题

    private func updateUI() {
        let title = NSMutableAttributedString()
        title.append(statusSegment(model.claude, icon: BrandIcons.claude))
        title.append(NSAttributedString(string: "  "))
        title.append(statusSegment(model.codex, icon: BrandIcons.codex))
        statusItem.button?.attributedTitle = title

        if menuIsOpen {
            pendingMenuRebuild = true
        } else {
            rebuildMenu()
        }
    }

    private func statusSegment(_ state: ProviderState, icon: NSImage?) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let result = NSMutableAttributedString()
        if let icon {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -2.5, width: 13, height: 13)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " ", attributes: [.font: font]))
        } else {
            result.append(NSAttributedString(string: state.prefix + " ", attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }

        let value: String
        let color: NSColor
        if state.isLoading {
            value = "…"
            color = .secondaryLabelColor
        } else if let percent = state.fiveHour?.percent {
            value = "\(Int(percent.rounded()))%"
            // 菜单栏默认黑色（随明暗自适应），仅在剩余 ≤10% 时转红示警。
            color = percent >= 90 ? .systemRed : .labelColor
        } else if state.error != nil {
            value = "⚠"
            color = .systemRed
        } else {
            value = "—"
            color = .secondaryLabelColor
        }

        result.append(NSAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: color,
        ]))
        return result
    }

    // MARK: - 下拉菜单

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let brandItem = NSMenuItem()
        brandItem.title = AppBrand.name
        brandItem.image = AppBrand.menuLogo
        brandItem.isEnabled = false
        menu.addItem(brandItem)
        menu.addItem(.separator())

        addSection(to: menu, state: model.claude)
        menu.addItem(.separator())
        addSection(to: menu, state: model.codex)
        menu.addItem(.separator())

        let updated = NSMenuItem()
        updated.attributedTitle = NSAttributedString(string: lastUpdatedText(), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        menu.addItem(updated)

        let refreshItem = NSMenuItem(
            title: "立即刷新", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(
            title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "退出 \(AppBrand.name)", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addSection(to menu: NSMenu, state: ProviderState) {
        var headerText = state.name
        if let plan = state.plan, !plan.isEmpty {
            headerText += " · " + plan.capitalized
        }
        let header = NSMenuItem()
        header.attributedTitle = NSAttributedString(string: headerText, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        menu.addItem(header)

        if state.isLoading {
            menu.addItem(infoRow("  读取中…", color: .secondaryLabelColor))
            return
        }
        if let fiveHour = state.fiveHour {
            menu.addItem(windowRow(label: "5 小时", window: fiveHour, emphasized: true))
        }
        if let weekly = state.weekly {
            menu.addItem(windowRow(label: "7 天 ", window: weekly, emphasized: false))
        }
        if state.fiveHour == nil, state.weekly == nil, state.error == nil {
            menu.addItem(infoRow("  暂无用量数据", color: .secondaryLabelColor))
        }
        if let error = state.error {
            menu.addItem(infoRow("  ⚠ " + error, color: .systemRed))
        }
    }

    private func infoRow(_ text: String, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: color,
        ])
        return item
    }

    private func windowRow(label: String, window: UsageWindow, emphasized: Bool) -> NSMenuItem {
        let item = NSMenuItem()
        let font = NSFont.monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: emphasized ? .semibold : .regular)
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: "  \(label)   ", attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))

        let percent = window.percent
        let color = usageColor(percent)
        line.append(NSAttributedString(string: progressBar(percent) + " ", attributes: [
            .font: font,
            .foregroundColor: color,
        ]))
        line.append(NSAttributedString(string: String(format: "%3d%%", Int(percent.rounded())), attributes: [
            .font: font,
            .foregroundColor: color,
        ]))
        if let reset = window.resetAt {
            line.append(NSAttributedString(string: "    重置 " + relativeText(reset), attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        item.attributedTitle = line
        return item
    }

    private func lastUpdatedText() -> String {
        guard let updated = model.lastUpdated else { return "尚未更新" }
        return "更新于 " + clockText(updated)
    }

    private func logStatus() {
        func describe(_ state: ProviderState) -> String {
            let plan = state.plan.map { "[\($0)]" } ?? ""
            if let error = state.error { return "\(state.prefix)\(plan)=错误(\(error))" }
            if let percent = state.fiveHour?.percent {
                return "\(state.prefix)\(plan) 5h=\(Int(percent.rounded()))%"
            }
            return "\(state.prefix)\(plan)=无数据"
        }
        let history = model.history
        let historyText = history.hasData
            ? "热力图 桶=\(history.buckets.count) 峰值=\(history.maxHourTotal)"
            : "热力图无数据"
        let line = "[\(AppBrand.name)] \(describe(model.claude)) | \(describe(model.codex)) | \(historyText)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    // MARK: - 动作

    @objc private func refreshClicked() {
        // 手动「立即刷新」：用量与俏皮总结一起刷新。
        if isRefreshing {
            Task { @MainActor in await refreshQuip() }
        } else {
            refresh(thenRefreshQuip: true, force: true)
        }
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsController()
        }
        settingsController?.show(
            config: HeyCCConfig.load(),
            claudePlan: model.claude.plan,
            codexPlan: model.codex.plan,
            onSave: { [weak self] config in
                self?.handleSettingsSaved(config)
            })
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    // MARK: - 配置

    /// 把配置里的续费日、图表偏好等设置应用到面板模型。
    private func applyConfig(_ config: HeyCCConfig) {
        model.claudeRenewalDay = config.claudeRenewalDay
        model.codexRenewalDay = config.codexRenewalDay
        model.userName = config.userName
        model.chartProviderMode = config.chartProviderMode
        model.chartRange = config.chartRange
        model.quotaWindow = config.quotaWindow
        model.petVariant = config.petVariant
        model.pinned = config.pinned
        applyLANConfig(enabled: config.lanEnabled, port: config.lanPort, token: config.lanToken)
    }

    /// 根据局域网相关配置启停 server；仅当真正变化时动手。
    private func applyLANConfig(enabled: Bool, port: Int, token: String) {
        let next = (enabled, port, token)
        if lanConfig == next { return }
        lanConfig = next

        if !enabled {
            lanServer.stop()
            return
        }
        // 首次启动时注入主线程快照拉取闭包（仅一次，闭包内部捕获 self、每次现读）。
        if lanServer.snapshotProvider == nil {
            lanServer.snapshotProvider = { [weak self] in
                MainActor.assertIsolated()
                return self?.makeLANSnapshot() ?? .empty
            }
            lanServer.onStatus = { text in
                FileHandle.standardError.write(Data("[\(AppBrand.name)] \(text)\n".utf8))
            }
        }
        lanServer.start(port: port, token: token)
    }

    /// 把面板模型 + 历史数据打包成给看板用的不可变快照。
    private func makeLANSnapshot() -> LANSnapshot {
        func provider(_ state: ProviderState) -> LANSnapshot.Provider {
            LANSnapshot.Provider(
                name: state.name,
                plan: state.plan,
                fiveHourPercent: state.fiveHour?.percent,
                fiveHourResetAt: state.fiveHour?.resetAt,
                weeklyPercent: state.weekly?.percent,
                weeklyResetAt: state.weekly?.resetAt,
                error: state.isLoading ? nil : state.error)
        }

        let history = model.history
        let calendar = Calendar.current
        let now = Date()

        // 最近 24 个自然小时：双品牌分开。`[0]` 为 23 小时前，`[23]` 为当前小时。
        var hourlyClaude = [Int](repeating: 0, count: 24)
        var hourlyCodex = [Int](repeating: 0, count: 24)
        if history.dayCount > 0 {
            let today = history.dayCount - 1
            let nowHour = calendar.component(.hour, from: now)
            var pairs: [(claude: Int, codex: Int)] = []
            // 先收当天的 0..nowHour
            for h in 0 ... nowHour {
                let bucket = history.bucket(day: today, hour: h)
                pairs.append((bucket?.claudeTokens ?? 0, bucket?.codexTokens ?? 0))
            }
            // 再用昨天的尾部凑足 24
            let need = 24 - pairs.count
            if need > 0, today >= 1 {
                var yesterday: [(Int, Int)] = []
                let startHour = 24 - need
                for h in startHour ..< 24 {
                    let bucket = history.bucket(day: today - 1, hour: h)
                    yesterday.append((bucket?.claudeTokens ?? 0, bucket?.codexTokens ?? 0))
                }
                pairs = yesterday + pairs
            }
            // 还不足就左侧补 0
            if pairs.count < 24 {
                pairs = [(Int, Int)](repeating: (0, 0), count: 24 - pairs.count) + pairs
            }
            let trimmed = Array(pairs.suffix(24))
            hourlyClaude = trimmed.map(\.0)
            hourlyCodex = trimmed.map(\.1)
        }
        let hourlyTotal = zip(hourlyClaude, hourlyCodex).map { $0 + $1 }

        // 最近 30 天每天的双品牌总量（从历史尾部取最后 30 天，不足补 0）。
        var dailyPoints: [LANSnapshot.DailyPoint] = []
        if history.dayCount > 0 {
            let want = 30
            let firstDay = max(0, history.dayCount - want)
            for day in firstDay ..< history.dayCount {
                let dayStart = history.dayStart(day) ?? now
                dailyPoints.append(LANSnapshot.DailyPoint(
                    dayStart: dayStart,
                    claudeTokens: history.dayClaude(day),
                    codexTokens: history.dayCodex(day)))
            }
            // 不足 30 天的，在前面补空日；让前端能稳定渲染 30 个柱子。
            while dailyPoints.count < want, let oldest = dailyPoints.first {
                guard let prev = calendar.date(byAdding: .day, value: -1, to: oldest.dayStart) else { break }
                dailyPoints.insert(LANSnapshot.DailyPoint(
                    dayStart: prev, claudeTokens: 0, codexTokens: 0), at: 0)
            }
        }

        // 网页端按可用位图走：蓝发大头用 blue_chibi，其余（mascot/卡通大头）兜底走 chibi。
        let webPet: String = (model.petVariant == .blueChibiPortrait) ? "blue_chibi" : "chibi"

        return LANSnapshot(
            claude: provider(model.claude),
            codex: provider(model.codex),
            quip: model.quip,
            hourlyTokens: hourlyTotal,
            hourlyClaudeTokens: hourlyClaude,
            hourlyCodexTokens: hourlyCodex,
            dailyPoints: dailyPoints,
            todayTokens: history.todayTotal,
            weekTokens: history.lastWeekTotal,
            lastUpdated: model.lastUpdated,
            generatedAt: Date(),
            claudeRenewalDay: model.claudeRenewalDay,
            codexRenewalDay: model.codexRenewalDay,
            petVariant: webPet)
    }

    /// 仅把图表时间范围写回配置文件（其余字段保持不变）。
    private func persistChartRange(_ range: ChartRange) {
        var config = HeyCCConfig.load()
        guard config.chartRange != range else { return }
        config.chartRange = range
        try? config.save()
    }

    /// 仅把固定显示开关写回配置文件（其余字段保持不变）。
    private func persistPinned(_ pinned: Bool) {
        var config = HeyCCConfig.load()
        guard config.pinned != pinned else { return }
        config.pinned = pinned
        try? config.save()
    }

    /// 仅把额度口径写回配置文件（其余字段保持不变）。
    private func persistQuotaWindow(_ window: QuotaWindow) {
        var config = HeyCCConfig.load()
        guard config.quotaWindow != window else { return }
        config.quotaWindow = window
        try? config.save()
    }

    /// 设置即时保存后：应用新值。
    /// 设置面板现在每改一项就调一次 onSave —— 这里要避免每次都重打 DeepSeek。
    /// 仅当 deepseekKey 或 userName 真正变化时才刷新俏皮总结。
    private func handleSettingsSaved(_ config: HeyCCConfig) {
        let prev = lastSavedConfig
        lastSavedConfig = config
        applyConfig(config)
        updateUI()
        let keyChanged = prev?.deepseekAPIKey != config.deepseekAPIKey
        let nameChanged = prev?.userName != config.userName
        if prev != nil, keyChanged || nameChanged {
            Task { @MainActor in await refreshQuip() }
        }
    }

    /// 上一次保存的配置 —— 用来判断哪些字段真的变了。
    private var lastSavedConfig: HeyCCConfig?

    // MARK: - NSMenuDelegate

    func menuWillOpen(_: NSMenu) {
        menuIsOpen = true
        refresh()
    }

    func menuDidClose(_: NSMenu) {
        menuIsOpen = false
        if pendingMenuRebuild {
            pendingMenuRebuild = false
            rebuildMenu()
        }
    }
}

// MARK: - 展示辅助

private func usageColor(_ percent: Double) -> NSColor {
    switch percent {
    case ..<50: .labelColor
    case ..<80: .systemOrange
    default: .systemRed
    }
}

private func progressBar(_ percent: Double) -> String {
    let slots = 10
    let clamped = min(max(percent, 0), 100)
    let filled = Int((clamped / 100 * Double(slots)).rounded())
    return String(repeating: "█", count: filled)
        + String(repeating: "░", count: slots - filled)
}
