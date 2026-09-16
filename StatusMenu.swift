import AppKit

/// Colors and type scale sampled from the Codex desktop UI. The light values are measured
/// from a live window; the dark values keep the same surface hierarchy.
enum CodexTheme {
    static let surface = dynamic(light: 0xFDFDFD, dark: 0x1B1B1D)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x232326)
    static let subtle = dynamic(light: 0xEDEDEE, dark: 0x333336)
    static let border = dynamic(light: 0xEDEDEE, dark: 0x3A3A3D)
    static let text = dynamic(light: 0x212327, dark: 0xF2F2F4)
    static let secondaryText = dynamic(light: 0x656667, dark: 0xA6A6AA)
    static let tertiaryText = dynamic(light: 0x88898A, dark: 0x8E8E93)
    static let primaryButton = dynamic(light: 0x212327, dark: 0xF2F2F4)
    static let primaryButtonText = dynamic(light: 0xFFFFFF, dark: 0x1B1B1D)

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Flat pill button matching the Codex action buttons: gray for secondary actions,
/// near-black for the primary action.
final class CodexPillButton: NSButton {
    private let fill: NSColor
    private let foreground: NSColor
    private let label: String

    init(title: String, primary: Bool) {
        label = title
        fill = primary ? CodexTheme.primaryButton : CodexTheme.subtle
        foreground = primary ? CodexTheme.primaryButtonText : CodexTheme.text
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        font = .systemFont(ofSize: 12, weight: primary ? .semibold : .regular)
        let titleWidth = (title as NSString).size(withAttributes: [.font: font as Any]).width
        widthAnchor.constraint(equalToConstant: (titleWidth + 24).rounded(.up)).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyTheme()
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool { didSet { applyTheme() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.opacity = flag ? 0.75 : 1
    }

    private func applyTheme() {
        setAccessibilityLabel(label)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let resolvedFill = fill.usingColorSpace(.sRGB) ?? fill
            let resolvedForeground = foreground.usingColorSpace(.sRGB) ?? foreground
            layer?.backgroundColor = (isEnabled ? resolvedFill : resolvedFill.withAlphaComponent(0.4)).cgColor
            attributedTitle = NSAttributedString(string: label, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: isEnabled ? resolvedForeground : resolvedForeground.withAlphaComponent(0.45),
            ])
        }
    }
}

struct ModelRow: Codable, Equatable {
    var id: String
    var context: Int

    init(id: String, context: Int = 272) {
        self.id = id
        self.context = context
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        context = try container.decodeIfPresent(Int.self, forKey: .context) ?? 272
    }
}

func contextConversionLabel(_ k: Int) -> String {
    if k < 1000 { return "\(k)k" }
    if k % 1000 == 0 { return "\(k / 1000)M" }
    var frac = String(k % 1000)
    while frac.count < 3 { frac = "0" + frac }
    while frac.last == "0" { frac.removeLast() }
    return "\(k / 1000).\(frac)M"
}

final class StatusMenuController: NSObject, NSApplicationDelegate, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let parentPID: pid_t
    let iconPath: String
    var statusItem: NSStatusItem?
    var parentMonitor: Timer?
    var window: NSWindow?
    let table = NSTableView()
    let feedback = NSTextField(wrappingLabelWithString: "")
    let emptyLabel = NSTextField(labelWithString: "暂无自定义模型")
    let emptyState = NSStackView()
    let addButton = NSButton()
    let removeButton = NSButton()
    let saveButton = CodexPillButton(title: "保存", primary: false)
    let restartButton = CodexPillButton(title: "保存并重启 ChatGPT", primary: true)
    var models: [ModelRow] = []
    var savedModels: [ModelRow] = []
    var loaded = false
    var busy = false
    var sendRequest: ([String: Any]) -> Void = { message in
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }

    init(parentPID: pid_t, iconPath: String) {
        self.parentPID = parentPID
        self.iconPath = iconPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(contentsOfFile: iconPath)
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true
        statusItem?.button?.image = icon
        statusItem?.button?.imageScaling = .scaleProportionallyDown
        statusItem?.button?.toolTip = "ChatGPT自定义模型"
        statusItem?.button?.setAccessibilityLabel("ChatGPT自定义模型")
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开面板", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "退出", action: #selector(quitPlugin), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
        parentMonitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if self.parentPID > 1 && kill(self.parentPID, 0) != 0 && errno == ESRCH {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        parentMonitor?.invalidate()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    @objc func openPanel() {
        if window == nil { buildPanel() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if !busy && models == savedModels {
            busy = true
            setFeedback("正在读取配置…")
            updateControls()
            sendRequest(["action": "load"])
        }
    }

    func buildPanel() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        panel.title = "ChatGPT自定义模型"
        panel.minSize = NSSize(width: 640, height: 420)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.backgroundColor = CodexTheme.surface
        panel.center()
        window = panel
        guard let content = panel.contentView else { return }

        let heading = NSTextField(labelWithString: "模型配置")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = CodexTheme.text
        let subtitle = NSTextField(labelWithString: "自定义模型 ID 与上下文窗口，保存并重启后在新任务中生效")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = CodexTheme.secondaryText
        let titles = NSStackView(views: [heading, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 3
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configureIconButton(addButton, symbol: "plus", label: "添加模型", action: #selector(addModel))
        configureIconButton(removeButton, symbol: "minus", label: "删除选中模型", action: #selector(removeModel))
        let headerActions = NSStackView(views: [addButton, removeButton])
        headerActions.spacing = 6
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = NSStackView(views: [titles, headerSpacer, headerActions])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.distribution = .fill

        let idColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("id"))
        idColumn.title = "模型 ID"
        idColumn.width = 520
        idColumn.minWidth = 200
        let contextColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("context"))
        contextColumn.title = "上下文窗口"
        contextColumn.width = 128
        contextColumn.minWidth = 120
        contextColumn.maxWidth = 160
        let convertedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("converted"))
        convertedColumn.title = "会话大小"
        convertedColumn.width = 96
        convertedColumn.minWidth = 88
        convertedColumn.maxWidth = 120
        table.addTableColumn(idColumn)
        table.addTableColumn(contextColumn)
        table.addTableColumn(convertedColumn)
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 40
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = false
        table.allowsEmptySelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false

        let card = NSBox()
        card.boxType = .custom
        card.titlePosition = .noTitle
        card.cornerRadius = 12
        card.borderWidth = 1
        card.borderColor = CodexTheme.border
        card.fillColor = CodexTheme.card
        card.contentViewMargins = NSSize(width: 0, height: 0)
        card.contentView = scroll

        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(systemSymbolName: "square.stack.3d.up",
                                  accessibilityDescription: "暂无自定义模型")
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        emptyIcon.contentTintColor = CodexTheme.tertiaryText
        emptyLabel.textColor = CodexTheme.text
        let emptyHint = NSTextField(labelWithString: "点击右上角 + 添加模型，例如 gpt-6-astra")
        emptyHint.font = .systemFont(ofSize: 11)
        emptyHint.textColor = CodexTheme.tertiaryText
        emptyState.setViews([emptyIcon, emptyLabel, emptyHint], in: .top)
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8

        let hint = NSTextField(labelWithString: "窗口单位 k：1000k = 1M，保存后需重启 ChatGPT/Codex 才生效")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = CodexTheme.tertiaryText

        saveButton.target = self
        saveButton.action = #selector(save)
        restartButton.target = self
        restartButton.action = #selector(saveAndRestart)
        restartButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [saveButton, restartButton])
        buttons.spacing = 8
        feedback.font = .systemFont(ofSize: 12)
        feedback.textColor = CodexTheme.secondaryText
        feedback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        feedback.setContentHuggingPriority(.defaultLow, for: .horizontal)
        feedback.lineBreakMode = .byTruncatingTail
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let footer = NSStackView(views: [feedback, footerSpacer, buttons])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.distribution = .fill

        for view in [header, card, hint, footer, emptyState] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            card.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -10),
            hint.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            footer.heightAnchor.constraint(equalToConstant: 32),
            emptyState.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 16),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),
        ])
        updateControls()
    }

    func configureIconButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.bezelStyle = .accessoryBarAction
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { models.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let cell = NSTableCellView()
        let kind = tableColumn.identifier.rawValue
        let isContext = kind == "context"
        let isConverted = kind == "converted"
        let value = isConverted ? contextConversionLabel(models[row].context)
            : isContext ? String(models[row].context) : models[row].id
        let field = isConverted ? NSTextField(labelWithString: value) : NSTextField(string: value)
        field.identifier = tableColumn.identifier
        field.tag = row
        if !isConverted {
            field.delegate = self
            field.isEditable = !busy && loaded
        }
        field.isBordered = false
        field.drawsBackground = false
        field.alignment = (isContext || isConverted) ? .right : .natural
        if isContext || isConverted {
            field.font = .monospacedDigitSystemFont(ofSize: isConverted ? 12 : 13, weight: .regular)
        } else {
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        field.textColor = isConverted ? CodexTheme.secondaryText : CodexTheme.text
        field.setAccessibilityLabel("第 \(row + 1) 行\(tableColumn.title)")
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, !busy else { return }
        let row = field.tag
        guard models.indices.contains(row) else { return }
        if field.identifier?.rawValue == "context" {
            if let value = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), value >= 1 {
                models[row].context = value
                let convertedIndex = table.column(withIdentifier: NSUserInterfaceItemIdentifier("converted"))
                if convertedIndex >= 0,
                   let cell = table.view(atColumn: convertedIndex, row: row, makeIfNecessary: false) as? NSTableCellView {
                    cell.textField?.stringValue = contextConversionLabel(value)
                }
            }
        } else {
            models[row].id = field.stringValue
        }
        setFeedback(models == savedModels ? "" : "有未保存的更改")
        updateControls()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }

    @objc func addModel() {
        guard loaded && !busy else { return }
        window?.makeFirstResponder(nil)
        models.append(ModelRow(id: "", context: 272))
        table.reloadData()
        let row = models.count - 1
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView {
            window?.makeFirstResponder(cell.textField)
        }
        setFeedback("有未保存的更改")
        updateControls()
    }

    @objc func removeModel() {
        guard !busy && models.indices.contains(table.selectedRow) else { return }
        window?.makeFirstResponder(nil)
        models.remove(at: table.selectedRow)
        table.reloadData()
        setFeedback(models == savedModels ? "" : "有未保存的更改")
        updateControls()
    }

    @objc func save() { submit(restart: false) }
    @objc func saveAndRestart() { submit(restart: true) }

    func submit(restart: Bool) {
        guard loaded && !busy else { return }
        window?.makeFirstResponder(nil)
        busy = true
        setFeedback(restart ? "正在保存并重启 ChatGPT…" : "正在保存…")
        table.reloadData()
        updateControls()
        sendRequest(["action": "save", "restart": restart,
                     "models": models.map { ["id": $0.id, "context": $0.context] }])
    }

    func receive(_ response: [String: Any]) {
        busy = false
        let ok = response["ok"] as? Bool == true
        if ok || response["saved"] as? Bool == true {
            if let value = response["models"],
               let data = try? JSONSerialization.data(withJSONObject: value),
               let rows = try? JSONDecoder().decode([ModelRow].self, from: data) {
                models = rows
                savedModels = rows
                loaded = true
            }
        }
        if !ok {
            setFeedback(response["error"] as? String ?? "操作失败", error: true)
        } else if response["restarted"] as? Bool == true {
            setFeedback("已保存，ChatGPT 已重启")
        } else if response["saved"] as? Bool == true {
            setFeedback("已保存，点击“保存并重启 ChatGPT”后生效")
        } else {
            setFeedback("")
        }
        table.reloadData()
        updateControls()
    }

    func setFeedback(_ text: String, error: Bool = false) {
        feedback.stringValue = text
        feedback.textColor = error ? .systemRed : CodexTheme.secondaryText
    }

    func updateControls() {
        addButton.isEnabled = loaded && !busy
        removeButton.isEnabled = loaded && !busy && models.indices.contains(table.selectedRow)
        saveButton.isEnabled = loaded && !busy && models != savedModels
        restartButton.isEnabled = loaded && !busy
        let showEmptyState = loaded && models.isEmpty
        emptyLabel.isHidden = !showEmptyState
        emptyState.isHidden = !showEmptyState
        window?.isDocumentEdited = models != savedModels
    }

    func canDiscardChanges() -> Bool {
        guard !busy else { NSSound.beep(); return false }
        window?.makeFirstResponder(nil)
        guard models != savedModels else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃未保存的更改？"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃更改")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        models = savedModels
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { canDiscardChanges() }

    @objc func quitPlugin() {
        guard canDiscardChanges() else { return }
        if parentPID > 1 { kill(parentPID, SIGTERM) }
        NSApp.terminate(nil)
    }
}

#if !STATUS_MENU_TEST
@main
struct StatusMenuApp {
    static func main() {
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name),
                  index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        guard let parent = argument("--parent-pid").flatMap(Int32.init), parent > 1,
              let iconPath = argument("--icon-path") else { return }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let controller = StatusMenuController(parentPID: parent, iconPath: iconPath)
        application.delegate = controller
        DispatchQueue.global(qos: .utility).async {
            while let line = readLine() {
                guard let data = line.data(using: .utf8),
                      let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                DispatchQueue.main.async { controller.receive(response) }
            }
            DispatchQueue.main.async { application.terminate(nil) }
        }
        withExtendedLifetime(controller) { application.run() }
    }
}
#endif
