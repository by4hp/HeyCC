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

private struct ProviderCooldown {
    var nextAllowedRefresh: Date = .distantPast
    var rateLimitStreak: Int = 0

    func remaining(at now: Date = Date()) -> TimeInterval {
        max(nextAllowedRefresh.timeIntervalSince(now), 0)
    }

    mutating func recordSuccess() {
        nextAllowedRefresh = .distantPast
        rateLimitStreak = 0
    }

    mutating func recordRateLimit(retryAfter: TimeInterval?,
                                  fallbackCap: TimeInterval,
                                  now: Date = Date()) -> TimeInterval {
        rateLimitStreak += 1
        let delay: TimeInterval
        if let retryAfter, retryAfter > 0 {
            // Retry-After is server truth. Do not cap it locally.
            delay = retryAfter
        } else {
            let exp = pow(2.0, Double(rateLimitStreak - 1))
            delay = min(60.0 * exp, fallbackCap)
        }
        nextAllowedRefresh = now.addingTimeInterval(delay)
        return delay
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

    private let refreshInterval: Duration = .seconds(300)  // 5 分钟自动刷一次；想立刻看可用菜单栏「立即刷新」(⌘R)
    private let historyInterval: Duration = .seconds(300)
    private let quipInterval: Duration = .seconds(1800)

    // Claude 的 OAuth source 与 Codex 分开退避；OAuth 冷却时 Claude 可继续走 CLI fallback。
    private var claudeOAuthCooldown = ProviderCooldown()
    private var codexCooldown = ProviderCooldown()
    private let rateLimitFallbackCap: TimeInterval = 15 * 60

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.applicationIconImage = AppBrand.logo
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // 首次运行写出配置模板，并把语言/续费日等设置读进来；先于首次 updateUI 以便菜单一开始就是正确语言。
        HeyCCConfig.createTemplateIfMissing()
        applyConfig(HeyCCConfig.load())
        updateUI()

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

    func refresh(thenRefreshQuip: Bool = false) {
        if isRefreshing { return }
        let now = Date()
        let shouldFetchClaudeOAuth = claudeOAuthCooldown.remaining(at: now) <= 0
        let shouldFetchCodex = codexCooldown.remaining(at: now) <= 0
        isRefreshing = true
        Task { @MainActor in
            let claudeTask = Task {
                await captureResult { try await fetchClaudeUsage(allowOAuth: shouldFetchClaudeOAuth) }
            }
            let codexTask: Task<Result<CodexUsage, Error>, Never>? = shouldFetchCodex
                ? Task { await captureResult { try await fetchCodexUsage() } }
                : nil

            switch await claudeTask.value {
            case let .success(usage):
                if usage.oauthWasRateLimited {
                    _ = claudeOAuthCooldown.recordRateLimit(
                        retryAfter: usage.oauthRetryAfter,
                        fallbackCap: rateLimitFallbackCap)
                } else if usage.source == .oauth {
                    claudeOAuthCooldown.recordSuccess()
                }
                model.claude = ProviderState(
                    name: "Claude Code", prefix: "Cl", plan: usage.plan ?? model.claude.plan,
                    fiveHour: preservingReset(usage.fiveHour, from: model.claude.fiveHour),
                    weekly: preservingReset(usage.weekly, from: model.claude.weekly),
                    error: nil, isLoading: false)
            case let .failure(error):
                var message = recordRateLimitIfNeeded(
                    error,
                    cooldown: &claudeOAuthCooldown,
                    fallbackName: "Claude OAuth")
                if message == nil, !shouldFetchClaudeOAuth {
                    message = cooldownMessage(
                        "Claude OAuth", remaining: claudeOAuthCooldown.remaining())
                        + L("；CLI 回退失败", "; CLI fallback failed")
                }
                model.claude = ProviderState(
                    name: "Claude Code", prefix: "Cl", plan: model.claude.plan,
                    fiveHour: model.claude.fiveHour, weekly: model.claude.weekly,
                    error: message ?? error.localizedDescription, isLoading: false)
            }

            if let codexTask {
                switch await codexTask.value {
                case let .success(usage):
                    codexCooldown.recordSuccess()
                    model.codex = ProviderState(
                        name: "Codex", prefix: "Cx", plan: usage.plan,
                        fiveHour: usage.fiveHour, weekly: usage.weekly,
                        error: nil, isLoading: false)
                case let .failure(error):
                    let message = recordRateLimitIfNeeded(
                        error,
                        cooldown: &codexCooldown,
                        fallbackName: "Codex")
                    model.codex = ProviderState(
                        name: "Codex", prefix: "Cx", plan: model.codex.plan,
                        fiveHour: model.codex.fiveHour, weekly: model.codex.weekly,
                        error: message ?? error.localizedDescription, isLoading: false)
                }
            } else {
                model.codex.error = cooldownMessage(
                    "Codex", remaining: codexCooldown.remaining())
                model.codex.isLoading = false
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

    private func preservingReset(_ latest: UsageWindow?, from previous: UsageWindow?) -> UsageWindow? {
        guard var latest else { return nil }
        if latest.resetAt == nil {
            latest.resetAt = previous?.resetAt
        }
        return latest
    }

    private func recordRateLimitIfNeeded(_ error: Error,
                                         cooldown: inout ProviderCooldown,
                                         fallbackName: String) -> String? {
        guard let usageError = error as? UsageError,
              case let .rateLimited(who, retryAfter) = usageError
        else {
            return nil
        }
        let delay = cooldown.recordRateLimit(
            retryAfter: retryAfter,
            fallbackCap: rateLimitFallbackCap)
        return cooldownMessage(who.isEmpty ? fallbackName : who, remaining: delay)
    }

    private func cooldownMessage(_ who: String, remaining: TimeInterval) -> String {
        L("\(who) 用量查询冷却中，\(durationText(remaining))后自动重试",
          "\(who) usage check cooling down, auto-retry in \(durationText(remaining))")
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(1, Int(interval.rounded(.up)))
        if seconds < 90 { return L("\(seconds) 秒", "\(seconds)s") }
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return L("\(minutes) 分钟", "\(minutes)m") }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest > 0 { return L("\(hours) 小时 \(rest) 分钟", "\(hours)h \(rest)m") }
        return L("\(hours) 小时", "\(hours)h")
    }

    private func captureResult<T: Sendable>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
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
            title: L("立即刷新", "Refresh now"), action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(
            title: L("设置…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: L("退出 \(AppBrand.name)", "Quit \(AppBrand.name)"),
            action: #selector(quitClicked), keyEquivalent: "q")
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
            menu.addItem(infoRow(L("  读取中…", "  Loading…"), color: .secondaryLabelColor))
            return
        }
        if let fiveHour = state.fiveHour {
            menu.addItem(windowRow(label: L("5 小时", "5-hour"), window: fiveHour, emphasized: true))
        }
        if let weekly = state.weekly {
            menu.addItem(windowRow(label: L("7 天 ", "7-day "), window: weekly, emphasized: false))
        }
        if state.fiveHour == nil, state.weekly == nil, state.error == nil {
            menu.addItem(infoRow(L("  暂无用量数据", "  No usage data"), color: .secondaryLabelColor))
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
            line.append(NSAttributedString(string: L("    重置 ", "    resets ") + relativeText(reset), attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        item.attributedTitle = line
        return item
    }

    private func lastUpdatedText() -> String {
        guard let updated = model.lastUpdated else { return L("尚未更新", "Not updated yet") }
        return L("更新于 ", "Updated ") + clockText(updated)
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
            refresh(thenRefreshQuip: true)
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
        // 先切全局语言，再改 model（@Published 触发的面板重绘会读到新语言）。
        appLanguage = config.language
        model.language = config.language
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
