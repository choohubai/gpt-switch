import AppKit
import SwiftUI

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
        ], "current": "OpenAI", "appearance": [
            "theme": "light",
            "themes": [
                ["id": "light", "name": "浅色", "previewPath": "/tmp/light.jpg", "colorScheme": "light"],
                ["id": "dark", "name": "深色", "previewPath": "/tmp/dark.jpg", "colorScheme": "dark"],
                ["id": "wind", "name": "有风", "previewPath": "/tmp/wind.jpg", "colorScheme": "light"],
            ],
        ]])
        assert(store.channels.count == 2)
        assert(store.currentChannelID == "OpenAI")
        assert(store.loaded && !store.busy)
        assert(store.editingIndex == nil, "读完配置应该停在列表页")
        assert(store.channels[0].models.first?.displayName == "", "老配置没有显示名称时留空")
        assert(store.channels[0].models.first?.inputModalities == ["text", "image"], "老配置默认文本+图片")
        assert(store.proxyHost == "127.0.0.1" && store.proxyPort == "47123", "没配代理时用默认值")

        // 外观卡片即选即存；保存失败要退回原主题，不能出现界面和文件不一致。
        assert(store.appearanceTheme == "light" && store.appearanceThemes.count == 3)
        let appearanceRequestCount = requests.count
        store.selectAppearanceTheme(store.appearanceThemes[2])
        assert(requests.count == appearanceRequestCount + 1)
        assert(requests.last?["scope"] as? String == "appearance")
        assert(requests.last?["theme"] as? String == "wind")
        assert(store.savingAppearance && store.appearanceTheme == "wind")
        store.apply(["ok": true, "saved": true, "appearance": [
            "theme": "wind",
            "themes": [
                ["id": "light", "name": "浅色", "previewPath": "/tmp/light.jpg", "colorScheme": "light"],
                ["id": "dark", "name": "深色", "previewPath": "/tmp/dark.jpg", "colorScheme": "dark"],
                ["id": "wind", "name": "有风", "previewPath": "/tmp/wind.jpg", "colorScheme": "light"],
            ],
        ]])
        assert(!store.savingAppearance && !store.busy)
        assert(store.appearanceTheme == "wind")
        assert(store.feedback.contains("有风"))
        store.selectAppearanceTheme(store.appearanceThemes[1])
        store.apply(["ok": false, "error": "主题写入失败"])
        assert(store.appearanceTheme == "wind", "主题保存失败时应恢复上一个主题")
        assert(store.feedback == "主题写入失败" && store.feedbackIsError)
        store.selectAppearanceTheme(store.appearanceThemes[1])
        store.apply(["ok": true, "saved": true, "restartRequired": true, "appearance": [
            "theme": "dark",
            "themes": [
                ["id": "light", "name": "浅色", "previewPath": "/tmp/light.jpg", "colorScheme": "light"],
                ["id": "dark", "name": "深色", "previewPath": "/tmp/dark.jpg", "colorScheme": "dark"],
                ["id": "wind", "name": "有风", "previewPath": "/tmp/wind.jpg", "colorScheme": "light"],
            ],
        ]])
        assert(store.appearanceTheme == "dark", "主题已保存时保留新主题")
        assert(store.feedback == "主题已保存，重启 ChatGPT 后生效")
        assert(!store.feedbackIsError, "等待重启不是保存失败，不能显示红色提示")

        // Codex 原生模式广播优先：暂停覆盖并把选中项同步到对应原生主题。
        store.apply(["event": "appearance-updated", "appearance": [
            "theme": "dark", "followNative": true, "nativeMode": "dark",
        ]])
        assert(store.appearanceTheme == "dark" && store.appearanceFollowNative)
        assert(store.appearanceNativeMode == "dark")
        assert(store.feedback.isEmpty, "原生模式同步只更新选中项，不再显示额外提示")
        let requestCountAfterNativeChange = requests.count
        store.selectAppearanceTheme(store.appearanceThemes[1])
        assert(requests.count == requestCountAfterNativeChange + 1)
        assert(!store.appearanceFollowNative && store.savingAppearance)
        store.apply(["ok": false, "error": "重新启用主题失败"])
        assert(store.appearanceFollowNative, "重新启用失败后必须恢复跟随原生状态")
        assert(store.appearanceNativeMode == "dark")
        assert(store.feedback == "重新启用主题失败" && store.feedbackIsError)
        store.selectAppearanceTheme(store.appearanceThemes[1])
        store.apply(["ok": true, "saved": true, "appearance": [
            "theme": "dark", "followNative": false, "nativeMode": "dark",
        ]])
        assert(!store.savingAppearance && !store.busy)
        store.savingProxy = true
        store.busy = true
        store.apply(["event": "appearance-updated", "appearance": [
            "theme": "light", "followNative": true, "nativeMode": "light",
        ]])
        assert(store.savingProxy && store.busy,
               "主动外观事件不能抢走正在等待的代理保存响应")
        assert(store.appearanceFollowNative && store.appearanceNativeMode == "light")
        assert(store.appearanceTheme == "light")
        store.savingProxy = false
        store.busy = false

        // Agents 默认值可以直接编辑；保存只发 scoped agents 请求，不碰渠道。
        store.agentsContent = "# 我编辑的公共指令\n"
        store.agentsEnabled = true
        assert(store.agentsDirty)
        let requestsBeforeAgents = requests.count
        store.saveAgents()
        assert(requests.count == requestsBeforeAgents + 1)
        assert(requests.last?["scope"] as? String == "agents")
        assert((requests.last?["agents"] as? [String: Any])?["content"] as? String == "# 我编辑的公共指令\n")
        assert((requests.last?["agents"] as? [String: Any])?["enabled"] as? Bool == true)
        store.apply(["ok": true, "saved": true, "agents": [
            "content": "# 我编辑的公共指令\n", "source": "user",
            "enabled": true,
            "path": "/tmp/AGENTS.md", "backupPath": "/tmp/AGENTS.md.2026.bak",
            "keptUserFile": true,
        ]])
        assert(!store.agentsDirty && !store.busy)
        assert(store.agentsSource == "user")
        assert(store.agentsEnabled)
        assert(store.feedback.contains("已同步"))

        // 正文或开关尚未保存时关闭面板，不能把状态静默丢掉。
        store.agentsContent = "# 未保存的编辑\n"
        assert(store.agentsDirty)
        store.agentsEnabled = false
        assert(store.agentsDirty)
        let requestsBeforeReopen = requests.count
        controller.openPanel()
        assert(requests.count == requestsBeforeReopen, "重新显示面板不能静默覆盖 Agents 草稿")
        controller.discardChangesChoice = { false }
        assert(!controller.canDiscardChanges())
        store.savingAgents = true
        assert(!controller.canDiscardChanges(), "保存进行中不能关闭或退出")
        store.savingAgents = false
        store.busy = true
        assert(!controller.canDiscardChanges(), "忙碌时退出也不能绕过未保存草稿确认")
        store.busy = false
        controller.discardChangesChoice = { true }
        assert(controller.canDiscardChanges())
        assert(!store.agentsDirty)
        assert(store.agentsContent == "# 我编辑的公共指令\n")
        assert(store.agentsEnabled)
        controller.discardChangesChoice = nil

        // 渠道 ID 在输入阶段校验：格式不对时给出具体提示，保存请求不发出去。
        store.addChannel()
        store.channels[store.channels.count - 1].id = "bad id"
        assert(store.channelIDError == "渠道 ID 只能用字母、数字、- 和 _")
        let requestsBeforeInvalidSave = requests.count
        store.save()
        assert(requests.count == requestsBeforeInvalidSave, "渠道 ID 不合法时不能发保存请求")
        assert(store.feedbackIsError && store.feedback == "渠道 ID 只能用字母、数字、- 和 _")
        store.channels[store.channels.count - 1].id = "choohub-gpt"
        assert(store.channelIDError == nil)
        store.channels[store.channels.count - 1].id = String(repeating: "a", count: 33)
        assert(store.channelIDError == "渠道 ID 不能超过 32 个字符")
        store.channels[store.channels.count - 1].id = " "
        assert(store.channelIDError == "渠道 ID 不能为空")
        store.requestLeaveEditor()

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

        // 右上角「重启」：重新写一遍配置和全部渠道的模型目录，然后重启客户端。
        store.requestRestart()
        store.confirmRestart()
        assert(requests.last?["action"] as? String == "switch")
        assert(requests.last?["restart"] as? Bool == true)
        assert(requests.last?["current"] as? String == "OpenAI")
        assert(store.restarting, "重启期间右上角按钮要变成「重启中」")
        store.apply(["ok": true, "saved": true, "restarted": true, "channels": [
            ["id": "OpenAI", "baseUrl": "https://choohub.net/api-proxy/v1", "models": []],
            ["id": "relay", "baseUrl": "https://relay.example/v1", "models": []],
        ], "current": "relay"])
        assert(!store.restarting && !store.restartNeeded, "重启完成后按钮恢复，也不再提示重启")
        assert(store.feedback.isEmpty, "重启不留提示")

        // 「重启」会重启客户端，所以先弹一句：取消什么都不做，确认才发 switch。
        store.requestRestart()
        assert(store.restartPrompt)
        let sentBeforePrompt = requests.count
        store.cancelRestart()
        assert(!store.restartPrompt)
        assert(requests.count == sentBeforePrompt, "取消不能发请求")
        store.requestRestart()
        store.confirmRestart()
        assert(!store.restartPrompt, "确认之后要收起提示")
        assert(requests.last?["action"] as? String == "switch")
        assert(requests.last?["restart"] as? Bool == true)
        assert(requests.last?["current"] as? String == "relay")
        store.busy = false

        // 代理保存只落盘；端口变化后提示重启，不会在路上动当前服务。
        store.proxyPort = "47124"
        assert(store.proxyDirty)
        store.saveProxy()
        assert(requests.last?["scope"] as? String == "proxy")
        assert((requests.last?["proxy"] as? [String: Any])?["port"] as? Int == 47124)
        store.busy = false
        store.apply(["ok": true, "saved": true, "proxy": ["host": "127.0.0.1", "port": 47124]])
        assert(!store.proxyDirty)
        assert(store.feedback == "代理配置已保存，重启 ChatGPT 后生效")

        // 每条渠道一个启用开关：禁用只翻这一条并落盘，别的渠道不动，也不重启客户端。
        store.showList()
        assert(store.channels.allSatisfy { $0.enabled }, "刚读进来的渠道都是启用状态")
        store.toggleChannel(at: 1)
        assert(!store.channels[1].enabled, "点禁用只翻这一条")
        assert(store.channels[0].enabled, "不能顺手把别的渠道也禁了")
        assert(requests.last?["action"] as? String == "save")
        assert(requests.last?["restart"] as? Bool == false, "开关渠道不重启客户端")
        let toggled = (requests.last?["channels"] as? [[String: Any]])?.first { $0["id"] as? String == "relay" }
        assert(toggled?["enabled"] as? Bool == false, "开关要跟着落盘")
        store.busy = false
        // 落盘成功：开关立刻生效，底栏既不说这条开关，也不提「点重启才生效」。
        store.apply(["ok": true, "saved": true, "current": "relay", "channels": store.channels.map(\.payload)])
        assert(store.feedback.isEmpty && !store.restartNeeded, "翻开关不需要重启，底栏不能提示")
        // 整份渠道列表一起校验，别的渠道不合格（比如有条新渠道还没填 ID）这条也会被拒：要退回原样。
        store.toggleChannel(at: 1)
        assert(store.channels[1].enabled, "再点一次就启用回来")
        store.busy = false
        store.apply(["ok": false, "error": "渠道 ID 只能用字母数字、- 和 _"])
        assert(!store.channels[1].enabled, "存盘失败要把开关退回上一次落盘的样子")
        assert(store.feedback == "渠道 ID 只能用字母数字、- 和 _")
        store.busy = false
        store.toggleChannel(at: 1)
        store.busy = false
        store.apply(["ok": true, "saved": true, "current": "relay", "channels": store.channels.map(\.payload)])
        store.addChannel()
        assert(store.channels.last?.enabled == true, "新建渠道默认是启用")
        store.requestLeaveEditor()

        // 进编辑页改模型：显示名称、窗口、输入类型都要落到渠道里。
        store.editChannel(at: 0)
        assert(store.editingTitle == "编辑渠道")
        store.channels[0].models = [ModelRow(id: "deepseek-v4-pro", context: 1000)]
        store.models[0].displayName = "DeepSeek V4"
        store.models[0].context = 10000
        store.models[0].id = "deepseek-v4-pro"
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
        store.channels[0].enabled = false
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
        assert(submitted[0]["enabled"] as? Bool == false, "在编辑页改渠道内容不能改动启用状态")

        store.apply(["ok": true, "saved": true, "channels": [
            ["id": "choohub", "baseUrl": "https://choohub.net/api-proxy/v1",
             "models": [["id": "deepseek-v4-pro", "displayName": "DeepSeek V4", "context": 10000,
                         "inputModalities": ["text", "image"]]]],
            ["id": "relay", "baseUrl": "https://relay.example/v1", "models": []],
        ], "current": "relay"])
        assert(store.restartNeeded && store.feedback.isEmpty, "改了配置要提示重启，话由底栏自己画")
        assert(store.editingIndex == nil, "存盘成功要回列表页，重启入口在那边")
        assert(!store.isDirty)

        // 改的是正在用的渠道也只存盘：写进 ChatGPT 是右上角「重启」的事，编辑完不重启客户端。
        store.showList()
        store.editChannel(at: 1)
        store.channels[1].baseUrl = "https://relay.example/v2"
        store.save()
        assert(requests.last?["action"] as? String == "save", "保存一律只写渠道列表")
        assert(requests.last?["restart"] as? Bool == false, "保存不重启客户端")
        assert(requests.last?["current"] as? String == "relay")
        store.apply(["ok": true, "saved": true, "channels": [
            ["id": "choohub", "baseUrl": "https://choohub.net/api-proxy/v1", "models": []],
            ["id": "relay", "baseUrl": "https://relay.example/v2", "models": []],
        ], "current": "relay"])
        assert(store.restartNeeded && store.feedback.isEmpty, "改了配置要提示重启，话由底栏自己画")
        assert(!store.isDirty)

        // 新增渠道进编辑页；删除立刻落盘并回列表页。
        store.showList()
        store.addChannel()
        assert(store.channels.count == 3)
        assert(store.editingIndex == 2)
        assert(store.editingTitle == "添加渠道")
        store.channels[2].id = "gateway"
        assert(store.editingTitle == "编辑渠道")
        store.deleteChannel(at: 2)
        assert(store.channels.count == 2)
        assert(store.editingIndex == nil, "删除后要回列表页")
        assert(requests.last?["action"] as? String == "save", "删除要落盘")
        store.apply(["ok": true, "saved": true, "channels": [
            ["id": "choohub", "baseUrl": "https://choohub.net/api-proxy/v1", "models": []],
            ["id": "relay", "baseUrl": "https://relay.example/v1", "models": []],
        ], "current": "relay"])
        assert(store.feedback.isEmpty && store.restartNeeded, "删除立刻生效，底栏只剩前面那条「配置有更新」")

        // 清空：不动面板里的渠道列表，只发 clear。
        store.clearAndRestart()
        assert(requests.last?["action"] as? String == "clear")
        store.apply(["ok": true, "cleared": true, "restarted": true, "channels": [
            ["id": "choohub", "baseUrl": "https://choohub.net/api-proxy/v1", "models": []],
            ["id": "relay", "baseUrl": "https://relay.example/v1", "models": []],
        ], "current": NSNull()])
        assert(store.feedback.isEmpty && !store.restartNeeded, "清空也重启了客户端，等重启的提示跟着清掉")
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
        // 忙碌期间（例如正在重启）不能再发一条请求：先回来的那条会被当成检查更新的响应吃掉，
        // busy 与「重启中」就再也复位不了。这条要在「有待下载版本」之前测——那时点更新是打开
        // 浏览器，会把测试里那个 example.com 的假地址真弹出来。
        store.busy = true
        let beforeBusyCheck = requests.count
        store.checkForUpdates()
        assert(requests.count == beforeBusyCheck, "忙碌期间点检查更新不能发请求")
        assert(!store.updateChecking, "被挡下就不要进检查中状态")
        store.busy = false
        store.checkForUpdates()
        assert(requests.last?["action"] as? String == "check-update")
        store.apply(["ok": true, "latest": "0.1.33", "url": "https://example.com/release"])
        assert(store.updateTitle == "去下载 v0.1.33")

        // 错误响应要落到反馈里，并解除 busy。
        store.busy = true
        store.apply(["ok": false, "error": "测试用失败"])
        assert(store.feedback == "测试用失败" && store.feedbackIsError && !store.busy)

        // 返回列表直接丢弃没保存的改动，不弹确认框。
        store.editChannel(at: 0)
        store.channels[0].baseUrl = "https://changed.example/v1"
        assert(store.isDirty)
        store.requestLeaveEditor()
        assert(store.editingIndex == nil, "返回列表不该停在编辑页")
        assert(!store.isDirty, "未保存的改动要丢弃")
        assert(store.channels == store.savedChannels, "丢弃后要回到已保存的内容")
        assert(store.feedback.isEmpty, "列表页不该挂着编辑页的未保存提示")
        store.editChannel(at: 0)
        store.requestLeaveEditor()
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
        // 没有「当前渠道不能删」这条限制：对着哪条点垃圾桶都先弹确认卡片。
        store.showList()
        store.editChannel(at: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        assert(store.editingActiveChannel, "这条就是客户端当前指向的那条")
        store.requestDelete(at: 1)
        assert(store.deletePrompt == .channel(1), "当前指向的那条也能删，先弹确认")
        store.cancelDelete()
        assert(store.channels.count == 2 && !store.busy, "取消就什么都不做")

        // 删别的渠道：立刻落盘、并且回到列表页，不能停在编辑页等用户再点一次返回。
        store.editChannel(at: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        store.deleteChannel(at: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        assert(store.channels.count == 1 && store.channels[0].id == "relay")
        assert(store.editingIndex == nil, "删除后要回列表页")
        assert(store.busy, "删除要发起存盘请求")
        assert(requests.last?["action"] as? String == "save", "删除要落盘")
        store.apply(["ok": true, "saved": true, "channels": [
            ["id": "relay", "baseUrl": "https://relay.example/v1", "models": []],
        ], "current": "relay"])
        assert(store.feedback.isEmpty, "删除立刻生效，底栏不留提示")
        assert(!store.isDirty)

        // 存盘失败时，刚删掉的那条要放回去，不能只在面板里消失。
        store.showList()
        store.addChannel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        assert(store.channels.count == 2)
        store.deleteChannel(at: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        assert(store.channels.count == 1)
        store.apply(["ok": false, "error": "测试用失败"])
        assert(store.channels.count == 2, "存盘失败要把渠道放回去")
        assert(store.feedbackIsError)

        // 列表页的垃圾桶：哪条都先弹确认卡片，取消不删，确认后走同一条删除 + 落盘。
        store.showList()
        store.channels[1].id = "spare"
        store.requestDelete(at: 0)
        assert(store.deletePrompt == .channel(0), "客户端当前指向的那条也能删")
        store.cancelDelete()
        assert(store.channels.count == 2, "取消不能删掉")
        store.requestDelete(at: 1)
        assert(store.deletePrompt == .channel(1), "点垃圾桶要先确认")
        assert(store.deletePromptText?.title == "删除 spare?", "确认卡片要有标题")
        assert(store.deletePromptText?.message == "删除 spare 会移除其配置和存储的 API 密钥。")
        store.cancelDelete()
        assert(store.deletePrompt == nil && store.channels.count == 2, "取消不能删掉")
        store.requestDelete(at: 1)
        store.confirmDelete()
        assert(store.deletePrompt == nil)
        assert(store.channels.count == 1, "确认后删掉")
        assert(store.editingIndex == nil, "列表页删除后仍然停在列表页")
        assert(requests.last?["action"] as? String == "save", "列表页删除也要落盘")
        store.apply(["ok": true, "saved": true, "channels": [
            ["id": "choohub", "baseUrl": "https://choohub.net/api-proxy/v1", "models": []],
            ["id": "relay", "baseUrl": "https://relay.example/v1", "models": []],
        ], "current": "relay"])
        assert(store.feedback.isEmpty, "删除立刻生效，底栏不留提示")

        // 删模型也要先确认，取消不删。
        store.editChannel(at: 0)
        store.addModel()
        store.requestModelDelete(at: 0)
        assert(store.deletePrompt == .model(0), "模型垃圾桶要先确认")
        store.cancelDelete()
        assert(store.models.count == 1, "取消不能删掉模型")
        store.requestModelDelete(at: 0)
        store.confirmDelete()
        assert(store.deletePrompt == nil && store.models.isEmpty, "确认后删掉模型")
        store.showList()

        // 改当前渠道的 ID：它就还是当前渠道，列表里不能退回「启用」。
        store.editChannel(at: 1)
        store.channels[1].id = "relay-2"
        store.save()
        assert(requests.last?["current"] as? String == "relay-2", "当前渠道改名后 current 要跟着走")
        store.apply(["ok": true, "saved": true, "channels": [
            ["id": "choohub", "baseUrl": "https://choohub.net/api-proxy/v1", "models": []],
            ["id": "relay-2", "baseUrl": "https://relay.example/v1", "models": []],
        ], "current": "relay-2"])
        assert(store.currentChannelID == "relay-2")

        // 改的要不是当前渠道，当前渠道就不能被顺手改掉。
        store.editChannel(at: 0)
        store.channels[0].id = "choohub-2"
        store.save()
        assert(requests.last?["action"] as? String == "save", "改别的渠道只存盘")
        assert(requests.last?["current"] as? String == "relay-2", "改别的渠道不能动当前渠道")
        store.apply(["ok": true, "saved": true, "channels": [
            ["id": "choohub-2", "baseUrl": "https://choohub.net/api-proxy/v1", "models": []],
            ["id": "relay-2", "baseUrl": "https://relay.example/v1", "models": []],
        ], "current": "relay-2"])

        // 获取可用模型：带上渠道地址、密钥和自定义请求头问端点，拿回来的清单填进模型目录。
        store.editChannel(at: 0)
        store.channels[0].apiKey = "sk-fetch"
        store.channels[0].headerName = "x-actor"
        store.channels[0].headerValue = "actor"
        let beforeFetch = requests.count
        store.channels[0].baseUrl = ""
        assert(!store.canFetchModels, "没填地址不能获取模型")
        store.fetchModels()
        assert(requests.count == beforeFetch, "没填地址不该发请求")
        store.channels[0].baseUrl = "https://choohub.net/api-proxy/v1"
        assert(store.canFetchModels)
        store.fetchModels()
        assert(requests.last?["action"] as? String == "list-models")
        assert(requests.last?["baseUrl"] as? String == "https://choohub.net/api-proxy/v1")
        assert(requests.last?["apiKey"] as? String == "sk-fetch")
        assert(requests.last?["headerName"] as? String == "x-actor")
        assert(store.busy && store.fetchingModels, "获取期间要锁住面板")
        store.channels[0].models = [ModelRow(id: "kept", displayName: "手动改的名字", context: 64)]
        store.apply(["ok": true, "models": [
            ["id": "kept", "context": 128],
            ["id": "brand-new", "displayName": "Brand New"],
        ]])
        assert(!store.busy && !store.fetchingModels)
        assert(store.discovering, "拿回来要先让人勾选，不能直接塞进目录")
        assert(store.discoveredSelection.isEmpty, "默认一个都不勾")
        assert(store.models.map(\.id) == ["kept"], "勾选之前目录不能动")

        store.discoveredSelection = ["kept"]
        store.addSelectedModels()
        assert(!store.discovering)
        assert(store.models.count == 1, "已经在目录里的不重复加")
        assert(store.feedback == "勾选的模型都已经在目录里")

        store.discoveredModels = [DiscoveredModel(id: "brand-new", displayName: "Brand New", context: nil)]
        store.discoveredSelection = ["brand-new"]
        store.cancelDiscovery()
        assert(!store.discovering && store.models.count == 1, "取消不动目录")

        store.discoveredModels = [
            DiscoveredModel(id: "brand-new", displayName: "Brand New", context: 128),
            DiscoveredModel(id: "deepseek-v4.1-flash", displayName: nil, context: nil),
        ]
        store.discoveredSelection = ["brand-new", "deepseek-v4.1-flash"]
        store.addSelectedModels()
        assert(store.models.map(\.id) == ["kept", "brand-new", "deepseek-v4.1-flash"], "勾上的补进目录")
        assert(store.models[1].displayName == "Brand New")
        assert(store.models[1].context == 128)
        assert(store.models[1].inputModalities == ["text", "image"], "新加进来的模型默认文本+图片")
        assert(store.models[0].displayName == "手动改的名字", "已有的那条不动")
        assert(store.feedback == "已添加 2 个模型，点「保存」后生效")
        assert(store.isDirty, "加进来的模型要保存后才生效")

        // 端点报错要落到反馈里并解除 busy。
        store.busy = true
        store.fetchingModels = true
        store.apply(["ok": false, "error": "连不上 https://choohub.net/api-proxy/v1/models"])
        assert(store.feedback == "连不上 https://choohub.net/api-proxy/v1/models")
        assert(store.feedbackIsError && !store.busy && !store.fetchingModels)

        // 存盘失败就留在编辑页：把人踢回列表页，改的东西看着就没了。
        store.busy = true
        store.apply(["ok": false, "error": "测试用失败"])
        store.editChannel(at: 0)
        store.channels[0].baseUrl = "https://typo.example/v1"
        store.save()
        store.apply(["ok": false, "error": "渠道地址不合法"])
        assert(store.editingIndex == 0, "存盘失败要留在编辑页")
        assert(store.feedback == "渠道地址不合法" && store.feedbackIsError)
        // 失败后重试成功：回列表页这个标记不能因为上一次失败就丢了。
        store.save()
        store.apply(["ok": true, "saved": true, "current": "relay", "channels": [
            ["id": "choohub-2", "baseUrl": "https://typo.example/v1", "models": []],
            ["id": "relay-2", "baseUrl": "https://relay.example/v1", "models": []],
        ]])
        assert(store.editingIndex == nil, "失败后重试成功仍然要回列表页")
        assert(store.restartNeeded, "这时候配置和客户端还是不一致")
        store.requestLeaveEditor()

        // 重启失败也要把「重启中」放回来，否则按钮永远回不到可点状态。
        store.showList()
        store.requestRestart()
        store.confirmRestart()
        assert(store.restarting, "重启请求发出后按钮要进「重启中」")
        store.apply(["ok": false, "error": "客户端没能正常退出"])
        assert(!store.restarting && !store.busy, "重启失败要把按钮放回来")
        assert(store.feedback == "客户端没能正常退出" && store.feedbackIsError)

        // 提示的含义是「文件里的配置和客户端里的不一样」：改回原值就该自己消失。
        let baseline: [[String: Any]] = [
            ["id": "choohub", "baseUrl": "https://choohub.net/api-proxy/v1", "models": []],
            ["id": "relay", "baseUrl": "https://relay.example/v1", "models": []],
        ]
        store.requestRestart()
        store.confirmRestart()
        store.apply(["ok": true, "saved": true, "restarted": true, "channels": baseline, "current": "relay"])
        assert(!store.restartNeeded, "刚重启过就不该提示重启")
        store.editChannel(at: 0)
        store.channels[0].baseUrl = "https://changed.example/v1"
        store.save()
        store.apply(["ok": true, "saved": true, "current": "relay", "channels": [
            ["id": "choohub", "baseUrl": "https://changed.example/v1", "models": []],
            ["id": "relay", "baseUrl": "https://relay.example/v1", "models": []],
        ]])
        assert(store.restartNeeded, "改成别的值要提示重启")
        store.editChannel(at: 0)
        store.channels[0].baseUrl = "https://choohub.net/api-proxy/v1"
        store.save()
        store.apply(["ok": true, "saved": true, "current": "relay", "channels": baseline])
        assert(!store.restartNeeded, "改回原值就不该再提示重启")

        if CommandLine.arguments.count > 2 {
            try render(controller, store: store, directory: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        controller.window?.close()
        print("Swift channel list, editor, save, switch and layout checks passed.")
    }

    struct TestFailure: Error { let message: String; init(_ message: String) { self.message = message } }

    static func render(_ controller: StatusMenuController, store: PanelStore, directory: URL) throws {
        guard let window = controller.window, window.contentView != nil else { return }
        func shoot(_ name: String) throws {
            guard let current = window.contentView else {
                throw TestFailure("截图前窗口内容被移除：\(name)")
            }
            current.layoutSubtreeIfNeeded()
            guard let rep = current.bitmapImageRepForCachingDisplay(in: current.bounds) else {
                throw TestFailure("无法创建截图：\(name)")
            }
            current.cacheDisplay(in: current.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw TestFailure("无法编码截图：\(name)")
            }
            try data.write(to: directory.appendingPathComponent(name))
        }
        store.showList()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try shoot("list.png")
        try assertSidebarSelectionState()
        store.editChannel(at: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try shoot("detail.png")
        store.requestDelete(at: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try shoot("confirm.png")
        store.cancelDelete()
        store.discoveredModels = [
            DiscoveredModel(id: "deepseek-v4-flash-vision-exp", displayName: nil, context: nil),
            DiscoveredModel(id: "deepseek-v4-pro", displayName: nil, context: nil),
            DiscoveredModel(id: "glm-5.3", displayName: nil, context: nil),
        ]
        store.discoveredSelection = ["deepseek-v4-pro"]
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try shoot("picker.png")
        store.cancelDiscovery()
        store.version = "0.1.46"
        store.showList()
        window.contentView = NSHostingView(rootView: PanelView(store: store, selectedSection: .proxy))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try shoot("proxy.png")
        window.contentView = NSHostingView(rootView: PanelView(store: store, selectedSection: .agents))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try shoot("agents.png")
        window.contentView = NSHostingView(rootView: PanelView(store: store, selectedSection: .general))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try shoot("general.png")
        let appearanceDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
            .deletingLastPathComponent()
            .appendingPathComponent("Appearance")
        store.appearanceTheme = "dark"
        store.appearanceFollowNative = true
        store.appearanceNativeMode = "dark"
        store.appearanceThemes = [
            AppearanceThemeRow(id: "light", name: "浅色",
                               previewPath: appearanceDirectory.appendingPathComponent("light-preview.jpg").path,
                               cardBackground: "#f0f0f0",
                               colorScheme: "light"),
            AppearanceThemeRow(id: "dark", name: "深色",
                               previewPath: appearanceDirectory.appendingPathComponent("dark-preview.jpg").path,
                               cardBackground: "#303030",
                               colorScheme: "dark"),
            AppearanceThemeRow(id: "wind", name: "有风",
                               previewPath: appearanceDirectory.appendingPathComponent("wind-preview.jpg").path,
                               coverPath: appearanceDirectory.appendingPathComponent("wind-bg.png").path,
                               colorScheme: "light"),
            AppearanceThemeRow(id: "qq", name: "经典 QQ",
                               previewPath: appearanceDirectory.appendingPathComponent("qq-preview.png").path,
                               coverPath: appearanceDirectory.appendingPathComponent("qq-bg.png").path,
                               colorScheme: "light"),
            AppearanceThemeRow(id: "peace", name: "和平精英激战金秋",
                               previewPath: appearanceDirectory.appendingPathComponent("peace-preview.jpg").path,
                               coverPath: appearanceDirectory.appendingPathComponent("peace-bg.png").path,
                               colorScheme: "light"),
            AppearanceThemeRow(id: "journey", name: "同行",
                               previewPath: appearanceDirectory.appendingPathComponent("journey-preview.jpg").path,
                               coverPath: appearanceDirectory.appendingPathComponent("journey-bg.png").path,
                               colorScheme: "light"),
            AppearanceThemeRow(id: "ripple", name: "涟漪",
                               previewPath: appearanceDirectory.appendingPathComponent("ripple-preview.jpg").path,
                               coverPath: appearanceDirectory.appendingPathComponent("ripple-bg.png").path,
                               colorScheme: "light"),
            AppearanceThemeRow(id: "buddy", name: "伙伴",
                               previewPath: appearanceDirectory.appendingPathComponent("buddy-preview.jpg").path,
                               coverPath: appearanceDirectory.appendingPathComponent("buddy-bg.png").path,
                               colorScheme: "light"),
        ]
        window.contentView = NSHostingView(rootView: PanelView(store: store, selectedSection: .appearance))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try shoot("appearance.png")
        window.contentView = NSHostingView(rootView: PanelView(store: store, selectedSection: .about))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try shoot("about.png")
        window.contentView = NSHostingView(rootView: PanelView(store: store, selectedSection: .help))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try shoot("help.png")
        let appearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: PanelView(store: store))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try shoot("dark-list.png")
        NSApp.appearance = appearance
    }

    /// 覆盖侧栏点击时走的同一套值变化；界面刷新由打包后的真实点击检查。
    static func assertSidebarSelectionState() throws {
        for section in SidebarSection.allCases {
            assert(SidebarSection(rawValue: section.rawValue) == section)
        }
        assert(SidebarSection.appearance.systemImage == "paintpalette")
    }
}
