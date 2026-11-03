import AppKit
import ServiceManagement

private struct LayoutRow {
    let entries: [LayoutEntry]

    var representative: LayoutEntry { entries[0] }
}

@MainActor
final class SettingsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let store = LayoutStore()
    private let window: NSWindow
    private let hiddenTable = NSTableView()
    private let visibleTable = NSTableView()
    private let visibleMode = NSSegmentedControl(labels: ["当前", "未核验"], trackingMode: .selectOne, target: nil, action: nil)
    private let visibleSectionLabel = NSTextField(labelWithString: "常驻")
    private let visibleEmptyLabel = NSTextField(labelWithString: "")
    private let search = NSSearchField()
    private let message = NSTextField(labelWithString: "")
    private let iconStylePopup = NSPopUpButton()
    private let iconPreview = NSImageView()
    private let autoCollapseButton = NSButton(checkboxWithTitle: "移开菜单栏 5 秒后收起", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let launchAtLoginStatus = NSTextField(labelWithString: "")
    private let loginSettingsButton = NSButton(title: "打开登录项设置…", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "辅助功能…", target: nil, action: nil)
    private let grantButton = NSButton(title: "授权布局文件…", target: nil, action: nil)
    private let reloadButton = NSButton(title: "重新读取", target: nil, action: nil)
    private let applyButton = NSButton(title: "应用排序", target: nil, action: nil)
    private var order: [LayoutEntry] = []
    private var originalOrder: [LayoutEntry] = []
    private var drawnIDs: Set<String>?
    private var inventoryFailure: String?
    private var hiddenIDs: Set<String>
    private let onApply: (Set<String>) -> Void
    private let onPreferencesChanged: (StatusIconStyle, Bool) -> Void
    private let onClose: () -> Void

    init(hiddenIDs: Set<String>, iconStyle: StatusIconStyle, autoCollapseEnabled: Bool,
         onApply: @escaping (Set<String>) -> Void,
         onPreferencesChanged: @escaping (StatusIconStyle, Bool) -> Void,
         onClose: @escaping () -> Void) {
        self.hiddenIDs = hiddenIDs
        self.onApply = onApply
        self.onPreferencesChanged = onPreferencesChanged
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildWindow()
        iconStylePopup.selectItem(at: StatusIconStyle.allCases.firstIndex(of: iconStyle) ?? 0)
        iconPreview.image = iconStyle.image(collapsed: true)
        autoCollapseButton.state = autoCollapseEnabled ? .on : .off
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        reload()
        refreshLaunchAtLogin()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        window.title = "BarClean"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 420)
        window.center()

        let title = NSTextField(labelWithString: "菜单栏布局")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        search.placeholderString = "查找图标"
        search.target = self
        search.action = #selector(searchChanged)
        search.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let header = NSStackView(views: [title, NSView(), search])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let iconLabel = NSTextField(labelWithString: "收纳图标")
        iconLabel.font = .systemFont(ofSize: 13)
        for style in StatusIconStyle.allCases {
            iconStylePopup.addItem(withTitle: style.title)
            iconStylePopup.lastItem?.image = style.image(collapsed: true)
        }
        iconStylePopup.target = self
        iconStylePopup.action = #selector(preferencesChanged)
        iconStylePopup.widthAnchor.constraint(equalToConstant: 142).isActive = true
        iconPreview.imageScaling = .scaleProportionallyDown
        iconPreview.widthAnchor.constraint(equalToConstant: 38).isActive = true
        iconPreview.heightAnchor.constraint(equalToConstant: 24).isActive = true
        autoCollapseButton.target = self
        autoCollapseButton.action = #selector(preferencesChanged)
        let preferences = NSStackView(views: [
            iconLabel, iconStylePopup, iconPreview, NSView(), autoCollapseButton
        ])
        preferences.orientation = .horizontal
        preferences.alignment = .centerY
        preferences.spacing = 10

        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(launchAtLoginChanged)
        launchAtLoginStatus.textColor = .secondaryLabelColor
        loginSettingsButton.target = self
        loginSettingsButton.action = #selector(openLoginSettings)
        let loginOptions = NSStackView(views: [
            launchAtLoginButton, launchAtLoginStatus, NSView(), loginSettingsButton
        ])
        loginOptions.orientation = .horizontal
        loginOptions.alignment = .centerY
        loginOptions.spacing = 10

        configure(hiddenTable)
        configure(visibleTable)
        visibleMode.selectedSegment = 0
        visibleMode.target = self
        visibleMode.action = #selector(visibleModeChanged)
        visibleMode.toolTip = "切换当前可确认显示的应用与尚未核验的布局记录"
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(section("隐藏", table: hiddenTable))
        split.addArrangedSubview(section("常驻", table: visibleTable))

        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility)
        grantButton.target = self
        grantButton.action = #selector(grantAccess)
        reloadButton.target = self
        reloadButton.action = #selector(reloadLayout)
        applyButton.target = self
        applyButton.action = #selector(applyOrder)
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"

        message.lineBreakMode = .byTruncatingTail
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [message, accessibilityButton, grantButton, reloadButton, applyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        let root = NSView()
        window.contentView = root
        for view in [header, preferences, loginOptions, split, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.heightAnchor.constraint(equalToConstant: 42),
            preferences.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            preferences.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            preferences.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            preferences.heightAnchor.constraint(equalToConstant: 36),
            loginOptions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            loginOptions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            loginOptions.topAnchor.constraint(equalTo: preferences.bottomAnchor),
            loginOptions.heightAnchor.constraint(equalToConstant: 30),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            split.topAnchor.constraint(equalTo: loginOptions.bottomAnchor, constant: 10),
            split.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            footer.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func section(_ name: String, table: NSTableView) -> NSView {
        let label = table === visibleTable ? visibleSectionLabel : NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        let section = NSView()
        for view in [label, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            section.addSubview(view)
        }
        if table === visibleTable {
            visibleMode.translatesAutoresizingMaskIntoConstraints = false
            section.addSubview(visibleMode)
            visibleEmptyLabel.textColor = .secondaryLabelColor
            visibleEmptyLabel.alignment = .center
            visibleEmptyLabel.lineBreakMode = .byWordWrapping
            visibleEmptyLabel.maximumNumberOfLines = 3
            visibleEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
            section.addSubview(visibleEmptyLabel)
            NSLayoutConstraint.activate([
                visibleMode.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: -8),
                visibleMode.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: visibleMode.leadingAnchor, constant: -8),
                visibleEmptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                visibleEmptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
                visibleEmptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -32),
            ])
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: section.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: section.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            section.widthAnchor.constraint(greaterThanOrEqualToConstant: 270),
        ])
        return section
    }

    private func configure(_ table: NSTableView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("icon"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.string])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
    }

    private func rows(in table: NSTableView) -> [LayoutRow] {
        let hidden = table === hiddenTable
        var seen = Set<String>()
        return order.compactMap { entry -> LayoutRow? in
            guard let id = entry.bundleID else { return nil }
            let configuredHidden = entry.bundleID.map(hiddenIDs.contains) ?? false
            let drawn = entry.bundleID.map { drawnIDs?.contains($0) ?? false } ?? false
            let included = hidden ? configuredHidden :
                (!configuredHidden && (visibleMode.selectedSegment == 0 ? drawn : !drawn))
            guard included,
                  search.stringValue.isEmpty || entry.title.localizedCaseInsensitiveContains(search.stringValue) else {
                return nil
            }
            guard seen.insert(id).inserted else { return nil }
            // 隐藏机制以应用为单位，多个 tag 共用一行，但原始记录仍用于排序与诊断。
            return LayoutRow(entries: order.filter { $0.bundleID == id })
        }
    }

    private func reload() {
        drawnIDs = nil
        inventoryFailure = nil
        do {
            order = try store.read()
            originalOrder = order
            if !MenuBarInventory.isTrusted {
                let failure = "需要辅助功能权限才能读取当前菜单栏"
                inventoryFailure = failure
                message.stringValue = failure
            } else {
                do {
                    drawnIDs = Set(try MenuBarInventory.read().compactMap(\.bundleID))
                    message.stringValue = ""
                } catch {
                    let failure = error.localizedDescription
                    inventoryFailure = failure
                    message.stringValue = failure
                }
            }
        } catch {
            order = []
            originalOrder = []
            inventoryFailure = error.localizedDescription
            message.stringValue = error.localizedDescription
        }
        accessibilityButton.isHidden = MenuBarInventory.isTrusted
        grantButton.isHidden = store.hasAccess && !order.isEmpty
        reloadButton.isEnabled = store.hasAccess
        updateApplyButton()
        hiddenTable.reloadData()
        visibleTable.reloadData()
        updateVisibleState()
    }

    private func needsSorting() -> Bool {
        let counts = Dictionary(grouping: order.compactMap(\.bundleID), by: { $0 }).mapValues(\.count)
        let eligible = { (entry: LayoutEntry) -> Bool in
            entry.bundleID.map {
                !self.hiddenIDs.contains($0) && self.drawnIDs?.contains($0) == true && counts[$0] == 1
            } ?? false
        }
        return originalOrder.filter(eligible).map(\.tag) != order.filter(eligible).map(\.tag)
    }

    private func updateApplyButton() {
        let sorting = needsSorting()
        applyButton.title = sorting ? "应用排序" : "保存隐藏设置"
        applyButton.isEnabled = store.hasAccess && !order.isEmpty && (!sorting || MenuBarInventory.isTrusted)
        if sorting && !MenuBarInventory.isTrusted {
            message.stringValue = "排序需要辅助功能权限"
        }
    }

    @objc private func requestAccessibility() {
        MenuBarInventory.requestPermission()
        message.stringValue = "请在系统设置中授权本应用，返回后点击“重新读取”"
    }

    @objc private func searchChanged() {
        hiddenTable.reloadData()
        visibleTable.reloadData()
        updateVisibleState()
    }

    @objc private func preferencesChanged() {
        let style = StatusIconStyle.allCases[iconStylePopup.indexOfSelectedItem]
        iconPreview.image = style.image(collapsed: true)
        onPreferencesChanged(style, autoCollapseButton.state == .on)
    }

    private func refreshLaunchAtLogin() {
        // 登录项可能在系统设置中被禁用，始终以系统登记状态为准。
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
        let status = SMAppService.mainApp.status
        launchAtLoginButton.isEnabled = installed
        launchAtLoginButton.state = installed && (status == .enabled || status == .requiresApproval) ? .on : .off
        launchAtLoginStatus.stringValue = !installed ? "请从 /Applications 启动后设置" :
            status == .requiresApproval ? "需要在系统设置中批准" :
            status == .notFound ? "无法读取登录项状态" : ""
        loginSettingsButton.isHidden = !installed || status != .requiresApproval
    }

    @objc private func launchAtLoginChanged() {
        let service = SMAppService.mainApp
        do {
            if launchAtLoginButton.state == .on {
                try service.register()
            } else {
                try service.unregister()
            }
            refreshLaunchAtLogin()
        } catch {
            refreshLaunchAtLogin()
            message.stringValue = "无法更改登录项：\(error.localizedDescription)"
        }
    }

    @objc private func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshLaunchAtLogin()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.onClose()
        }
    }

    @objc private func visibleModeChanged() {
        visibleTable.reloadData()
        updateVisibleState()
    }

    private func updateVisibleState() {
        let current = visibleMode.selectedSegment == 0
        visibleSectionLabel.stringValue = current ? "常驻" : "未核验记录"
        visibleEmptyLabel.stringValue = current
            ? (inventoryFailure ?? "当前没有可确认显示的应用图标")
            : "没有未核验的布局记录"
        visibleEmptyLabel.isHidden = !rows(in: visibleTable).isEmpty
    }

    @objc private func grantAccess() {
        do {
            try store.requestAccess()
            reload()
        } catch {
            message.stringValue = error.localizedDescription
        }
    }

    @objc private func reloadLayout() {
        reload()
    }

    @objc private func applyOrder() {
        guard store.hasAccess, !order.isEmpty else { return }
        let sorting = needsSorting()
        guard !sorting || MenuBarInventory.isTrusted else { return }
        let alert = NSAlert()
        alert.messageText = sorting ? "应用菜单栏排序？" : "保存隐藏设置？"
        alert.informativeText = sorting
            ? "仅对可核验的第三方常驻图标排序；写入前会备份布局，失败后尝试恢复。菜单栏服务可能短暂重启。"
            : "同一应用的所有菜单栏图标会一起隐藏或显示。"
        alert.addButton(withTitle: sorting ? "应用排序" : "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applyButton.isEnabled = false
        message.stringValue = sorting ? "正在核对实际菜单栏…" : "正在保存隐藏设置…"
        Task { @MainActor in
            do {
                if sorting {
                    let drawn = try MenuBarInventory.read()
                    let visibleIDs = Set(drawn.compactMap(\.bundleID)).subtracting(hiddenIDs)
                    _ = try await store.apply(order: order.map(\.tag), visibleBundleIDs: visibleIDs)
                    originalOrder = order
                }
                UserDefaults.standard.set(hiddenIDs.sorted(), forKey: "hiddenBundleIdentifiers")
                onApply(hiddenIDs)
                message.stringValue = sorting ? "已核验常驻图标的实际顺序" : "隐藏设置已保存；未修改系统图标顺序"
            } catch {
                message.stringValue = error.localizedDescription
            }
            updateApplyButton()
        }
    }

    private func move(_ tag: String, to table: NSTableView, before target: String?) -> Bool {
        guard let entry = order.first(where: { $0.tag == tag }) else { return false }
        let hide = table === hiddenTable
        guard let id = entry.bundleID else {
            message.stringValue = "暂不支持移动系统图标"
            return false
        }
        let members = order.filter { $0.bundleID == entry.bundleID }
        if members.count > 1 && hiddenIDs.contains(id) == hide {
            message.stringValue = "同一应用的多条记录暂不支持组内排序"
            return false
        }
        let memberTags = Set(members.map(\.tag))
        var nextHidden = hiddenIDs
        if hide { nextHidden.insert(id) } else { nextHidden.remove(id) }
        var concealed = order.filter { ($0.bundleID.map(nextHidden.contains) ?? false) && !memberTags.contains($0.tag) }
        var visible = order.filter { !($0.bundleID.map(nextHidden.contains) ?? false) && !memberTags.contains($0.tag) }
        var destination = hide ? concealed : visible
        let index = target.flatMap { value in destination.firstIndex(where: { $0.tag == value }) }
            ?? destination.count
        destination.insert(contentsOf: members, at: index)
        if hide { concealed = destination } else { visible = destination }
        hiddenIDs = nextHidden
        order = concealed + visible
        message.stringValue = members.count > 1 ? "多条记录只切换隐藏状态，不执行组内排序" : ""
        if !hide && drawnIDs?.contains(id) != true {
            visibleMode.selectedSegment = 1
        }
        hiddenTable.reloadData()
        visibleTable.reloadData()
        updateVisibleState()
        updateApplyButton()
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows(in: tableView).count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let group = rows(in: tableView)[row]
        let entry = group.representative
        let cell = NSTableCellView()
        let icon = NSImageView(image: entry.icon ?? NSImage())
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: entry.title)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        let count = NSTextField(labelWithString: "\(group.entries.count) 条记录")
        count.textColor = .secondaryLabelColor
        count.font = .systemFont(ofSize: 11)
        count.translatesAutoresizingMaskIntoConstraints = false
        if group.entries.count > 1 { cell.addSubview(count) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 23),
            icon.heightAnchor.constraint(equalToConstant: 23),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: group.entries.count > 1 ? -8 : 0),
        ])
        if group.entries.count > 1 {
            NSLayoutConstraint.activate([
                count.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                count.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
            ])
        }
        cell.toolTip = group.entries.map(\.tag).joined(separator: "\n")
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if tableView === visibleTable && visibleMode.selectedSegment == 1 { return nil }
        return rows(in: tableView)[row].representative.tag as NSString
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let source = info.draggingSource as? NSTableView,
              let tag = info.draggingPasteboard.string(forType: .string),
              let entry = order.first(where: { $0.tag == tag }),
              entry.bundleID != nil else { return [] }
        if tableView === visibleTable && visibleMode.selectedSegment == 1 { return [] }
        if source === tableView && (tableView === hiddenTable ||
                                   order.filter({ $0.bundleID == entry.bundleID }).count > 1) {
            return []
        }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if tableView === visibleTable && visibleMode.selectedSegment == 1 { return false }
        guard let tag = info.draggingPasteboard.string(forType: .string) else { return false }
        let destination = rows(in: tableView)
        return move(tag, to: tableView, before: row < destination.count ? destination[row].representative.tag : nil)
    }
}
