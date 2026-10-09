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
        // 没打开过面板就点「退出」时 store 还是 nil，不能把退出挡掉。
        assert(controller.store == nil)
        assert(controller.canDiscardChanges(), "面板没建过时退出要放行")
        var requests: [[String: Any]] = []
        controller.sendRequest = { requests.append($0) }
        controller.openPanel()
        assert(requests.last?["action"] as? String == "load")
        guard let store = controller.store else { throw TestFailure("面板没建出来") }
        assert(store.busy && !store.loaded)

        // 读回两个渠道：首页要列出全部，并标记当前渠道。
        store.apply(["ok": true, "channels": [
            ["id": "OpenAI", "name": "ChooHub", "baseUrl": "https://choohub.net/api-proxy/v1",
             "apiKey": "sk-choohub", "headerName": "x-openai-actor-authorization", "headerValue": "actor",
             "models": [["id": "gpt-6-astra"]]],
            ["id": "relay", "name": "", "baseUrl": "https://relay.example/v1",
             "apiKey": "sk-relay", "headerName": "", "headerValue": "",
             "models": [["id": "deepseek-v4-pro", "context": 1000]]],
        ], "current": "OpenAI"])
        assert(store.channels.count == 2)
        assert(store.currentChannelID == "OpenAI")
        assert(store.loaded && !store.busy)
        assert(store.editingIndex == nil, "读完配置应该停在列表页")
        assert(store.channels[0].models.first?.displayName == "", "老配置没有显示名称时留空")
        assert(store.channels[0].models.first?.inputModalities == ["text", "image"], "老配置默认文本+图片")

        // 程序坞图标要能把面板叫回来；从程序坞或 ⌘Q 来的退出请求只关窗口，不能把菜单栏图标带走。
        controller.window?.orderOut(nil)
        assert(controller.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        assert(controller.window?.isVisible == true, "点程序坞图标要把面板叫回来")
        assert(NSApp.activationPolicy() == .regular, "面板打开时程序坞里要有图标")
        // 面板重新读配置的请求由测试直接放行，免得后面的断言撞上 busy。
        store.busy = false
        assert(controller.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        assert(controller.window?.isVisible == false, "退出请求只关窗口，菜单栏进程要留着")
        assert(NSApp.activationPolicy() == .accessory, "关掉窗口就缩回菜单栏")

        // 首页「启用」：存盘 + 切渠道 + 重启。
        store.enableChannel(at: 1)
        assert(requests.last?["action"] as? String == "switch")
        assert(requests.last?["restart"] as? Bool == true)
        assert(requests.last?["current"] as? String == "relay")
        store.apply(["ok": true, "saved": true, "restarted": true, "channels": [
            ["id": "OpenAI", "baseUrl": "https://choohub.net/api-proxy/v1", "models": []],
            ["id": "relay", "baseUrl": "https://relay.example/v1", "models": []],
        ], "current": "relay"])
        assert(store.feedback == "已启用渠道，ChatGPT 已重启")

        // 进编辑页改模型：显示名称、窗口、输入类型都要落到渠道里。
        store.editChannel(at: 0)
        assert(store.editingTitle == "编辑渠道")
        store.channels[0].models = [ModelRow(id: "deepseek-v4-pro", context: 1000)]
        store.models[0].displayName = "DeepSeek V4"
        store.models[0].context = 10000
        assert(store.models[0].displayName == "DeepSeek V4")
        assert(store.models[0].context == 10000)
        assert(contextConversionLabel(10000) == "10M")
        store.toggleModality(at: 0, modality: "image", on: false)
        assert(store.models[0].inputModalities == ["text"])
        store.toggleModality(at: 0, modality: "text", on: false)
        assert(store.models[0].inputModalities == ["text"], "最后一个输入类型不能被取消")
        store.toggleModality(at: 0, modality: "image", on: true)
        assert(store.models[0].inputModalities == ["text", "image"])

        store.addModel()
        assert(store.models.count == 2)
        store.removeModel(at: 1)
        assert(store.models.count == 1)

        store.channels[0].id = "choohub"
        assert(store.isDirty)
        store.save()
        assert(requests.last?["action"] as? String == "save")
        assert(requests.last?["restart"] as? Bool == false)
        let submitted = requests.last?["channels"] as! [[String: Any]]
        assert(submitted.count == 2)
        assert(submitted[0]["id"] as? String == "choohub")
        let submittedModels = submitted[0]["models"] as! [[String: Any]]
        assert(submittedModels[0]["context"] as? Int == 10000)
        assert(submittedModels[0]["displayName"] as? String == "DeepSeek V4")
        assert(submittedModels[0]["inputModalities"] as? [String] == ["text", "image"])

        store.apply(["ok": true, "saved": true, "channels": [
            ["id": "choohub", "baseUrl": "https://choohub.net/api-proxy/v1",
             "models": [["id": "deepseek-v4-pro", "displayName": "DeepSeek V4", "context": 10000,
                         "inputModalities": ["text", "image"]]]],
            ["id": "relay", "baseUrl": "https://relay.example/v1", "models": []],
        ], "current": "relay"])
        assert(store.feedback == "已保存，点列表里的「启用」才会生效")
        assert(!store.isDirty)

        // 新增渠道进编辑页；删除后回列表。
        store.showList()
        store.addChannel()
        assert(store.channels.count == 3)
        assert(store.editingIndex == 2)
        assert(store.editingTitle == "添加渠道")
        store.channels[2].id = "gateway"
        assert(store.editingTitle == "编辑渠道")
        store.deleteChannel(at: 2)
        assert(store.channels.count == 2)

        // 清空：不动面板里的渠道列表，只发 clear。
        store.clearAndRestart()
        assert(requests.last?["action"] as? String == "clear")
        store.apply(["ok": true, "cleared": true, "restarted": true, "channels": [
            ["id": "choohub", "baseUrl": "https://choohub.net/api-proxy/v1", "models": []],
            ["id": "relay", "baseUrl": "https://relay.example/v1", "models": []],
        ], "current": NSNull()])
        assert(store.feedback == "已清空并重启 ChatGPT")
        assert(store.channels.count == 2, "清空只还原 Codex 侧，渠道列表要留着")
        assert(store.currentChannelID == nil)

        // 列表页重新打开面板会再发一次 load，回来后必须还停在列表页。
        store.showList()
        store.busy = true
        store.apply(["ok": true, "channels": [
            ["id": "choohub", "baseUrl": "https://choohub.net/api-proxy/v1", "models": []],
            ["id": "relay", "baseUrl": "https://relay.example/v1", "models": []],
        ], "current": "relay"])
        assert(store.editingIndex == nil, "列表页刷新配置后不能跳进编辑页")

        // 版本比较和更新按钮。
        assert(isVersion("0.1.33", newerThan: "0.1.32"))
        assert(!isVersion("0.1.31", newerThan: "0.1.32"))
        store.checkForUpdates()
        assert(requests.last?["action"] as? String == "check-update")
        store.apply(["ok": true, "latest": "0.1.33", "url": "https://example.com/release"])
        assert(store.updateTitle == "去下载 v0.1.33")

        // 错误响应要落到反馈里，并解除 busy。
        store.busy = true
        store.apply(["ok": false, "error": "测试用失败"])
        assert(store.feedback == "测试用失败" && store.feedbackIsError && !store.busy)

        // 返回列表必须了结未保存的改动：有改动先确认，放弃就回滚到已保存状态。
        store.editChannel(at: 0)
        store.channels[0].baseUrl = "https://changed.example/v1"
        assert(store.isDirty)
        store.requestLeaveEditor()
        assert(store.confirmingLeave, "有未保存改动时返回要先确认")
        assert(store.editingIndex == 0, "确认前不能离开编辑页")
        store.discardAndLeave()
        assert(store.editingIndex == nil)
        assert(!store.isDirty, "放弃更改后要回到已保存状态")
        assert(store.feedback.isEmpty, "列表页不该挂着编辑页的未保存提示")
        store.editChannel(at: 0)
        store.requestLeaveEditor()
        assert(!store.confirmingLeave, "没有改动时直接返回，不弹框")
        assert(store.editingIndex == nil)

        // 删模型/删渠道后 SwiftUI 会用旧下标再求一次 body，不能越界崩掉面板进程。
        store.editChannel(at: 0)
        store.addModel()
        store.addModel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        store.removeModel(at: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        store.removeModel(at: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        assert(store.models.isEmpty)
        store.addModel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        assert(store.models.count == 1)
        store.showList()
        store.editChannel(at: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        store.deleteChannel(at: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        assert(store.channels.count == 1)

        if CommandLine.arguments.count > 2 {
            try render(controller, store: store, directory: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        controller.window?.close()
        print("Swift channel list, editor, save, switch and layout checks passed.")
    }

    struct TestFailure: Error { let message: String; init(_ message: String) { self.message = message } }

    static func render(_ controller: StatusMenuController, store: PanelStore, directory: URL) throws {
        guard let window = controller.window, let content = window.contentView else { return }
        func shoot(_ name: String) {
            content.layoutSubtreeIfNeeded()
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(name))
        }
        store.showList()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        shoot("list.png")
        store.editChannel(at: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        shoot("detail.png")
    }
}
