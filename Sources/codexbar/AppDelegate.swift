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

    private var isRefreshing = false
    private var isQuipRefreshing = false
    private var menuIsOpen = false
    private var pendingMenuRebuild = false

    private let refreshInterval: Duration = .seconds(60)
    private let historyInterval: Duration = .seconds(300)
    private let quipInterval: Duration = .seconds(1800)

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateUI()

        // 首次运行写出 DeepSeek 配置模板，方便填 Key。
        CodexBarConfig.createTemplateIfMissing()

        notchController = NotchController(model: model)
        notchController?.start()

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
        isRefreshing = true
        Task { @MainActor in
            async let claudeResult = fetchClaudeUsage()
            async let codexResult = fetchCodexUsage()

            do {
                let usage = try await claudeResult
                model.claude = ProviderState(
                    name: "Claude Code", prefix: "Cl", plan: nil,
                    fiveHour: usage.fiveHour, weekly: usage.weekly,
                    error: nil, isLoading: false)
            } catch {
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
                model.codex = ProviderState(
                    name: "Codex", prefix: "Cx", plan: model.codex.plan,
                    fiveHour: model.codex.fiveHour, weekly: model.codex.weekly,
                    error: error.localizedDescription, isLoading: false)
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
        FileHandle.standardError.write(Data("[CodexBar] 俏皮总结：\(status)\n".utf8))
    }

    /// 把当前用量状态打包成喂给 DeepSeek 的快照。
    private func currentSnapshot() -> UsageSnapshot {
        func snap(_ state: ProviderState) -> ProviderSnapshot {
            ProviderSnapshot(
                fiveHourPercent: state.fiveHour?.percent,
                weeklyPercent: state.weekly?.percent,
                weeklyResetAt: state.weekly?.resetAt,
                error: state.isLoading ? nil : state.error)
        }
        return UsageSnapshot(
            claude: snap(model.claude),
            codex: snap(model.codex),
            peakHourTotal: model.history.maxHourTotal,
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
            color = usageColor(percent)
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

        let quitItem = NSMenuItem(
            title: "退出 CodexBar", action: #selector(quitClicked), keyEquivalent: "q")
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
            if let error = state.error { return "\(state.prefix)=错误(\(error))" }
            if let percent = state.fiveHour?.percent {
                return "\(state.prefix) 5h=\(Int(percent.rounded()))%"
            }
            return "\(state.prefix)=无数据"
        }
        let history = model.history
        let historyText = history.hasData
            ? "热力图 桶=\(history.buckets.count) 峰值=\(history.maxHourTotal)"
            : "热力图无数据"
        let line = "[CodexBar] \(describe(model.claude)) | \(describe(model.codex)) | \(historyText)\n"
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

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

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
