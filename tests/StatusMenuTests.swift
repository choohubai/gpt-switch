import AppKit

@main
struct StatusMenuTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = StatusMenuController(parentPID: getpid(), iconPath: CommandLine.arguments[1])
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        assert(controller.statusItem?.menu?.items.map(\.title) == ["打开面板", "退出"])
        assert(controller.statusItem?.button?.image?.isValid == true)
        assert(controller.statusItem?.button?.image?.size == NSSize(width: 18, height: 18))
        var requests: [[String: Any]] = []
        controller.sendRequest = { requests.append($0) }
        controller.openPanel()
        assert(contextConversionLabel(200) == "200k")
        assert(contextConversionLabel(999) == "999k")
        assert(contextConversionLabel(1000) == "1M")
        assert(contextConversionLabel(1500) == "1.5M")
        assert(contextConversionLabel(1010) == "1.01M")
        assert(contextConversionLabel(10000) == "10M")
        assert(controller.table.tableColumns.map(\.identifier.rawValue) == ["id", "context", "converted"])
        assert(controller.table.tableColumns.map(\.title) == ["模型 ID", "上下文窗口", "会话大小"])
        assert(requests.last?["action"] as? String == "load")
        assert(controller.busy && !controller.saveButton.isEnabled)
        let original = [["id": "gpt-6-astra"]]
        controller.receive(["ok": true, "models": original])
        assert(controller.models.first?.id == "gpt-6-astra")
        assert(controller.models.first?.context == 272)
        let convertedColumn = controller.table.column(withIdentifier: NSUserInterfaceItemIdentifier("converted"))
        let convertedCell = controller.table.view(atColumn: convertedColumn, row: 0, makeIfNecessary: true) as! NSTableCellView
        assert(convertedCell.textField?.stringValue == "272k")
        let contextField = NSTextField(string: "10000")
        contextField.identifier = NSUserInterfaceItemIdentifier("context")
        contextField.tag = 0
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: contextField))
        assert(controller.models.first?.context == 10000)
        assert(convertedCell.textField?.stringValue == "10M")
        contextField.stringValue = "272"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: contextField))
        assert(controller.models.first?.context == 272)
        assert(convertedCell.textField?.stringValue == "272k")
        assert(!controller.saveButton.isEnabled && controller.restartButton.isEnabled)
        controller.addModel()
        assert(controller.models.count == 2 && controller.models.last?.context == 272 && controller.saveButton.isEnabled)
        let idField = NSTextField(string: "relay-test")
        idField.tag = 1
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: idField))
        controller.save()
        assert(requests.last?["restart"] as? Bool == false)
        let submitted = requests.last?["models"] as! [[String: Any]]
        assert(submitted.count == 2)
        assert(submitted[0]["id"] as? String == "gpt-6-astra")
        assert(submitted[0]["context"] as? Int == 272)
        assert(submitted[1]["id"] as? String == "relay-test")
        assert(submitted[1]["context"] as? Int == 272)
        assert(controller.busy && !controller.restartButton.isEnabled)
        controller.receive(["ok": false, "error": "模型 ID 重复"])
        assert(controller.models.count == 2 && controller.saveButton.isEnabled)
        controller.saveAndRestart()
        assert(requests.last?["restart"] as? Bool == true)
        controller.receive(["ok": false, "saved": true, "models": submitted, "error": "配置已保存，但重启失败"])
        assert(controller.models == controller.savedModels)
        assert(controller.restartButton.isEnabled)
        controller.receive(["ok": true, "saved": true, "restarted": false, "models": submitted])
        assert(controller.feedback.stringValue == "已保存，点击“保存并重启 ChatGPT”后生效")
        controller.saveAndRestart()
        controller.receive(["ok": true, "saved": true, "restarted": true, "models": submitted])
        assert(controller.feedback.stringValue == "已保存，ChatGPT 已重启")
        let sameWindow = controller.window
        controller.openPanel()
        assert(controller.window === sameWindow)
        controller.receive(["ok": true, "models": submitted])
        for row in [1, 0] {
            controller.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            controller.removeModel()
        }
        assert(controller.models.isEmpty && !controller.emptyLabel.isHidden)
        controller.saveAndRestart()
        assert((requests.last?["models"] as? [[String: Any]])?.isEmpty == true)
        controller.receive(["ok": true, "saved": true, "restarted": true, "models": []])
        assert(controller.windowShouldClose(controller.window!))
        let layoutWindow = controller.window!
        let layoutContent = layoutWindow.contentView!
        for width in [640, 720, 900] {
            layoutWindow.setContentSize(NSSize(width: width, height: 440))
            layoutContent.layoutSubtreeIfNeeded()
            controller.fitTableColumns()
            let visible = controller.table.enclosingScrollView?.contentSize.width ?? 0
            let lastColumn = controller.table.tableColumns.count - 1
            assert(controller.table.rect(ofColumn: lastColumn).maxX <= visible + 0.5,
                   "\(width) 宽度下最后一列超出可视区域")
        }
        controller.receive(["ok": true, "models": submitted])
        if CommandLine.arguments.count > 2, let window = controller.window, let content = window.contentView {
            for width in [640, 900] {
                window.setContentSize(NSSize(width: width, height: 440))
                content.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let image = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                content.cacheDisplay(in: content.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to:
                    URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("panel-\(width).png"))
            }
        }
        controller.window?.close()
        print("Swift menu, editing, save, restart feedback and empty-list checks passed.")
    }
}
