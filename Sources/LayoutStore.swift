import AppKit

struct LayoutEntry: Identifiable, Hashable {
    let tag: String
    let title: String
    let bundleID: String?

    var id: String { tag }

    var icon: NSImage? {
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let symbol = tag.localizedCaseInsensitiveContains("wifi") ? "wifi" : "square.grid.2x2"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}

enum LayoutError: LocalizedError {
    case noAccess
    case invalidFile
    case noItems
    case cannotWrite
    case restartFailed
    case verificationFailed
    case liveOrderUnavailable
    case staleOrder

    var errorDescription: String? {
        switch self {
        case .noAccess: return "需要先授权读取菜单栏布局文件"
        case .invalidFile: return "所选文件不是当前 macOS 的菜单栏布局文件"
        case .noItems: return "布局文件中没有可排序的菜单栏图标"
        case .cannotWrite: return "无法写入系统布局；原布局未修改或已恢复"
        case .restartFailed: return "菜单栏服务未能刷新；已尝试恢复原布局"
        case .verificationFailed: return "实际菜单栏顺序没有按要求变化；已尝试恢复原布局"
        case .liveOrderUnavailable: return "只支持当前可见且可唯一识别的第三方图标排序；请先展开菜单栏并重新读取"
        case .staleOrder: return "布局文件与实际菜单栏顺序不一致；已停止写入以避免误排"
        }
    }
}

@MainActor
final class LayoutStore {
    private static let bookmarkKey = "menuBarLayoutBookmark"
    private static let positionsKey = "TrailingItemPreferredPositions"
    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")

    private var scopedURL: URL?

    init() {
        restoreBookmark()
    }

    var hasAccess: Bool { scopedURL != nil }

    func requestAccess() throws {
        let panel = NSOpenPanel()
        panel.title = "授权菜单栏布局"
        panel.message = "请选择 com.apple.MenuBar.plist；应用仅在你点击“应用排序”后修改这个文件。"
        panel.prompt = "授权此文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.fileURL.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        guard selected.standardizedFileURL.path == Self.fileURL.standardizedFileURL.path else {
            throw LayoutError.invalidFile
        }
        let data = try selected.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        restoreBookmark()
        guard hasAccess else { throw LayoutError.noAccess }
        _ = try read()
    }

    func read() throws -> [LayoutEntry] {
        let (_, positions, _) = try snapshot()
        let runningNames = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier else { return nil }
                return (id, app.localizedName ?? id)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let tags = positions.keys.sorted {
            let left = positions[$0] ?? 0
            let right = positions[$1] ?? 0
            return left == right ? $0 < $1 : left > right
        }
        return tags.map { tag in
            let bundleID = Self.bundleID(for: tag)
            let title: String
            if let bundleID {
                title = runningNames[bundleID] ?? bundleID.components(separatedBy: ".").last ?? bundleID
            } else {
                title = tag.components(separatedBy: ".").last ?? tag
            }
            return LayoutEntry(tag: tag, title: title, bundleID: bundleID)
        }
    }

    func apply(order: [String], visibleBundleIDs: Set<String>) async throws -> Bool {
        let (original, positions, propertyList) = try snapshot()
        guard Set(order) == Set(positions.keys), order.count == positions.count else {
            throw LayoutError.verificationFailed
        }
        let originalOrder = Self.sortedTags(in: positions)
        let counts = Dictionary(
            grouping: positions.keys.compactMap(Self.bundleID(for:)),
            by: { $0 }
        ).mapValues(\.count)
        let eligible = { (tag: String) -> Bool in
            Self.bundleID(for: tag).map { visibleBundleIDs.contains($0) && counts[$0] == 1 } ?? false
        }
        let before = originalOrder.filter(eligible)
        let after = order.filter(eligible)
        // 隐藏状态由独立机制处理；只有可见图标顺序变化才修改系统布局。
        guard before != after else { return false }
        let beforeIDs = before.compactMap(Self.bundleID(for:))
        let afterIDs = after.compactMap(Self.bundleID(for:))
        guard Set(beforeIDs).count == beforeIDs.count,
              Set(afterIDs) == Set(beforeIDs),
              let liveOrder = observedOrder(of: Set(beforeIDs)) else {
            throw LayoutError.liveOrderUnavailable
        }
        guard liveOrder == beforeIDs else { throw LayoutError.staleOrder }

        let backupFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BarClean")
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let backup = backupFolder.appendingPathComponent("layout-backup.plist")
        try original.write(to: backup, options: .atomic)

        var nextPositions = positions
        let slots = before.compactMap { positions[$0] }
        guard Set(slots).count == slots.count else { throw LayoutError.liveOrderUnavailable }
        for (index, tag) in after.enumerated() {
            nextPositions[tag] = slots[index]
        }
        var updated = propertyList
        updated[Self.positionsKey] = nextPositions
        let format: PropertyListSerialization.PropertyListFormat =
            original.starts(with: Data("bplist".utf8)) ? .binary : .xml
        let data = try PropertyListSerialization.data(fromPropertyList: updated, format: format, options: 0)
        do {
            try write(data)
            let (_, recorded, _) = try snapshot()
            guard Self.sortedTags(in: recorded).filter(eligible) == after else {
                throw LayoutError.verificationFailed
            }
            guard restartAgent() else { throw LayoutError.restartFailed }
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 300_000_000)
                if observedOrder(of: Set(afterIDs)) == afterIDs { return true }
            }
            throw LayoutError.verificationFailed
        } catch {
            if (try? write(original)) != nil { _ = restartAgent() }
            if error is LayoutError { throw error }
            throw LayoutError.cannotWrite
        }
    }

    private static func sortedTags(in positions: [String: Double]) -> [String] {
        positions.keys.sorted {
            let left = positions[$0] ?? 0
            let right = positions[$1] ?? 0
            return left == right ? $0 < $1 : left > right
        }
    }

    private func observedOrder(of ids: Set<String>) -> [String]? {
        guard let items = try? MenuBarInventory.read() else { return nil }
        let visible = items.filter { $0.bundleID.map(ids.contains) ?? false }
        guard visible.count == ids.count, Set(visible.compactMap(\.bundleID)) == ids,
              let first = visible.first, visible.allSatisfy({
                  abs($0.frame.midY - first.frame.midY) < 10
              }) else { return nil }
        return visible.compactMap(\.bundleID)
    }

    private func snapshot() throws -> (Data, [String: Double], [String: Any]) {
        guard let scopedURL else { throw LayoutError.noAccess }
        let data = try Data(contentsOf: scopedURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let raw = plist[Self.positionsKey] as? [String: Any] else {
            throw LayoutError.invalidFile
        }
        let positions = raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
            .filter { $0.value > 0 }
        guard !positions.isEmpty else { throw LayoutError.noItems }
        return (data, positions, plist)
    }

    private func write(_ data: Data) throws {
        guard let scopedURL else { throw LayoutError.noAccess }
        // 授权仅覆盖选中的文件，因此用已授权的文件句柄写入，并在上层保留原文件备份。
        let handle = try FileHandle(forWritingTo: scopedURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func restartAgent() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/com.apple.MenuBarAgent"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.standardizedFileURL.path == Self.fileURL.standardizedFileURL.path,
              url.startAccessingSecurityScopedResource() else { return }
        scopedURL = url
        if stale, let renewed = try? url.bookmarkData(options: [.withSecurityScope],
                                                       includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(renewed, forKey: Self.bookmarkKey)
        }
    }

    private static func bundleID(for tag: String) -> String? {
        let id: String
        if tag.hasPrefix("status:") {
            id = String(tag.dropFirst("status:".count)).components(separatedBy: "::")[0]
        } else if tag.contains(":Item-") {
            id = tag.components(separatedBy: ":Item-")[0]
        } else {
            return nil
        }
        guard !id.isEmpty, !id.hasPrefix("com.apple.") else { return nil }
        return id
    }
}
