import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - 设置窗口控制器

/// 管理「设置」窗口：磨砂玻璃窗体 + SwiftUI 表单，保存时写回配置文件。
@MainActor
final class SettingsController {
    private var window: NSWindow?

    /// 打开设置窗口。每次都用最新配置与识别到的套餐重建内容。
    func show(config: HeyCCConfig,
              claudePlan: String?,
              codexPlan: String?,
              onSave: @escaping (HeyCCConfig) -> Void) {
        let view = SettingsView(
            config: config,
            claudePlan: claudePlan,
            codexPlan: codexPlan,
            onSave: { newConfig in
                do {
                    try newConfig.save()
                } catch {
                    NSSound.beep()
                }
                onSave(newConfig)
            })

        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        var contentSize = hosting.fittingSize
        if contentSize.width < 200 || contentSize.height < 200 {
            contentSize = NSSize(width: 420, height: 560) // 兜底，避免取到 0 尺寸
        }
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.autoresizingMask = [.width, .height]

        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            self.window = window
        }

        // 主窗口背景：用系统窗口材质，厚实不糊。
        let glass = NSVisualEffectView(frame: hosting.frame)
        glass.material = .windowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        glass.addSubview(hosting)

        window.contentView = glass
        window.setContentSize(contentSize)
        window.center()
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 设置表单

/// 设置窗口里的分页。每页内容控制在窗口高度内，避免出现滚动条。
private enum SettingsTab: Hashable, CaseIterable {
    case general, ai, lan

    var label: String {
        switch self {
        case .general: return L("常规", "General")
        case .ai: return L("AI 小精灵", "AI Sprite")
        case .lan: return L("局域网看板", "LAN Dashboard")
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .ai: return "sparkles"
        case .lan: return "network"
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @State private var claudeDay: Int
    @State private var codexDay: Int
    @State private var deepseekKey: String
    @State private var userName: String
    @State private var showClaudeCalendar = false
    @State private var showCodexCalendar = false
    @State private var chartMode: ChartProviderMode
    @State private var chartRange: ChartRange
    @State private var petVariant: PetVariant
    @State private var lanEnabled: Bool
    @State private var lanPort: Int
    @State private var lanToken: String
    @State private var language: AppLanguage

    private let claudePlan: String?
    private let codexPlan: String?
    /// 额度口径与固定开关只在悬浮面板上切换，设置里不暴露 —— 原样保留、保存时透传。
    private let quotaWindow: QuotaWindow
    private let pinned: Bool
    private let onSave: (HeyCCConfig) -> Void

    /// 防抖保存的 pending 任务；textfield 输入时取消上一次。
    @State private var pendingSaveTask: Task<Void, Never>?

    private let claudeTint = Color(red: 0.85, green: 0.49, blue: 0.30)
    private let codexTint = Color(red: 0.26, green: 0.72, blue: 0.66)
    private let deepseekTint = Color(red: 0.55, green: 0.50, blue: 0.95)
    private let chartTint = Color(red: 0.40, green: 0.52, blue: 0.92)
    private let petTint = Color(red: 0.92, green: 0.35, blue: 0.52)

    init(config: HeyCCConfig,
         claudePlan: String?,
         codexPlan: String?,
         onSave: @escaping (HeyCCConfig) -> Void) {
        _claudeDay = State(initialValue: config.claudeRenewalDay)
        _codexDay = State(initialValue: config.codexRenewalDay)
        _deepseekKey = State(initialValue: config.deepseekAPIKey)
        _userName = State(initialValue: config.userName)
        _chartMode = State(initialValue: config.chartProviderMode)
        _chartRange = State(initialValue: config.chartRange)
        _petVariant = State(initialValue: config.petVariant)
        _lanEnabled = State(initialValue: config.lanEnabled)
        _lanPort = State(initialValue: config.lanPort)
        _lanToken = State(initialValue: config.lanToken)
        _language = State(initialValue: config.language)
        self.quotaWindow = config.quotaWindow
        self.pinned = config.pinned
        self.claudePlan = claudePlan
        self.codexPlan = codexPlan
        self.onSave = onSave
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .opacity(0.68)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header
                tabPicker
                Group {
                    switch selectedTab {
                    case .general: generalTab
                    case .ai: aiTab
                    case .lan: lanTab
                    }
                }
                // 锁死内容区高度：tab 切换不会改变窗口/容器尺寸，自然不抖。
                // 按内容最高的 generalTab (~386pt) + 底部呼吸空间 ~54pt。
                .frame(maxWidth: .infinity, minHeight: 440, maxHeight: 440, alignment: .topLeading)
                // 关键：不要把 selectedTab 的变化挂动画 —— 不然不同高度的 tab 切换会塌陷/抖动。
                .transaction { $0.animation = nil }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 500, height: 620)
        // 即时保存：每个选项变化都触发 350ms 防抖的 onSave。
        // textfield 改字符不会狂调 IO，picker/toggle 切换也几乎"即时"。
        .onChange(of: claudeDay) { _ in scheduleSave() }
        .onChange(of: codexDay) { _ in scheduleSave() }
        .onChange(of: chartMode) { _ in scheduleSave() }
        .onChange(of: chartRange) { _ in scheduleSave() }
        .onChange(of: petVariant) { _ in scheduleSave() }
        .onChange(of: lanEnabled) { _ in scheduleSave() }
        .onChange(of: lanPort) { _ in scheduleSave() }
        .onChange(of: lanToken) { _ in scheduleSave() }
        .onChange(of: userName) { _ in scheduleSave() }
        .onChange(of: deepseekKey) { _ in scheduleSave() }
        .onChange(of: language) { newValue in
            // 立刻切全局语言，这次 @State 变更触发的重绘就会读到新语言；再防抖写回。
            appLanguage = newValue
            scheduleSave()
        }
        .onDisappear { pendingSaveTask?.cancel() }
    }

    /// 350ms debounce —— 取消上一次未触发的保存。
    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            saveNow()
        }
    }

    private func saveNow() {
        onSave(HeyCCConfig(
            deepseekAPIKey: deepseekKey.trimmingCharacters(in: .whitespacesAndNewlines),
            claudeRenewalDay: claudeDay,
            codexRenewalDay: codexDay,
            userName: userName.trimmingCharacters(in: .whitespacesAndNewlines),
            chartProviderMode: chartMode,
            chartRange: chartRange,
            quotaWindow: quotaWindow,
            petVariant: petVariant,
            pinned: pinned,
            lanEnabled: lanEnabled,
            lanPort: max(1024, min(65535, lanPort)),
            lanToken: lanToken,
            language: language))
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.5))
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(tab.label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            // 关键：让整段（含图标+文字+周围空白）都可点，而不只命中文字像素
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.08) : Color.clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 各 Tab 内容

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            providerSection
            chartSection
            petSection
            Spacer(minLength: 0)
        }
    }

    private var aiTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            quipSection
            Spacer(minLength: 0)
        }
    }

    private var lanTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            lanSection
            Spacer(minLength: 0)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            if let logo = AppBrand.settingsLogo {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.10), radius: 2.5, y: 1)
            } else {
                PixelPet(pixel: 3, variant: petVariant)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L("设置", "Settings"))
                    .font(.system(size: 20, weight: .semibold))
                Text("\(AppBrand.name) · " + L("额度、AI 小精灵与局域网看板",
                                                "quota, AI sprite & LAN dashboard"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            languageToggle
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(L("本机保存", "Saved locally"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.055)))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.065), lineWidth: 0.5))
    }

    /// 头部右侧的语言切换：中 / EN 胶囊分段控件，切换即时生效。
    private var languageToggle: some View {
        HStack(spacing: 2) {
            ForEach(AppLanguage.allCases, id: \.self) { lang in
                let isSelected = language == lang
                Button {
                    language = lang
                } label: {
                    Text(lang == .zh ? "中" : "EN")
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(minWidth: 24)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .help(L("界面语言", "Interface language"))
    }

    // MARK: 各分区

    /// 订阅套餐 + 续费日合并：同一行展示「图标 · 名字 · 套餐 · 续费日按钮」。
    private var providerSection: some View {
        section(L("订阅套餐", "Subscription"),
                footnote: L("套餐由接口自动识别；点右侧「X 号」按钮可改续费日。",
                            "Plan is detected automatically; tap the day button to set the renewal day.")) {
            providerRow(
                name: "Claude Code", plan: claudePlan,
                day: $claudeDay, showCalendar: $showClaudeCalendar,
                tint: claudeTint, icon: "a.circle.fill")
            rowDivider
            providerRow(
                name: "Codex", plan: codexPlan,
                day: $codexDay, showCalendar: $showCodexCalendar,
                tint: codexTint, icon: "chevron.left.forwardslash.chevron.right")
        }
    }

    private func providerRow(name: String, plan: String?,
                             day: Binding<Int>, showCalendar: Binding<Bool>,
                             tint: Color, icon: String) -> some View {
        HStack(spacing: 12) {
            iconTile(icon, tint)
            Text(name)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text((plan?.isEmpty == false) ? plan!.capitalized : L("识别中…", "Detecting…"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
            dayButton(day: day, show: showCalendar, tint: tint)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    /// 「X 号」按钮，点击弹出图形日历。Apple capsule chip 风格。
    private func dayButton(day: Binding<Int>, show: Binding<Bool>, tint: Color) -> some View {
        Button {
            show.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(L("\(day.wrappedValue) 号", "Day \(day.wrappedValue)"))
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.75)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.13)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: show, arrowEdge: .bottom) {
            DatePicker("", selection: renewalBinding(day), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(tint)
                .padding(12)
        }
    }

    private var chartSection: some View {
        section(L("悬浮窗图表", "Panel chart"),
                footnote: L("时间范围也可在图表顶部直接切换。",
                            "The time range can also be switched at the top of the chart.")) {
            row(icon: "chart.bar.xaxis", tint: chartTint, title: L("Claude / Codex 区分", "Claude / Codex split")) {
                Picker("", selection: $chartMode) {
                    ForEach(ChartProviderMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .controlSize(.small)
            }
            rowDivider
            row(icon: "calendar", tint: chartTint, title: L("默认时间范围", "Default range")) {
                Picker("", selection: $chartRange) {
                    Text(L("最近 7 天", "Last 7 days")).tag(ChartRange.week)
                    Text(L("最近三个月", "Last 3 months")).tag(ChartRange.month)
                }
                .labelsHidden()
                .frame(width: 130)
                .controlSize(.small)
            }
        }
    }

    private var petSection: some View {
        section(L("像素宠物", "Pixel pet"),
                footnote: L("刘海面板底部陪你看额度的小家伙。",
                            "The little buddy at the bottom of the notch panel.")) {
            row(icon: "pawprint.fill", tint: petTint, title: L("宠物样式", "Pet style")) {
                Picker("", selection: $petVariant) {
                    ForEach(PetVariant.allCases, id: \.self) { variant in
                        Text(variant.displayName).tag(variant)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .controlSize(.small)
            }
        }
    }

    private var quipSection: some View {
        section(L("俏皮总结", "Witty summary"),
                footnote: L("面板底部那句俏皮话由 deepseek-v4-flash 生成；留空 API Key 即关闭。",
                            "The line at the bottom is generated by deepseek-v4-flash; leave the API key empty to disable.")) {
            row(icon: "face.smiling", tint: deepseekTint, title: L("称呼", "Nickname")) {
                TextField(L("小精灵怎么称呼你", "What the sprite calls you"), text: $userName)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .frame(width: 170)
            }
            rowDivider
            row(icon: "key.fill", tint: deepseekTint, title: "DeepSeek API Key") {
                SecureField("sk-…", text: $deepseekKey)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 170)
            }
        }
    }

    // MARK: 局域网看板

    private var lanSection: some View {
        section(L("局域网看板", "LAN dashboard"),
                footnote: L("同一 Wi-Fi 的 Kindle / 手机访问下面 URL 看实时用量，每 120 秒自动刷新。",
                            "A Kindle / phone on the same Wi-Fi can open the URL below for live usage, auto-refreshing every 120s.")) {
            row(icon: "antenna.radiowaves.left.and.right", tint: lanTint, title: L("开启共享", "Enable sharing")) {
                Toggle("", isOn: $lanEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            rowDivider
            row(icon: "number", tint: lanTint, title: L("端口", "Port")) {
                TextField("8723", value: $lanPort, format: .number.grouping(.never))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 70)
            }
            rowDivider
            row(icon: "key.fill", tint: lanTint, title: L("访问令牌", "Access token")) {
                HStack(spacing: 6) {
                    Text(lanToken)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 128, alignment: .trailing)
                    Button {
                        lanToken = generateLANToken()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(lanTint)
                            .padding(5)
                            .background(
                                Circle().fill(lanTint.opacity(0.13)))
                    }
                    .buttonStyle(.plain)
                    .help(L("重置令牌", "Reset token"))
                }
            }
            if lanEnabled, let url = lanURL() {
                rowDivider
                lanShareRow(url: url)
            }
        }
    }

    private let lanTint = Color(red: 0.40, green: 0.68, blue: 0.45)

    /// 本机首个可用的 IPv4 拼出来的访问 URL；没有合适网卡时返回 nil。
    private func lanURL() -> String? {
        guard let ip = localIPv4Addresses().first else { return nil }
        return "http://\(ip):\(lanPort)/?t=\(lanToken)"
    }

    private func lanShareRow(url: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let qr = makeQRCode(url, size: 92) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 92, height: 92)
                    .padding(6)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("扫码或在浏览器输入", "Scan or open in a browser"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Text(url)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(url, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(lanTint.opacity(0.13)))
                .foregroundStyle(lanTint)
                .controlSize(.small)
                .help(L("复制链接", "Copy link"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.025))
    }

    // MARK: 复用组件

    /// 一个分区：小标题 + 实色控件背景卡片 + 可选脚注。
    private func section(_ title: String,
                         footnote: String?,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.86)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.065), lineWidth: 0.5))
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 卡片里的一行：图标贴片 + 标题 + 右侧内容。
    private func row(icon: String,
                     tint: Color,
                     title: String,
                     @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            iconTile(icon, tint)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, 50)
    }

    /// System Settings 风格的彩色圆角图标贴片。
    private func iconTile(_ symbol: String, _ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white))
            .shadow(color: tint.opacity(0.25), radius: 1.5, y: 0.5)
    }

    /// Int 续费日 ⟷ Date 的桥接，给日历选择器用。
    private func renewalBinding(_ day: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Self.dateForDay(day.wrappedValue) },
            set: { day.wrappedValue = Calendar.current.component(.day, from: $0) })
    }

    /// 用本月构造某一天的 Date；日号超出本月长度时收敛到月末。
    private static func dateForDay(_ day: Int) -> Date {
        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month], from: now)
        let maxDay = calendar.range(of: .day, in: .month, for: now)?.count ?? 28
        components.day = min(max(day, 1), maxDay)
        return calendar.date(from: components) ?? now
    }
}

/// 用 CoreImage 把字符串渲染成黑白二维码 NSImage；尺寸是显示边长（点）。
private func makeQRCode(_ text: String, size: CGFloat) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let extent = output.extent
    guard extent.width > 0 else { return nil }
    let scale = (size * 3) / extent.width // 三倍像素再交给 NSImage 缩放，更锐利
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(rep)
    return image
}
