import AppKit
import ApplicationServices

@MainActor
final class MenuBarHider: NSObject, NSApplicationDelegate {
    private let bridge = VisibilityBridge()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var hiddenIDs = Set<String>()
    private var collapsed = false
    private var isApplying = false
    private var iconStyle = StatusIconStyle.standard
    private var autoCollapseEnabled = true
    private var mouseMoveMonitor: Any?
    private var localMouseMoveMonitor: Any?
    private var collapseTimer: Timer?
    private var blankClickMonitor: Any?
    private var localClickMonitor: Any?
    private var statusTrackingArea: NSTrackingArea?
    private var hasVisitedMenuBar = false
    private var menuBarRegions: [CGRect] = []
    private var showingContextMenu = false
    private var runningAppObserver: NSObjectProtocol?
    private var terminatedAppObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var settingsWindow: SettingsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hiddenIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenBundleIdentifiers") ?? [])
        iconStyle = StatusIconStyle(rawValue: UserDefaults.standard.string(forKey: "statusIconStyle") ?? "") ?? .standard
        autoCollapseEnabled = UserDefaults.standard.object(forKey: "autoCollapseOnMouseLeave") as? Bool ?? true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.toolTip = "左键展开或收起，右键打开设置"
        if let button = statusItem.button {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            button.addTrackingArea(area)
            statusTrackingArea = area
        }
        updateIcon()
        startMouseWatch(visitedMenuBar: false)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateMenuBarRegions()
                self?.mouseMoved()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        runningAppObserver = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runningAppsChanged() }
        }
        terminatedAppObserver = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runningAppsChanged() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMouseWatch()
        if let statusTrackingArea, let button = statusItem.button {
            button.removeTrackingArea(statusTrackingArea)
        }
        bridge.release()
        let center = NSWorkspace.shared.notificationCenter
        if let runningAppObserver { center.removeObserver(runningAppObserver) }
        if let terminatedAppObserver { center.removeObserver(terminatedAppObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    private func updateIcon() {
        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.image = iconStyle.image(collapsed: collapsed)
    }

    private func startMouseWatch(visitedMenuBar: Bool) {
        stopMouseWatch()
        updateMenuBarRegions()
        guard !hiddenIDs.isEmpty, settingsWindow?.isVisible != true else { return }
        hasVisitedMenuBar = visitedMenuBar
        if collapsed {
            blankClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handleMenuBarClick(event) }
            }
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handleMenuBarClick(event) }
                return event
            }
            return
        }
        guard autoCollapseEnabled else { return }
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }
        mouseMoved()
    }

    private func stopMouseWatch() {
        collapseTimer?.invalidate()
        collapseTimer = nil
        if let mouseMoveMonitor {
            NSEvent.removeMonitor(mouseMoveMonitor)
            self.mouseMoveMonitor = nil
        }
        if let localMouseMoveMonitor {
            NSEvent.removeMonitor(localMouseMoveMonitor)
            self.localMouseMoveMonitor = nil
        }
        if let blankClickMonitor {
            NSEvent.removeMonitor(blankClickMonitor)
            self.blankClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        hasVisitedMenuBar = false
    }

    @objc private func mouseEntered(_ event: NSEvent) {
        mouseMoved()
    }

    @objc private func mouseExited(_ event: NSEvent) {
        mouseMoved()
    }

    private func mouseMoved() {
        guard !collapsed, autoCollapseEnabled, !isApplying, !showingContextMenu,
              settingsWindow?.isVisible != true else { return }
        let mouse = NSEvent.mouseLocation
        let inMenuBar = isInMenuBar(mouse)
        if inMenuBar {
            hasVisitedMenuBar = true
            collapseTimer?.invalidate()
            collapseTimer = nil
        } else if hasVisitedMenuBar, collapseTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.completeCollapse() }
            }
            collapseTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func completeCollapse() {
        collapseTimer = nil
        guard !collapsed, autoCollapseEnabled, !isApplying, !showingContextMenu,
              !isInMenuBar(NSEvent.mouseLocation) else { return }
        applyRestriction()
    }

    private func updateMenuBarRegions() {
        menuBarRegions = NSScreen.screens.map { screen in
            let height = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
            return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                          width: screen.frame.width, height: height)
        }
    }

    private func isInMenuBar(_ point: CGPoint) -> Bool {
        menuBarRegions.contains { $0.contains(point) }
    }

    private func handleMenuBarClick(_ event: NSEvent) {
        guard collapsed, !isApplying, !showingContextMenu,
              let point = event.cgEvent?.location ?? CGEvent(source: nil)?.location,
              isBlankMenuBar(at: point) else { return }
        toggleVisibility()
    }

    private func isBlankMenuBar(at point: CGPoint) -> Bool {
        guard MenuBarInventory.isTrusted else { return false }
        let inMenuBar = NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            let height = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
            return bounds.contains(point) && point.y <= bounds.minY + height
        }
        guard inMenuBar else { return false }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1)
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        if result == .success {
            guard let hit else { return false }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &value) == .success,
                  let role = value as? String else { return false }
            // 命中交互控件时不展开；空白背景在不同系统版本可能不是固定的 AX 角色。
            let itemRoles = [kAXMenuBarItemRole, kAXMenuItemRole, kAXButtonRole,
                             kAXPopUpButtonRole, kAXCheckBoxRole].map { $0 as String }
            guard !itemRoles.contains(role), role != "AXStatusItem" else { return false }
        } else if result != .noValue {
            return false
        }
        guard let items = try? MenuBarInventory.read() else { return false }
        // 空白处才响应；菜单栏项目的点击仍交给所属应用处理。
        return !items.contains { $0.frame.insetBy(dx: -3, dy: -2).contains(point) }
    }

    private func runningAppsChanged() {
        if collapsed && !isApplying { applyRestriction() }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggleVisibility()
        }
    }

    private func showContextMenu() {
        menu.removeAllItems()
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let toggle = NSMenuItem(title: collapsed ? "展开所有图标" : "收起隐藏图标",
                                action: #selector(toggleVisibility), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !isApplying
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 BarClean", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        guard let button = statusItem.button else { return }
        showingContextMenu = true
        defer { showingContextMenu = false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    @objc private func showSettings() {
        // 设置窗口读取的是当前绘制的图标，收起状态会造成不完整的顺序快照。
        stopMouseWatch()
        bridge.release()
        collapsed = false
        updateIcon()
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(
                hiddenIDs: hiddenIDs,
                iconStyle: iconStyle,
                autoCollapseEnabled: autoCollapseEnabled,
                onApply: { [weak self] ids in
                    guard let self else { return }
                    self.hiddenIDs = ids
                    self.bridge.release()
                    self.collapsed = false
                    self.updateIcon()
                    if !ids.isEmpty { self.applyRestriction() }
                },
                onPreferencesChanged: { [weak self] style, enabled in
                    guard let self else { return }
                    self.iconStyle = style
                    self.autoCollapseEnabled = enabled
                    UserDefaults.standard.set(style.rawValue, forKey: "statusIconStyle")
                    UserDefaults.standard.set(enabled, forKey: "autoCollapseOnMouseLeave")
                    self.updateIcon()
                    self.startMouseWatch(visitedMenuBar: false)
                },
                onClose: { [weak self] in
                    self?.startMouseWatch(visitedMenuBar: true)
                }
            )
        }
        settingsWindow?.show()
    }

    @objc private func toggleVisibility() {
        guard !isApplying else { return }
        if collapsed {
            bridge.release()
            collapsed = false
            updateIcon()
            startMouseWatch(visitedMenuBar: true)
        } else if hiddenIDs.isEmpty {
            showSettings()
        } else {
            applyRestriction()
        }
    }

    private func applyRestriction() {
        stopMouseWatch()
        guard bridge.isAvailable else {
            showError("当前系统未提供可用的隐藏接口")
            return
        }
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            showError("请将应用放入 /Applications 后重新启动")
            return
        }

        // 只限制用户明确移到隐藏区的第三方应用，其余正在运行的应用继续显示。
        let allowed = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            .subtracting(hiddenIDs)
            .union([Bundle.main.bundleIdentifier ?? "io.github.sherlockwxd.barclean"])
            .sorted()
        isApplying = true
        bridge.apply(allowedBundleIDs: allowed) { [weak self] error in
            guard let self else { return }
            self.isApplying = false
            if let error {
                self.showError("图标未能收起：\(error.localizedDescription)")
            } else {
                self.collapsed = true
                self.updateIcon()
                self.startMouseWatch(visitedMenuBar: false)
            }
        }
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "BarClean"
        alert.informativeText = text
        alert.runModal()
    }

    @objc private func quit() {
        stopMouseWatch()
        bridge.release()
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MenuBarHider()
    app.delegate = delegate
    app.run()
}
