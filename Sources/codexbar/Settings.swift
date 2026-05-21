import AppKit
import SwiftUI

// MARK: - 设置窗口控制器

/// 管理「设置」窗口：磨砂玻璃窗体 + SwiftUI 表单，保存时写回配置文件。
@MainActor
final class SettingsController {
    private var window: NSWindow?

    /// 打开设置窗口。每次都用最新配置与识别到的套餐重建内容。
    func show(config: CodexBarConfig,
              claudePlan: String?,
              codexPlan: String?,
              onSave: @escaping (CodexBarConfig) -> Void) {
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
            },
            onClose: { [weak self] in self?.window?.close() })

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

        // 磨砂玻璃背景：透出并模糊身后的桌面。
        let glass = NSVisualEffectView(frame: hosting.frame)
        glass.material = .popover
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

struct SettingsView: View {
    @State private var claudeDay: Int
    @State private var codexDay: Int
    @State private var deepseekKey: String
    @State private var userName: String
    /// 续费日历正在编辑哪一个：0 = Claude，1 = Codex。
    @State private var renewalTarget = 0

    private let claudePlan: String?
    private let codexPlan: String?
    private let onSave: (CodexBarConfig) -> Void
    private let onClose: () -> Void

    private let claudeTint = Color(red: 0.85, green: 0.49, blue: 0.30)
    private let codexTint = Color(red: 0.26, green: 0.72, blue: 0.66)
    private let deepseekTint = Color(red: 0.55, green: 0.50, blue: 0.95)

    init(config: CodexBarConfig,
         claudePlan: String?,
         codexPlan: String?,
         onSave: @escaping (CodexBarConfig) -> Void,
         onClose: @escaping () -> Void) {
        _claudeDay = State(initialValue: config.claudeRenewalDay)
        _codexDay = State(initialValue: config.codexRenewalDay)
        _deepseekKey = State(initialValue: config.deepseekAPIKey)
        _userName = State(initialValue: config.userName)
        self.claudePlan = claudePlan
        self.codexPlan = codexPlan
        self.onSave = onSave
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            planSection
            renewalSection
            quipSection
            footer
        }
        .padding(.horizontal, 22)
        .padding(.top, 38)
        .padding(.bottom, 20)
        .frame(width: 420)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 13) {
            PixelPet(pixel: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("CodexBar 设置")
                    .font(.system(size: 16, weight: .semibold))
                Text("额度看板 · 菜单栏常驻")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: 各分区

    private var planSection: some View {
        section("订阅套餐", footnote: "由官方接口与本机凭证自动识别，无需手动配置。") {
            row(icon: "a.circle.fill", tint: claudeTint, title: "Claude Code") {
                planLabel(claudePlan)
            }
            rowDivider
            row(icon: "chevron.left.forwardslash.chevron.right", tint: codexTint, title: "Codex") {
                planLabel(codexPlan)
            }
        }
    }

    private var renewalSection: some View {
        section("每月续费日", footnote: "在日历上选一天，就当作每月那天续费。") {
            VStack(spacing: 10) {
                Picker("", selection: $renewalTarget) {
                    Text("Claude · \(claudeDay) 号").tag(0)
                    Text("Codex · \(codexDay) 号").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                DatePicker(
                    "",
                    selection: renewalTarget == 0 ? renewalBinding($claudeDay) : renewalBinding($codexDay),
                    displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .tint(renewalTarget == 0 ? claudeTint : codexTint)
            }
            .padding(11)
            .frame(maxWidth: .infinity)
        }
    }

    private var quipSection: some View {
        section("俏皮总结",
                footnote: "刘海面板底部那句俏皮话由 deepseek-v4-flash 生成，留空 API Key 即关闭。") {
            row(icon: "face.smiling", tint: deepseekTint, title: "称呼") {
                TextField("小精灵怎么称呼你", text: $userName)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12))
                    .frame(width: 158)
            }
            rowDivider
            row(icon: "key.fill", tint: deepseekTint, title: "API Key") {
                TextField("sk-…", text: $deepseekKey)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12))
                    .frame(width: 158)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("取消", action: onClose)
                .controlSize(.large)
            Button("保存") {
                onSave(CodexBarConfig(
                    deepseekAPIKey: deepseekKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    claudeRenewalDay: claudeDay,
                    codexRenewalDay: codexDay,
                    userName: userName.trimmingCharacters(in: .whitespacesAndNewlines)))
                onClose()
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: 复用组件

    /// 一个分区：小标题 + 磨砂玻璃卡片 + 可选脚注。
    private func section(_ title: String,
                         footnote: String?,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
            if let footnote {
                Text(footnote)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 卡片里的一行：图标贴片 + 标题 + 右侧内容。
    private func row(icon: String,
                     tint: Color,
                     title: String,
                     @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 11) {
            iconTile(icon, tint)
            Text(title).font(.system(size: 12.5))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 11)
        .frame(height: 42)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 44)
    }

    /// System Settings 风格的彩色圆角图标贴片。
    private func iconTile(_ symbol: String, _ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white))
    }

    private func planLabel(_ plan: String?) -> some View {
        Text((plan?.isEmpty == false) ? plan!.capitalized : "识别中…")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
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
