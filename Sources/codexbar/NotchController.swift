import AppKit
import SwiftUI

/// 管理刘海下方的悬浮面板：窗口定位、鼠标悬停检测、展开/收起。
@MainActor
final class NotchController {
    let model: PanelModel

    private var window: NSWindow?
    private var pollTask: Task<Void, Never>?
    private var notchScreen: NSScreen?

    private let pollInterval: Duration = .milliseconds(40)

    init(model: PanelModel) {
        self.model = model
    }

    /// 在带刘海的屏幕上启用面板；无刘海屏幕时返回 false。
    @discardableResult
    func start() -> Bool {
        guard let screen = Self.screenWithNotch() else { return false }
        notchScreen = screen
        buildWindow(on: screen)
        startMousePolling()
        observeScreenChanges()
        return true
    }

    // MARK: - 屏幕与窗口几何

    private static func screenWithNotch() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    private func notchHeight(of screen: NSScreen) -> CGFloat {
        max(screen.safeAreaInsets.top, 32)
    }

    private func notchRect(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let height = notchHeight(of: screen)
        let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        var notchWidth = frame.width - leftWidth - rightWidth
        if notchWidth <= 0 || notchWidth > 480 { notchWidth = 220 }
        return NSRect(
            x: frame.midX - notchWidth / 2,
            y: frame.maxY - height,
            width: notchWidth,
            height: height)
    }

    private func windowFrame(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        // 窗口顶边贴屏幕最顶，高度含刘海段，使面板向上覆盖刘海与菜单栏区域。
        let height = notchHeight(of: screen) + NotchMetrics.contentHeight
        return NSRect(
            x: frame.midX - NotchMetrics.panelWidth / 2,
            y: frame.maxY - height,
            width: NotchMetrics.panelWidth,
            height: height)
    }

    private func buildWindow(on screen: NSScreen) {
        model.notchHeight = notchHeight(of: screen)
        model.notchWidth = notchRect(on: screen).width
        let frame = windowFrame(on: screen)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = true

        let hosting = NSHostingView(rootView: NotchPanelView(model: model))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.orderFrontRegardless()
        self.window = window
    }

    // MARK: - 鼠标悬停检测

    /// 用定时轮询读取鼠标全局坐标，而非事件监听 —— 事件在无边框非 key 窗口上不可靠，
    /// 会导致鼠标移入面板时被误判为「离开」而收起。轮询则始终拿得到准确位置。
    private func startMousePolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.updateHoverState()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    private func updateHoverState() {
        guard let screen = notchScreen else { return }
        let pointer = NSEvent.mouseLocation
        let inside = currentHotZone(on: screen).contains(pointer)
        if inside {
            if !model.expanded { setExpanded(true) }
        } else if model.expanded {
            // 离开热区即收起，无缓冲，保持跟手。
            setExpanded(false)
        }
    }

    /// 收起态只响应刘海区域；展开态扩大到整个面板（含缓冲），鼠标在面板上不会收起。
    private func currentHotZone(on screen: NSScreen) -> NSRect {
        if model.expanded, let window {
            return window.frame.insetBy(dx: -8, dy: -8)
        }
        let notch = notchRect(on: screen)
        return NSRect(
            x: notch.minX - 14,
            y: notch.minY - 8,
            width: notch.width + 28,
            height: notch.height + 8)
    }

    private func setExpanded(_ expanded: Bool) {
        model.expanded = expanded
        window?.ignoresMouseEvents = !expanded
    }

    // MARK: - 屏幕变化

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenChange()
            }
        }
    }

    private func handleScreenChange() {
        guard let screen = Self.screenWithNotch() else {
            window?.orderOut(nil)
            notchScreen = nil
            return
        }
        notchScreen = screen
        if let window {
            window.setFrame(windowFrame(on: screen), display: true)
            window.orderFrontRegardless()
        } else {
            buildWindow(on: screen)
        }
    }
}
