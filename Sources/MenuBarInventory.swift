import AppKit
import ApplicationServices

enum InventoryError: LocalizedError {
    case permissionRequired
    case agentUnavailable
    case readFailed(String, Int32)
    case noItems(String)
    case noVisibleItems

    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "请先在系统设置中授予辅助功能权限，然后重新读取菜单栏"
        case .agentUnavailable: return "找不到菜单栏服务；请稍后重新读取"
        case let .readFailed(stage, code): return "无法读取菜单栏\(stage)（辅助功能错误 \(code)）"
        case let .noItems(stage): return "菜单栏\(stage)没有可读取的项目；请展开后重新读取"
        case .noVisibleItems: return "没有找到屏幕上可见的菜单栏图标；请展开后重新读取"
        }
    }
}

struct DrawnMenuBarItem {
    let bundleID: String?
    let frame: CGRect
}

@MainActor
enum MenuBarInventory {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func read() throws -> [DrawnMenuBarItem] {
        guard isTrusted else { throw InventoryError.permissionRequired }
        guard let agentPID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.MenuBarAgent"
        ).first?.processIdentifier else { throw InventoryError.agentUnavailable }

        let agent = AXUIElementCreateApplication(agentPID)
        AXUIElementSetMessagingTimeout(agent, 2)
        let windows = try requiredChildren(of: agent, attribute: kAXWindowsAttribute, stage: "窗口")
        let items = try requiredChildren(of: windows[0], attribute: kAXChildrenAttribute, stage: "图标")

        let applications = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
                guard let id = app.bundleIdentifier else { return nil }
                return (app.processIdentifier, id)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
        let drawn = items.compactMap { item -> DrawnMenuBarItem? in
            guard let frame = frame(of: item), frame.width > 0, frame.height > 0,
                  isInMenuBar(frame, displays: displays), !isHidden(item) else { return nil }
            let pid = ownerPID(of: item, agentPID: agentPID)
            return DrawnMenuBarItem(bundleID: applications[pid], frame: frame)
        }
        guard !drawn.isEmpty else { throw InventoryError.noVisibleItems }
        return drawn.sorted { $0.frame.midX < $1.frame.midX }
    }

    private static func isInMenuBar(_ frame: CGRect, displays: [CGRect]) -> Bool {
        // MenuBarAgent 可能保留离屏项目；只接受落在任一屏幕顶部菜单栏区域的子项。
        displays.contains {
            $0.contains(CGPoint(x: frame.midX, y: frame.midY)) &&
            frame.minY >= $0.minY &&
            frame.maxY <= $0.minY + 48
        }
    }

    private static func isHidden(_ item: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXHiddenAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) == true
    }

    private static func requiredChildren(of element: AXUIElement, attribute: String,
                                         stage: String) throws -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { throw InventoryError.readFailed(stage, result.rawValue) }
        guard let children = value as? [AXUIElement], !children.isEmpty else {
            throw InventoryError.noItems(stage)
        }
        return children
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return []
        }
        return (value as? [AXUIElement]) ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(value as! AXValue, .cgRect, &rect) { return rect }
        }
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let position = value, CFGetTypeID(position) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let size = value, CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var dimensions = CGSize.zero
        guard AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private static func ownerPID(of item: AXUIElement, agentPID: pid_t) -> pid_t {
        var element = item
        for _ in 0..<8 {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { break }
            if pid != agentPID { return pid }
            guard let child = children(of: element, attribute: kAXChildrenAttribute).first else { break }
            element = child
        }
        return agentPID
    }
}
