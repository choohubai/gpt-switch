import AppKit
import SwiftUI

/// 同一个颜色按系统外观取浅色或深色值，沿用原来的深浅色支持。
private func appearanceColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

/// 后端主题目录可以给纯色卡片一个十六进制色值；解析失败时仍退回系统色。
private func appearanceHexColor(_ value: String, fallback: Color) -> Color {
    let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard digits.count == 6, let number = UInt64(digits, radix: 16) else { return fallback }
    return Color(
        red: Double((number >> 16) & 0xff) / 255,
        green: Double((number >> 8) & 0xff) / 255,
        blue: Double(number & 0xff) / 255)
}

/// 面板使用 WorkBuddy 同系的低饱和绿色；系统 accent 被改掉时界面也不会跟着走样。
private let accentTop = appearanceColor(
    light: NSColor(calibratedRed: 0.25, green: 0.49, blue: 0.30, alpha: 1),
    dark: NSColor(calibratedRed: 0.39, green: 0.68, blue: 0.45, alpha: 1))
private let accentBottom = appearanceColor(
    light: NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.25, alpha: 1),
    dark: NSColor(calibratedRed: 0.30, green: 0.59, blue: 0.37, alpha: 1))
private let panelBackground = appearanceColor(
    light: NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.96, alpha: 0.7),
    dark: NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.08, alpha: 0.82))
private let panelTint = appearanceColor(
    light: NSColor(calibratedRed: 0.95, green: 0.97, blue: 0.94, alpha: 0.84),
    dark: NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.11, alpha: 0.88))
private let sidebarBackground = appearanceColor(
    light: NSColor(calibratedRed: 0.92, green: 0.95, blue: 0.91, alpha: 0.94),
    dark: NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.07, alpha: 0.96))
private var accentGradient: LinearGradient {
    LinearGradient(colors: [accentTop, accentBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
}

enum SidebarSection: String, CaseIterable, Hashable {
    case models = "模型"
    case proxy = "代理"
    case general = "通用"
    case appearance = "外观"
    case agents = "Agents"
    case about = "关于"
    case help = "获取帮助"

    static let settings: [SidebarSection] = [.models, .proxy, .general, .appearance, .agents]

    var systemImage: String {
        switch self {
        case .models: return "cube"
        case .proxy: return "network"
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .agents: return "person.2"
        case .about: return "info.circle"
        case .help: return "questionmark.circle"
        }
    }
}

// MARK: - 数据模型

struct ModelRow: Codable, Equatable {
    var id: String
    var displayName: String
    var context: Int
    var inputModalities: [String]

    private enum CodingKeys: String, CodingKey {
        case id, displayName, context, inputModalities
    }

    init(id: String = "", displayName: String = "", context: Int = 272,
         inputModalities: [String] = ["text", "image"]) {
        self.id = id
        self.displayName = displayName
        self.context = context
        self.inputModalities = inputModalities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        context = try container.decodeIfPresent(Int.self, forKey: .context) ?? 272
        inputModalities = try container.decodeIfPresent([String].self, forKey: .inputModalities)
            ?? ["text", "image"]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(context, forKey: .context)
        try container.encode(inputModalities, forKey: .inputModalities)
    }

    var payload: [String: Any] {
        [
            "id": id, "displayName": displayName, "context": context, "inputModalities": inputModalities,
        ]
    }
}

struct ChannelRow: Codable, Equatable {
    var id: String
    var name: String
    var baseUrl: String
    var apiKey: String
    var headerName: String
    var headerValue: String
    /// 这条渠道能不能用：面板里单独开关，新建的缺省启用。
    var enabled: Bool
    var models: [ModelRow]

    private enum CodingKeys: String, CodingKey {
        case id, name, baseUrl, apiKey, headerName, headerValue, enabled, models
    }

    init(id: String = "", name: String = "", baseUrl: String = "", apiKey: String = "",
         headerName: String = "", headerValue: String = "", enabled: Bool = true, models: [ModelRow] = []) {
        self.id = id
        self.name = name
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.headerName = headerName
        self.headerValue = headerValue
        self.enabled = enabled
        self.models = models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        headerName = try container.decodeIfPresent(String.self, forKey: .headerName) ?? ""
        headerValue = try container.decodeIfPresent(String.self, forKey: .headerValue) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        models = try container.decodeIfPresent([ModelRow].self, forKey: .models) ?? []
    }

    var payload: [String: Any] {
        ["id": id, "name": name, "baseUrl": baseUrl, "apiKey": apiKey,
         "headerName": headerName, "headerValue": headerValue, "enabled": enabled,
         "models": models.map(\.payload)]
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

/// 面板里认这条渠道用的名字：有显示名就「名字 (id)」，否则只给 id。
func channelDisplayLabel(_ channel: ChannelRow) -> String {
    let id = channel.id.trimmingCharacters(in: .whitespaces)
    let name = channel.name.trimmingCharacters(in: .whitespaces)
    if id.isEmpty { return name.isEmpty ? "未命名渠道" : name }
    if name.isEmpty || name == id { return id }
    return "\(name) (\(id))"
}

/// 删除统一走同一张确认卡片，这里只记「要删哪一条」。
enum DeletePrompt: Equatable {
    case channel(Int)
    case model(Int)
}

/// 「获取可用模型」拿回来的行：id 一定有，显示名和窗口只在端点给出时才有。
struct DiscoveredModel: Decodable {
    let id: String
    let displayName: String?
    let context: Int?
}

struct AppearanceThemeRow: Identifiable, Equatable {
    let id: String
    let name: String
    let previewPath: String
    let coverPath: String
    let cardBackground: String
    let colorScheme: String

    init(id: String, name: String, previewPath: String, coverPath: String = "",
         cardBackground: String = "", colorScheme: String) {
        self.id = id
        self.name = name
        self.previewPath = previewPath
        self.coverPath = coverPath
        self.cardBackground = cardBackground
        self.colorScheme = colorScheme
    }
}

func isVersion(_ candidate: String, newerThan base: String) -> Bool {
    func parts(_ value: String) -> [Int] {
        value.replacingOccurrences(of: "v", with: "").split(separator: ".").map { Int($0) ?? 0 }
    }
    let left = parts(candidate)
    let right = parts(base)
    for index in 0..<max(left.count, right.count) {
        let leftPart = index < left.count ? left[index] : 0
        let rightPart = index < right.count ? right[index] : 0
        if leftPart != rightPart { return leftPart > rightPart }
    }
    return false
}

// MARK: - 面板状态

final class PanelStore: ObservableObject {
    @Published var channels: [ChannelRow] = []
    @Published var savedChannels: [ChannelRow] = []
    @Published var proxyHost = "127.0.0.1"
    @Published var proxyPort = "47123"
    @Published var savedProxyHost = "127.0.0.1"
    @Published var savedProxyPort = "47123"
    @Published var agentsContent = ""
    @Published var savedAgentsContent = ""
    @Published var agentsBackupPath = ""
    @Published var agentsSource = ""
    @Published var agentsError = ""
    @Published var agentsEnabled = false
    @Published var savedAgentsEnabled = false
    @Published var appearanceTheme = "light"
    @Published var appearanceFollowNative = false
    @Published var appearanceNativeMode = "light"
    @Published var appearanceThemes: [AppearanceThemeRow] = []
    @Published var savingAppearance = false
    @Published var savingAgents = false
    @Published var savingProxy = false
    @Published var currentChannelID: String?
    @Published var editingIndex: Int?
    @Published var loaded = false
    @Published var busy = false
    @Published var feedback = ""
    @Published var feedbackIsError = false
    @Published var version = ""
    @Published var updateTitle = "检查更新"
    @Published var updateEnabled = true
    @Published var fetchingModels = false
    @Published var discoveredModels: [DiscoveredModel] = []
    @Published var discoveredSelection: Set<String> = []
    @Published var discoveryFilter = ""
    @Published var confirmingClear = false
    /// 改过的配置还没写进客户端（右上角「重启」才会写）：底栏只在这时候提示重启。
    @Published var restartNeeded = false
    /// 正在重启客户端：右上角那个按钮变成「重启中」并置灰。
    @Published var restarting = false
    /// 右上角「重启」会重启客户端，先弹一句说明。
    @Published var restartPrompt = false
    @Published var deletePrompt: DeletePrompt?

    var send: ([String: Any]) -> Void = { _ in }
    private var pendingUpdateURL: URL?
    private var checkingUpdate = false
    /// 进编辑页时这条渠道是不是正在用的那条：保存时按它决定「使用中」跟谁走。
    private(set) var editingActiveChannel = false
    /// 要落盘的改动（删渠道、翻开关）先在这里留一份原文，存盘失败时放回去，别让面板和文件对不上。
    private var pendingRestore: [ChannelRow]?
    /// 主题保存失败时恢复到这里，避免卡片看起来已经切换但配置文件没有写成功。
    private var appearanceThemeBeforeSave = "light"
    private var appearanceFollowNativeBeforeSave = false
    private var appearanceNativeModeBeforeSave = "light"
    /// 编辑页点「保存」：落盘成功后回列表页（重启入口在那边），失败就留在原地。
    private var leaveEditorAfterSave = false
    /// 上一次写进客户端的那份渠道列表（读完配置时、重启或清空成功后各记一次）。
    /// 用来判断「文件里的配置和客户端里的到底一样不一样」，改回原值就不该再提示重启。
    private var appliedChannels: [ChannelRow] = []

    var activeIndex: Int { editingIndex ?? 0 }

    var activeChannel: ChannelRow? {
        channels.indices.contains(activeIndex) ? channels[activeIndex] : nil
    }

    var hasChannel: Bool { activeChannel != nil }
    /// 代理页也有自己的保存按钮；未保存的代理输入不能把模型页的「保存」和右上角重启拖住。
    var proxyDirty: Bool { proxyHost != savedProxyHost || proxyPort != savedProxyPort }
    var agentsDirty: Bool { agentsContent != savedAgentsContent || agentsEnabled != savedAgentsEnabled }
    var isDirty: Bool { channels != savedChannels }

    /// 输入阶段就按后端的 Provider ID 规则校验，别等整份列表保存时才报错。
    var channelIDError: String? {
        guard let channel = activeChannel else { return nil }
        let id = channel.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return "渠道 ID 不能为空" }
        if id.count > 32 { return "渠道 ID 不能超过 32 个字符" }
        if id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) == nil {
            return "渠道 ID 只能用字母、数字、- 和 _"
        }
        return nil
    }

    var editingTitle: String {
        guard let channel = activeChannel, !channel.id.isEmpty else { return "添加渠道" }
        return "编辑渠道"
    }

    var models: [ModelRow] {
        get { activeChannel?.models ?? [] }
        set {
            guard channels.indices.contains(activeIndex) else { return }
            channels[activeIndex].models = newValue
        }
    }

    // MARK: 页面切换

    func showList() {
        editingIndex = nil
        editingActiveChannel = false
        deletePrompt = nil
        cancelDiscovery()
        feedback = ""
        feedbackIsError = false
    }

    /// 返回列表一律丢弃编辑页里没保存的改动，不再弹确认框。
    func requestLeaveEditor() {
        guard !busy else { return }
        channels = savedChannels
        showList()
    }

    func editChannel(at index: Int) {
        guard channels.indices.contains(index) else { return }
        editingIndex = index
        editingActiveChannel = channels[index].id == currentChannelID
    }

    /// 列表页和编辑页的垃圾桶都先问一句，删的动作还是走 deleteChannel。
    func requestDelete(at index: Int) {
        guard channels.indices.contains(index), !busy else { return }
        deletePrompt = .channel(index)
    }

    func requestModelDelete(at index: Int) {
        guard models.indices.contains(index), !busy else { return }
        deletePrompt = .model(index)
    }

    func confirmDelete() {
        let prompt = deletePrompt
        deletePrompt = nil
        switch prompt {
        case .channel(let index): deleteChannel(at: index)
        case .model(let index): removeModel(at: index)
        case nil: break
        }
    }

    func cancelDelete() {
        deletePrompt = nil
    }

    /// 二次确认卡片的标题、正文和确认按钮文案。
    var deletePromptText: (title: String, message: String, confirm: String)? {
        switch deletePrompt {
        case .channel(let index):
            guard channels.indices.contains(index) else { return nil }
            let label = channelDisplayLabel(channels[index])
            return ("删除 \(label)?", "删除 \(label) 会移除其配置和存储的 API 密钥。", "删除 \(label)")
        case .model(let index):
            let id = models.indices.contains(index) ? models[index].id : ""
            let label = id.isEmpty ? "未命名模型" : id
            return ("删除模型「\(label)」？", "会从当前渠道的模型目录里移除它，保存后生效。", "删除")
        case nil:
            return nil
        }
    }

    func addChannel() {
        guard loaded, !busy, channels.count < 50 else { return }
        channels.append(ChannelRow())
        editingIndex = channels.count - 1
        editingActiveChannel = false
        feedback = "有未保存的更改"
        feedbackIsError = false
    }

    /// 删除立刻落盘并回列表页：只从内存里拿掉、人还留在编辑页，等于没删成。
    func deleteChannel(at index: Int) {
        guard channels.indices.contains(index), !busy else { return }
        let restore = channels
        channels.remove(at: index)
        pendingRestore = restore
        showList()
        submit(action: "save", currentID: currentChannelID ?? "")
    }

    // MARK: 模型编辑

    func addModel() {
        guard loaded, !busy, hasChannel else { return }
        models.append(ModelRow())
        feedback = "有未保存的更改"
        feedbackIsError = false
    }

    func removeModel(at index: Int) {
        guard !busy, models.indices.contains(index) else { return }
        models.remove(at: index)
    }

    /// 关掉唯一的输入类型会让配置不可用，所以最后一个勾不能取消。
    func toggleModality(at index: Int, modality: String, on: Bool) {
        guard channels.indices.contains(activeIndex),
              channels[activeIndex].models.indices.contains(index) else { return }
        var next = channels[activeIndex].models[index].inputModalities
        if on {
            if !next.contains(modality) { next.append(modality) }
        } else {
            let remaining = next.filter { $0 != modality }
            if remaining.isEmpty {
                NSSound.beep()
                return
            }
            next = remaining
        }
        channels[activeIndex].models[index].inputModalities = next
    }

    // MARK: 请求

    /// 保存只写渠道列表，不重启客户端：写进 ChatGPT 是右上角「重启」的事。改的是正在用的
    /// 那条时 current 要跟着走，否则把渠道 ID 改掉之后「运行中」就掉了。
    func save() {
        guard loaded, !busy else { return }
        if let error = channelIDError {
            feedback = error
            feedbackIsError = true
            return
        }
        leaveEditorAfterSave = true
        if editingActiveChannel, channels.indices.contains(activeIndex) {
            submit(action: "save", currentID: channels[activeIndex].id)
            return
        }
        submit(action: "save", currentID: currentChannelID ?? "")
    }

    /// 代理保存只落盘；实际监听和 Codex 地址在用户点右上角「重启 ChatGPT」时一起切换。
    func saveProxy() {
        guard loaded, !busy, proxyDirty else { return }
        busy = true
        savingProxy = true
        feedback = ""
        feedbackIsError = false
        send([
            "action": "save",
            "restart": false,
            "scope": "proxy",
            "proxy": ["host": proxyHost, "port": Int(proxyPort) ?? -1],
        ])
    }

    /// 保存可编辑草稿；启用时由本地注入器在写入前备份并合并用户 AGENTS.md。
    func saveAgents() {
        guard loaded, !busy, agentsDirty else { return }
        busy = true
        savingAgents = true
        feedback = "正在保存公共指令…"
        feedbackIsError = false
        send([
            "action": "save",
            "restart": false,
            "scope": "agents",
            "agents": ["content": agentsContent, "enabled": agentsEnabled],
        ])
    }

    /// 离开 Agents 页时同时丢弃未保存的正文和开关。
    func discardAgentsDraft() {
        agentsContent = savedAgentsContent
        agentsEnabled = savedAgentsEnabled
    }

    /// 主题卡片即选即存；保存失败时恢复原主题，尚未热应用时提示重启后生效。
    func selectAppearanceTheme(_ theme: AppearanceThemeRow) {
        guard loaded, !busy, !savingAppearance,
              appearanceFollowNative || appearanceTheme != theme.id else { return }
        appearanceThemeBeforeSave = appearanceTheme
        appearanceFollowNativeBeforeSave = appearanceFollowNative
        appearanceNativeModeBeforeSave = appearanceNativeMode
        appearanceTheme = theme.id
        appearanceFollowNative = false
        busy = true
        savingAppearance = true
        feedback = "正在应用「\(theme.name)」…"
        feedbackIsError = false
        send([
            "action": "save",
            "restart": false,
            "scope": "appearance",
            "theme": theme.id,
        ])
    }

    /// 右上角的「重启」：重新写一遍 ChatGPT 配置和全部渠道的模型目录，然后重启。
    func applyAndRestart() {
        guard loaded, !busy else { return }
        submit(action: "switch", currentID: currentChannelID ?? "")
    }

    /// 单条渠道的启用/禁用：只改这条的开关并落盘，不碰别的渠道，也不重启客户端。
    func toggleChannel(at index: Int) {
        guard channels.indices.contains(index), loaded, !busy else { return }
        // 整份渠道列表一起校验，别的渠道有问题（比如有条新渠道还没填 ID）这一条也会被拒，
        // 所以先留一份原文：存盘失败要退回原样，不能让面板显示一个没落盘的状态。
        let restore = channels
        channels[index].enabled.toggle()
        pendingRestore = restore
        submit(action: "save", currentID: currentChannelID ?? "")
    }

    func requestRestart() {
        guard loaded, !busy else { return }
        restartPrompt = true
    }

    func confirmRestart() {
        guard restartPrompt else { return }
        restartPrompt = false
        applyAndRestart()
    }

    func cancelRestart() {
        restartPrompt = false
    }

    var canRestart: Bool {
        loaded && !busy
    }

    var canSaveProxy: Bool {
        loaded && !busy && proxyDirty
    }

    /// 面板不为「正在启用/正在重启」这类过程刷提示：底栏留给报错和「配置有更新」。
    private func submit(action: String, currentID: String) {
        guard loaded, !busy else { return }
        busy = true
        restarting = action == "switch"
        feedback = ""
        feedbackIsError = false
        send([
            "action": action,
            "restart": action == "switch",
            "current": currentID,
            "channels": channels.map(\.payload),
        ])
    }

    func clearAndRestart() {
        guard loaded, !busy else { return }
        busy = true
        restarting = true
        feedback = ""
        feedbackIsError = false
        send(["action": "clear"])
    }

    func checkForUpdates() {
        if let pendingUpdateURL {
            NSWorkspace.shared.open(pendingUpdateURL)
            return
        }
        // 面板一次只挂一条在途请求（load/save/switch 都靠 busy 串起来）：忙碌期间再发一条，
        // 先回来的那条会被当成检查更新的响应吃掉，busy 和「重启中」就再也复位不了。
        guard !checkingUpdate, !busy else { return }
        checkingUpdate = true
        updateTitle = "检查中…"
        updateEnabled = false
        send(["action": "check-update"])
    }

    /// 底栏那个图标按钮的三种样子：检查中转圈、有新版可下载、平常。
    var updateChecking: Bool { checkingUpdate }
    var updateAvailable: Bool { pendingUpdateURL != nil }

    /// 填了地址才问得动端点，所以地址是空的就不给点。
    var canFetchModels: Bool {
        guard loaded, !busy, let channel = activeChannel else { return false }
        return !channel.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 问渠道端点要它公布的模型，拿回来填进这个渠道的模型目录。
    func fetchModels() {
        guard canFetchModels, let channel = activeChannel else { return }
        fetchingModels = true
        busy = true
        feedback = "正在获取可用模型…"
        feedbackIsError = false
        send([
            "action": "list-models",
            "baseUrl": channel.baseUrl,
            "apiKey": channel.apiKey,
            "headerName": channel.headerName,
            "headerValue": channel.headerValue,
        ])
    }

    // MARK: 响应

    func apply(_ response: [String: Any]) {
        if let value = response["version"] as? String, !value.isEmpty, value != version {
            version = value
        }
        if let value = response["proxy"] as? [String: Any],
           let host = value["host"] as? String,
           let port = value["port"] as? Int {
            proxyHost = host
            proxyPort = String(port)
            savedProxyHost = host
            savedProxyPort = String(port)
        }
        if let value = response["agents"] as? [String: Any],
           let content = value["content"] as? String {
            agentsContent = content
            savedAgentsContent = content
            agentsSource = value["source"] as? String ?? ""
            agentsBackupPath = value["backupPath"] as? String ?? ""
            agentsError = value["error"] as? String ?? ""
            agentsEnabled = value["enabled"] as? Bool ?? false
            savedAgentsEnabled = agentsEnabled
        }
        if let value = response["appearance"] as? [String: Any] {
            applyAppearance(value)
            if response["event"] as? String == "appearance-updated" {
                feedback = ""
                feedbackIsError = false
                return
            }
        }
        if checkingUpdate {
            finishUpdateCheck(response)
            return
        }
        if fetchingModels {
            finishModelFetch(response)
            return
        }
        if savingAppearance {
            savingAppearance = false
            busy = false
            if response["ok"] as? Bool == true,
               let value = response["appearance"] as? [String: Any] {
                applyAppearance(value)
                if response["restartRequired"] as? Bool == true {
                    feedback = "主题已保存，重启 ChatGPT 后生效"
                    feedbackIsError = false
                } else {
                    let name = appearanceThemes.first(where: { $0.id == appearanceTheme })?.name ?? appearanceTheme
                    feedback = "已切换到「\(name)」并应用到 ChatGPT"
                    feedbackIsError = false
                }
            } else {
                appearanceTheme = appearanceThemeBeforeSave
                appearanceFollowNative = appearanceFollowNativeBeforeSave
                appearanceNativeMode = appearanceNativeModeBeforeSave
                feedback = response["error"] as? String ?? "应用外观主题失败"
                feedbackIsError = true
            }
            return
        }
        if savingProxy {
            savingProxy = false
            busy = false
            if response["ok"] as? Bool == true,
               let value = response["proxy"] as? [String: Any],
               let host = value["host"] as? String,
               let port = value["port"] as? Int {
                proxyHost = host
                proxyPort = String(port)
                savedProxyHost = host
                savedProxyPort = String(port)
                feedback = "代理配置已保存，重启 ChatGPT 后生效"
                feedbackIsError = false
            } else {
                feedback = response["error"] as? String ?? "保存代理配置失败"
                feedbackIsError = true
            }
            return
        }
        if savingAgents {
            savingAgents = false
            busy = false
            if response["ok"] as? Bool == true,
               let value = response["agents"] as? [String: Any],
               let content = value["content"] as? String {
                agentsContent = content
                savedAgentsContent = content
                agentsSource = value["source"] as? String ?? ""
                agentsBackupPath = value["backupPath"] as? String ?? ""
                agentsError = ""
                agentsEnabled = value["enabled"] as? Bool ?? false
                savedAgentsEnabled = agentsEnabled
                let keptUserFile = value["keptUserFile"] as? Bool == true
                feedback = keptUserFile && !agentsBackupPath.isEmpty
                    ? "公共指令已同步，原文件已备份"
                    : "公共指令已保存"
                feedbackIsError = false
            } else {
                feedback = response["error"] as? String ?? "保存公共指令失败"
                feedbackIsError = true
            }
            return
        }
        busy = false
        restarting = false
        let ok = response["ok"] as? Bool == true
        let cleared = response["cleared"] as? Bool == true
        let pending = pendingRestore
        pendingRestore = nil
        let leaveEditor = leaveEditorAfterSave
        leaveEditorAfterSave = false
        if ok || response["saved"] as? Bool == true || cleared {
            if let value = response["channels"],
               let data = try? JSONSerialization.data(withJSONObject: value),
               let rows = try? JSONDecoder().decode([ChannelRow].self, from: data) {
                // 只有停在编辑页时才按渠道 ID 找回来；列表页没有当前渠道，别拿 0 号顶上。
                let editingChannelID = editingIndex.flatMap { channels.indices.contains($0) ? channels[$0].id : nil }
                channels = rows
                savedChannels = rows
                currentChannelID = response["current"] as? String
                loaded = true
                if let editingChannelID, let index = rows.firstIndex(where: { $0.id == editingChannelID }) {
                    editingIndex = index
                }
                if let index = editingIndex, !rows.indices.contains(index) { editingIndex = nil }
            }
        }
        if !ok {
            if let pending { channels = pending }
            feedback = response["error"] as? String ?? "操作失败"
            feedbackIsError = true
        } else if cleared || response["restarted"] as? Bool == true {
            // 清空和重启都把配置写进了客户端：底栏那句「等重启」到此为止。
            feedback = ""
            feedbackIsError = false
            restartNeeded = false
            appliedChannels = channels
        } else if response["saved"] as? Bool == true {
            // 只存盘有两种：改配置要重启才写进客户端；翻开关、删渠道立刻生效，不留提示。
            // 后一种客户端手里已经换成这份列表了（注入器会重推一次），基线跟着走，
            // 免得改动再改回原值还挂着「配置有更新」让人白重启一次。
            feedback = ""
            feedbackIsError = false
            if pending == nil { restartNeeded = channels != appliedChannels } else { appliedChannels = channels }
            if leaveEditor { showList() }
        } else {
            feedback = ""
            feedbackIsError = false
            // 读配置：面板刚打开时按「文件里的就是客户端里的」算。
            appliedChannels = channels
        }
    }

    /// 双端共用后端主题目录；路径为空时只影响预览图，不影响实际保存主题。
    private func applyAppearance(_ value: [String: Any]) {
        if let theme = value["theme"] as? String, !theme.isEmpty {
            appearanceTheme = theme
        }
        appearanceFollowNative = value["followNative"] as? Bool ?? false
        appearanceNativeMode = value["nativeMode"] as? String ?? "light"
        if let rows = value["themes"] as? [[String: Any]] {
            appearanceThemes = rows.compactMap { row in
                guard let id = row["id"] as? String,
                      let name = row["name"] as? String else { return nil }
                return AppearanceThemeRow(
                    id: id,
                    name: name,
                    previewPath: row["previewPath"] as? String ?? "",
                    coverPath: row["coverPath"] as? String ?? "",
                    cardBackground: row["cardBackground"] as? String ?? "",
                    colorScheme: row["colorScheme"] as? String ?? "light")
            }
        }
    }

    /// 渠道端点公布的模型：id 一定有，显示名和窗口只在端点给出时才有。
    private func finishModelFetch(_ response: [String: Any]) {
        fetchingModels = false
        busy = false
        guard response["ok"] as? Bool == true,
              let value = response["models"],
              let data = try? JSONSerialization.data(withJSONObject: value),
              let rows = try? JSONDecoder().decode([DiscoveredModel].self, from: data),
              channels.indices.contains(activeIndex) else {
            feedback = response["error"] as? String ?? "获取可用模型失败"
            feedbackIsError = true
            return
        }
        discoveredModels = rows
        discoveredSelection = []
        discoveryFilter = ""
        feedback = "已获取 \(rows.count) 个可用模型，勾选后添加"
        feedbackIsError = false
    }

    /// 清单只在面板里挑，没点「添加所选」之前不动模型目录。
    var discovering: Bool { !discoveredModels.isEmpty }

    func cancelDiscovery() {
        guard discovering else { return }
        discoveredModels = []
        discoveredSelection = []
        discoveryFilter = ""
        feedback = isDirty ? "有未保存的更改" : ""
        feedbackIsError = false
    }

    /// 勾上的补进当前渠道；已经在目录里的不重复加。
    func addSelectedModels() {
        guard channels.indices.contains(activeIndex) else { return }
        let existing = Set(channels[activeIndex].models.map(\.id))
        let picked = discoveredModels.filter { discoveredSelection.contains($0.id) && !existing.contains($0.id) }
        channels[activeIndex].models.append(contentsOf: picked.map { row in
            var model = ModelRow(id: row.id)
            model.displayName = row.displayName ?? ""
            if let context = row.context { model.context = context }
            return model
        })
        let added = picked.count
        cancelDiscovery()
        feedback = added > 0 ? "已添加 \(added) 个模型，点「保存」后生效" : "勾选的模型都已经在目录里"
        feedbackIsError = false
    }

    private func finishUpdateCheck(_ response: [String: Any]) {
        checkingUpdate = false
        guard response["ok"] as? Bool == true, let latest = response["latest"] as? String else {
            updateTitle = "重试"
            updateEnabled = true
            return
        }
        if isVersion(latest, newerThan: version) {
            pendingUpdateURL = (response["url"] as? String).flatMap(URL.init(string:))
            updateTitle = "去下载 v\(latest)"
        } else {
            pendingUpdateURL = nil
            updateTitle = "已是最新"
        }
        updateEnabled = true
    }
}

// MARK: - 界面

/// SwiftUI 的 ScrollView 底下还是 NSScrollView，系统设置成「始终显示滚动条」时
/// 会被强制画成传统样式。这里关掉系统指示条，自己画一条细圆角条。
private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
}

private struct ScrollMetricsKey: PreferenceKey {
    static var defaultValue = ScrollMetrics()
    static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) {
        // 没挂 preference 的兄弟节点会送来默认值，别让它把真实测量覆盖掉。
        let next = nextValue()
        if next.contentHeight > 0 { value = next }
    }
}

struct OverlayScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var metrics = ScrollMetrics()

    private let coordinateSpace = "gpt-switch-scroll"

    var body: some View {
        GeometryReader { outer in
            ScrollView(.vertical, showsIndicators: false) {
                content.background(
                    GeometryReader { inner in
                        Color.clear.preference(key: ScrollMetricsKey.self, value: ScrollMetrics(
                            offset: -inner.frame(in: .named(coordinateSpace)).minY,
                            contentHeight: inner.size.height))
                    }
                )
            }
            .coordinateSpace(name: coordinateSpace)
            .onPreferenceChange(ScrollMetricsKey.self) { metrics = $0 }
            .overlay(alignment: .topTrailing) { indicator(viewport: outer.size.height) }
        }
    }

    @ViewBuilder
    private func indicator(viewport: CGFloat) -> some View {
        let scrollable = max(metrics.contentHeight - viewport, 0)
        if scrollable > 1 {
            let track = max(viewport - 16, 0)
            let thumb = max(track * min(viewport / metrics.contentHeight, 1), 36)
            let progress = min(max(metrics.offset / scrollable, 0), 1)
            Capsule()
                .fill(Color.primary.opacity(0.22))
                .frame(width: 5, height: thumb)
                .offset(y: 8 + (track - thumb) * progress)
                .padding(.trailing, 5)
                .allowsHitTesting(false)
        }
    }
}

struct PanelView: View {
    @ObservedObject var store: PanelStore
    @State private var selectedSection: SidebarSection

    /// 初始页默认模型；指定其它页只用于预览和截图测试，复用同一套侧栏。
    init(store: PanelStore, selectedSection: SidebarSection = .models) {
        self.store = store
        _selectedSection = State(initialValue: selectedSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                selection: $selectedSection,
                onSelect: guardSectionSelection
            )
                .frame(width: 190)
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 卡片只挡鼠标挡不住键盘：不把底下的表单停下，打字还会进到被遮住的输入框。
        .disabled(store.deletePromptText != nil || store.discovering)
        .frame(minWidth: 820, minHeight: 560)
        .tint(accentBottom)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [Color(nsColor: .windowBackgroundColor).opacity(0.9),
                                        panelTint],
                               startPoint: .top, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
        }
        .overlay { modalLayer }
        .confirmationDialog("还原 ChatGPT 配置并重启客户端？", isPresented: $store.confirmingClear) {
            Button("还原并重启", role: .destructive) { store.clearAndRestart() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(clearPromptMessage)
        }
        .confirmationDialog(restartPromptTitle, isPresented: restartPromptPresented, titleVisibility: .visible) {
            Button("重启") { store.confirmRestart() }
            Button("取消", role: .cancel) { store.cancelRestart() }
        } message: {
            Text("会重新写入 ChatGPT 配置和全部渠道的模型目录，然后重启客户端。")
        }
    }

    /// 右侧只按当前侧栏项换内容，模型列表和编辑页仍沿用原来的页面切换。
    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedSection {
                case .models:
                    if store.editingIndex == nil {
                        ChannelListView(store: store)
                    } else {
                        ChannelDetailView(store: store)
                    }
                case .proxy:
                    ProxySettingsView(store: store)
                case .about:
                    AboutView(store: store)
                case .agents:
                    AgentsSettingsView(store: store)
                case .appearance:
                    AppearanceSettingsView(store: store)
                case .general, .help:
                    EmptyPanelView(store: store, title: selectedSection.rawValue)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            PanelFeedbackBar(store: store, restartHint: restartHint)
        }
    }

    /// 重启入口只在模型列表页；编辑页和其它分区要说清楚先回到哪个页面。
    private var restartHint: String {
        if selectedSection != .models {
            return "配置有更新，回到「模型」后点右上角「重启 ChatGPT」生效"
        }
        if store.editingIndex != nil {
            return "配置有更新，保存后回模型列表点右上角「重启 ChatGPT」生效"
        }
        return "配置有更新，点右上角「重启 ChatGPT」生效"
    }

    /// 有未保存编辑时必须在动手前说清楚，还原只会保留落盘的那份渠道列表。
    private var clearPromptMessage: String {
        if store.isDirty {
            return "会还原插件写进 ChatGPT 的渠道配置、清掉模型目录并重启客户端；未保存的改动不会保留，已保存的渠道列表保留。"
        }
        return "会还原插件写进 ChatGPT 的渠道配置、清掉模型目录并重启客户端；面板里保存的渠道列表保留。"
    }

    private let restartPromptTitle = "重启 ChatGPT？"

    private var restartPromptPresented: Binding<Bool> {
        Binding(get: { store.restartPrompt },
                set: { presented in if !presented { store.cancelRestart() } })
    }

    /// 离开 Agents 时先拦住未保存的正文和开关；其它导航直接写入 @State，保证菜单立刻刷新。
    private func guardSectionSelection(_ next: SidebarSection) -> Bool {
        guard next != selectedSection else { return false }
        if store.savingAgents { return false }
        if store.agentsDirty {
            let alert = NSAlert()
            alert.messageText = "Agents 有未保存的更改"
            alert.informativeText = "要放弃草稿并离开吗？"
            alert.addButton(withTitle: "继续编辑")
            alert.addButton(withTitle: "放弃并离开")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            store.discardAgentsDraft()
        }
        return true
    }

    /// 列表和编辑页共用这一层：要么问一句删不删，要么让人挑要加哪些模型。
    @ViewBuilder
    private var modalLayer: some View {
        if let prompt = store.deletePromptText {
            DeleteConfirmCard(title: prompt.title, message: prompt.message, confirmTitle: prompt.confirm,
                              onCancel: { store.cancelDelete() }, onConfirm: { store.confirmDelete() })
        } else if store.discovering {
            ModelPickerCard(store: store)
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: SidebarSection
    let onSelect: (SidebarSection) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("GPT Switch")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.9))
                .padding(.horizontal, 14)
                .padding(.top, 22)
                .padding(.bottom, 18)
            Text("设置")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            ForEach(SidebarSection.settings, id: \.self) { section in
                SidebarRow(section: section, selection: $selection, onSelect: onSelect)
            }
            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            SidebarRow(section: .about, selection: $selection, onSelect: onSelect)
            SidebarRow(section: .help, selection: $selection, onSelect: onSelect)
            Spacer(minLength: 20)
        }
        .background(sidebarBackground)
    }
}

private struct SidebarRow: View {
    let section: SidebarSection
    @Binding var selection: SidebarSection
    let onSelect: (SidebarSection) -> Bool

    var body: some View {
        Button {
            guard onSelect(section) else { return }
            selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selection == section ? accentBottom : Color.primary.opacity(0.78))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selection == section ? accentBottom.opacity(0.13) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .withoutFocusRing()
        .pointingHand()
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .accessibilityAddTraits(selection == section ? .isSelected : [])
    }
}

/// 侧栏页面共用页头：标题、说明、全局重启入口和下方的分割线只在这里维护。
private struct PanelHeader: View {
    @ObservedObject var store: PanelStore
    let title: String
    let detail: String
    var showsRestart = false
    var content: AnyView?

    init(store: PanelStore, title: String, detail: String, showsRestart: Bool = false) {
        self.store = store
        self.title = title
        self.detail = detail
        self.showsRestart = showsRestart
        content = nil
    }

    init<Accessory: View>(
        store: PanelStore,
        title: String,
        detail: String,
        showsRestart: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.store = store
        self.title = title
        self.detail = detail
        self.showsRestart = showsRestart
        content = AnyView(accessory())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 20, weight: .regular))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let content {
                content
            } else if showsRestart {
                RestartButton(store: store)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
        }
    }
}

/// 主题选择沿用注入器返回的同一份目录；卡片选中后立即保存，顶部和网格共用预览资源。
private struct AppearanceSettingsView: View {
    @ObservedObject var store: PanelStore

    private var selectedTheme: AppearanceThemeRow? {
        store.appearanceThemes.first(where: { $0.id == store.appearanceTheme })
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                store: store,
                title: "外观",
                detail: "选择一套主题，立即改变 ChatGPT 的背景、侧栏、输入框和弹窗。",
                showsRestart: true)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    AppearanceThemePreview(
                        imagePath: selectedTheme?.previewPath ?? "",
                        applying: store.savingAppearance,
                        isDark: selectedTheme?.colorScheme == "dark")
                        .padding(.bottom, 20)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("全部主题")
                            .font(.system(size: 14, weight: .semibold))
                        Text("选择后立即应用")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 12)

                    if store.appearanceThemes.isEmpty {
                        HStack(spacing: 8) {
                            if !store.loaded {
                                ProgressView().controlSize(.small)
                            }
                            Text(store.loaded ? "主题资源不可用" : "正在读取主题…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 18)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 112, maximum: 160), spacing: 12)],
                            alignment: .leading,
                            spacing: 16
                        ) {
                            ForEach(store.appearanceThemes) { theme in
                                AppearanceThemeCard(
                                    theme: theme,
                                    selected: theme.id == store.appearanceTheme,
                                    disabled: store.busy
                                ) {
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        store.selectAppearanceTheme(theme)
                                    }
                                }
                            }
                            AppearanceComingSoonCard()
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(panelBackground)
    }
}

/// 顶部大图按源图比例完整展示，避免容器过宽时拉伸或裁切素材。
private struct AppearanceThemePreview: View {
    let imagePath: String
    let applying: Bool
    let isDark: Bool

    private var image: NSImage? {
        NSImage(contentsOfFile: imagePath)
    }

    private var previewAspectRatio: CGFloat {
        guard let image, image.size.height > 0 else { return 8.0 / 5.0 }
        return image.size.width / image.size.height
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    LinearGradient(
                        colors: isDark
                            ? [Color(nsColor: .darkGray), Color.black]
                            : [accentTop.opacity(0.14), accentBottom.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                }
                if applying {
                    Color.black.opacity(0.08)
                    ProgressView()
                        .controlSize(.large)
                        .tint(accentBottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.09))
            }
        }
        .aspectRatio(previewAspectRatio, contentMode: .fit)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct AppearanceThemeCard: View {
    let theme: AppearanceThemeRow
    let selected: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Button(action: action) {
                GeometryReader { proxy in
                    ZStack {
                        if let image = NSImage(contentsOfFile: theme.coverPath) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        } else {
                            appearanceHexColor(
                                theme.cardBackground,
                                fallback: theme.colorScheme == "dark" ? Color(nsColor: .darkGray) : Color.white)
                        }
                        if selected {
                            VStack {
                                HStack {
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white, accentBottom)
                                        .padding(8)
                                }
                                Spacer()
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                selected ? accentBottom : Color.primary.opacity(hovering ? 0.22 : 0.09),
                                lineWidth: selected ? 2 : 1)
                    }
                    .shadow(
                        color: .black.opacity(hovering && !selected ? 0.13 : 0.05),
                        radius: hovering ? 7 : 3,
                        y: 2)
                }
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .withoutFocusRing()
            .pointingHand()
            .disabled(disabled)
            .onHover { hovering = $0 }
            .accessibilityLabel("\(theme.name)主题\(selected ? "，当前使用" : "")")
            .accessibilityAddTraits(selected ? .isSelected : [])

            Text(theme.name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }
}

private struct AppearanceComingSoonCard: View {
    var body: some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.055))
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
                .overlay {
                    Text("敬请期待")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
            Text(" ")
                .font(.system(size: 12))
        }
        .accessibilityHidden(true)
    }
}

/// 重启会同时写入全部渠道和代理设置，所以各设置页沿用同一个入口与确认流程。
private struct RestartButton: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        Button { store.requestRestart() } label: {
            Text(store.restarting ? "重启中" : "重启 ChatGPT")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(accentGradient))
                .shadow(color: accentBottom.opacity(0.18), radius: 6, y: 2)
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .withoutFocusRing()
        .pointingHand()
        .opacity(store.canRestart ? 1 : 0.45)
        .disabled(!store.canRestart)
    }
}

private struct EmptyPanelView: View {
    @ObservedObject var store: PanelStore
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(store: store, title: title, detail: "")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(panelBackground)
    }
}

/// 公共指令默认展示内置模板；用户可以编辑草稿，启用保存后写入 Codex。
private struct AgentsSettingsView: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                store: store,
                title: "Agents",
                detail: "维护所有项目共用的 Markdown 指令。"
            ) {
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Text("启用").font(.system(size: 13))
                        Toggle("", isOn: $store.agentsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(store.busy)
                            .help("启用后，保存时把编辑器内容写入 ~/.codex/AGENTS.md")
                    }
                    RestartButton(store: store)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("公共指令").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("~/.codex/AGENTS.md")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    MarkdownTextEditor(text: $store.agentsContent, isEditable: !store.busy)
                        .frame(minHeight: 280)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.primary.opacity(0.14)))
                        .accessibilityLabel("Agents 公共指令")
                    Text("启用时会先备份原 AGENTS.md；关闭只停止同步，不恢复原文件。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if !store.agentsBackupPath.isEmpty {
                        Text("最近备份：\(store.agentsBackupPath)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.07)))
                HStack {
                    Text(store.agentsError.isEmpty
                         ? "保存草稿；启用状态下同时写入公共 AGENTS.md。"
                         : store.agentsError)
                        .font(.system(size: 11))
                        .foregroundStyle(store.agentsError.isEmpty ? Color.secondary : Color.red)
                    Spacer()
                    Button("保存") { store.saveAgents() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(accentBottom)
                        .disabled(!store.loaded || store.busy || !store.agentsDirty)
                        .pointingHand()
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .background(panelBackground)
    }
}

/// Markdown 指令必须保留用户输入的直引号、连字符和代码字符，关闭系统文本自动替换。
private struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// 创建支持滚动和撤销的纯文本编辑区，并关闭会改写 Markdown 的系统替换。
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.string = text
        textView.delegate = context.coordinator
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        scrollView.documentView = textView
        return scrollView
    }

    /// 只在外部载入或保存回包改变内容时替换文本，避免滚动时反复重置编辑区。
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else {
            (scrollView.documentView as? NSTextView)?.isEditable = isEditable
            return
        }
        textView.isEditable = isEditable
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor

        init(parent: MarkdownTextEditor) {
            self.parent = parent
        }

        /// 把原生编辑内容同步回面板草稿，驱动未保存状态和保存按钮。
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  parent.text != textView.string else { return }
            parent.text = textView.string
        }
    }
}

/// 代理服务本身负责替换渠道密钥，只允许本机回环监听；端口范围与 CC Switch 保持一致。
private struct ProxySettingsView: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                store: store,
                title: "代理",
                detail: "控制本地转发服务监听的 IP 和端口；保存后点「重启 ChatGPT」生效。",
                showsRestart: true)
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("监听 IP").font(.system(size: 13, weight: .medium))
                            TextField("127.0.0.1", text: $store.proxyHost)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .fieldBox()
                            Text("必须是合法 IPv4。建议使用 127.0.0.1；开放到局域网会增加密钥暴露风险。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("监听端口").font(.system(size: 13, weight: .medium))
                            TextField("47123", text: $store.proxyPort)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .fieldBox()
                            Text("1024–65535；被占用时自动顺延并更新此端口。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        Text("保存只会写入配置。地址或端口变化后，需要重启 ChatGPT 才能切换服务。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button("保存") { store.saveProxy() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(accentBottom)
                            .disabled(!store.canSaveProxy)
                            .pointingHand()
                    }
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.07)))
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .background(panelBackground)
        .disabled(store.busy)
    }
}

private struct AboutView: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(store: store, title: "关于", detail: "")
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 0) {
                    AboutRow(
                        title: "当前版本",
                        detail: store.version.isEmpty ? "" : "v\(store.version)",
                        inlineDetail: true,
                        buttonTitle: store.updateTitle
                    ) {
                        store.checkForUpdates()
                    }
                    .disabled(!store.updateEnabled || store.busy)
                    Divider().padding(.leading, 18)
                    AboutRow(
                        title: "还原配置",
                        detail: "还原 ChatGPT 侧配置与模型目录，面板里的渠道列表保留。",
                        buttonTitle: "还原配置"
                    ) {
                        store.confirmingClear = true
                    }
                    .disabled(!store.loaded || store.busy)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.07))
                )
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .background(panelBackground)
    }
}

private struct AboutRow: View {
    let title: String
    let detail: String
    var inlineDetail = false
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                if inlineDetail {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 16)
            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(accentBottom)
                .foregroundStyle(accentBottom)
                .pointingHand()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

/// 搜索框按文字自适应高度：用写死的 38pt 框时，光标一进去 AppKit 的编辑区就把
/// 文字顶到框顶，框里空出一大截。上下留白对称，编辑与否都居中。
private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("搜索模型", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? accentBottom.opacity(0.6) : Color.primary.opacity(0.16))
            )
    }
}

/// 端点公布的清单先在这里勾选，点「添加所选」才进模型目录。
struct ModelPickerCard: View {
    @ObservedObject var store: PanelStore

    private var visible: [DiscoveredModel] {
        let keyword = store.discoveryFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !keyword.isEmpty else { return store.discoveredModels }
        return store.discoveredModels.filter { $0.id.lowercased().contains(keyword) }
    }

    private var listHeight: CGFloat {
        min(max(CGFloat(visible.count) * 30 + 10, 64), 220)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Text("选择要添加的模型").font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 0)
                    Button { store.cancelDiscovery() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .pointingHand()
                }
                Text("以下是模型提供商的可用模型，勾选要添加的模型。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    SearchField(text: $store.discoveryFilter)
                    Toggle("全选", isOn: allVisible)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                        .pointingHand()
                        .disabled(visible.isEmpty)
                }
                Divider()
                OverlayScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(visible, id: \.id) { row in
                            Toggle(isOn: selected(row.id)) {
                                Text(row.id).font(.system(size: 14, design: .monospaced))
                            }
                            .toggleStyle(.checkbox)
                            .pointingHand()
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: listHeight)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button("取消") { store.cancelDiscovery() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .pointingHand()
                    Button("添加所选") { store.addSelectedModels() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .pointingHand()
                        .disabled(store.discoveredSelection.isEmpty)
                }
            }
            .padding(24)
            .frame(width: 460)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.thickMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            )
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.1)))
        }
    }

    /// 「全选」按当前筛出来的那些算：筛过之后再全选，只全选看得见的。
    private var allVisible: Binding<Bool> {
        Binding(
            get: { !visible.isEmpty && visible.allSatisfy { store.discoveredSelection.contains($0.id) } },
            set: { on in
                for row in visible {
                    if on { store.discoveredSelection.insert(row.id) } else { store.discoveredSelection.remove(row.id) }
                }
            }
        )
    }

    private func selected(_ id: String) -> Binding<Bool> {
        Binding(
            get: { store.discoveredSelection.contains(id) },
            set: { on in
                if on { store.discoveredSelection.insert(id) } else { store.discoveredSelection.remove(id) }
            }
        )
    }
}

struct DeleteConfirmCard: View {
    let title: String
    let message: String
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            // Color 自己吃点击，浮层挡住底下的按钮，不用再加手势。
            Color.black.opacity(0.12)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 0)
                    Button(action: onCancel) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .pointingHand()
                }
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button("取消", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .pointingHand()
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .foregroundStyle(Color.red)
                        .background(
                            RoundedRectangle(cornerRadius: 7).fill(Color.red.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7).strokeBorder(Color.red.opacity(0.6))
                        )
                        .pointingHand()
                }
            }
            .padding(24)
            .frame(width: 460)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.thickMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            )
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}

struct ChannelListView: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                store: store,
                title: "模型",
                detail: "聚合多条渠道，模型合进同一份选择器目录按渠道折叠成组。",
                showsRestart: true)

            OverlayScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(store.channels.indices), id: \.self) { index in
                        ChannelCard(store: store, index: index)
                    }
                    DashedRowButton(title: "添加渠道", systemImage: "plus") { store.addChannel() }
                        .disabled(!store.loaded || store.busy || store.channels.count >= 50)
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
        }
        .background(panelBackground)
    }
}

struct ChannelCard: View {
    @ObservedObject var store: PanelStore
    let index: Int
    @State private var hovering = false

    /// 删渠道后 SwiftUI 也会用旧下标再求一次 body，越界会崩掉面板进程。
    private var channel: ChannelRow {
        store.channels.indices.contains(index) ? store.channels[index] : ChannelRow()
    }

    /// 启用状态沿用面板的绿色主题，深浅色由动态色自己切。
    private var badgeInk: Color {
        channel.enabled ? accentBottom : Color.primary.opacity(0.55)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.id.isEmpty ? "未填渠道 ID" : channel.id)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text(channel.baseUrl.isEmpty ? "还没填地址" : channel.baseUrl)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // 每条渠道一个开关：禁用只是这条不能用，别的渠道照常。
            HStack(spacing: 10) {
                Text(channel.enabled ? "已启用" : "已禁用")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(badgeInk)
                    // 中文字形落在行框偏下，补 1.5pt 下内边距才在这个小徽标里居中。
                    .padding(.horizontal, 8)
                    .padding(.bottom, 1.5)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(channel.enabled ? accentBottom.opacity(0.14) : Color.primary.opacity(0.07)))
                Button { store.toggleChannel(at: index) } label: {
                    ZStack(alignment: .leading) {
                        Capsule().fill(channel.enabled ? AnyShapeStyle(accentGradient)
                                                        : AnyShapeStyle(Color.primary.opacity(0.16)))
                        Circle()
                            .fill(.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                            .padding(2)
                            .offset(x: channel.enabled ? 14 : 0)
                    }
                    .frame(width: 32, height: 18)
                    .contentShape(Capsule())
                    .animation(.easeOut(duration: 0.16), value: channel.enabled)
                }
                .buttonStyle(.plain)
                .withoutFocusRing()
                .pointingHand()
                .help(channel.enabled ? "禁用这条渠道" : "启用这条渠道")
                // 自绘形状里没有文字，读屏走到这儿得知道这是哪条渠道的什么开关。
                .accessibilityLabel("\(channelDisplayLabel(channel)) \(channel.enabled ? "已启用" : "已禁用")")
                .opacity(store.busy ? 0.5 : 1)
                .disabled(store.busy)
                Button { store.editChannel(at: index) } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        // 这两个字形本身就偏下，抬 1px 才跟左边的文字和胶囊齐。
                        .offset(y: -1)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .pointingHand()
                .disabled(store.busy)
                Button { store.requestDelete(at: index) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .offset(y: -1)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .pointingHand()
                .disabled(store.busy)
                .help("删除渠道")
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 1 : 0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.07))
        )
        .shadow(color: .black.opacity(hovering ? 0.07 : 0.05), radius: hovering ? 12 : 6, y: hovering ? 4 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

struct ChannelDetailView: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { store.requestLeaveEditor() } label: {
                    Label("返回", systemImage: "chevron.left").font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .pointingHand()
                .disabled(store.busy)
                Text(store.editingTitle).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("删除渠道", role: .destructive) { store.requestDelete(at: store.activeIndex) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .pointingHand()
                    .disabled(!store.hasChannel || store.busy)
                    .help("删除渠道")
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 16)

            OverlayScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("渠道信息")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                    channelForm
                    HStack(spacing: 12) {
                        Text("模型目录")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button(store.fetchingModels ? "获取中…" : "获取可用模型") { store.fetchModels() }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                            .foregroundStyle(accentBottom)
                            .withoutFocusRing()
                            .pointingHand()
                            .disabled(!store.canFetchModels)
                    }
                    .padding(.horizontal, 2)
                    ForEach(Array(store.models.indices), id: \.self) { index in
                        ModelCard(store: store, index: index)
                    }
                    DashedRowButton(title: "添加模型", systemImage: "plus") { store.addModel() }
                        .disabled(!store.hasChannel || store.busy)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("保存") { store.save() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .pointingHand()
                    .disabled(!store.isDirty || store.busy || !store.hasChannel || store.channelIDError != nil)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 18)
        }
        .background(panelBackground)
    }

    @ViewBuilder
    private var channelForm: some View {
        if store.hasChannel {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledField(title: "渠道 ID", placeholder: "输入渠道 ID",
                                 text: $store.channels[store.activeIndex].id)
                    if let error = store.channelIDError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }
                LabeledField(title: "API 密钥", placeholder: "输入 API 密钥",
                             text: $store.channels[store.activeIndex].apiKey, secure: true)
                LabeledField(title: "API 地址", placeholder: "https://gateway.example/v1",
                             text: $store.channels[store.activeIndex].baseUrl)
                LabeledField(title: "请求头名（可选）", placeholder: "Authorization",
                             text: $store.channels[store.activeIndex].headerName)
                LabeledField(title: "请求头值", placeholder: "值",
                             text: $store.channels[store.activeIndex].headerValue)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 1)
        }
    }
}

struct ModelCard: View {
    @ObservedObject var store: PanelStore
    let index: Int

    private var model: Binding<ModelRow> {
        // 删除后 SwiftUI 还会拿旧下标求一次值，直接下标会越界崩掉面板进程。
        Binding(
            get: { store.models.indices.contains(index) ? store.models[index] : ModelRow() },
            set: { newValue in
                guard store.channels.indices.contains(store.activeIndex),
                      store.channels[store.activeIndex].models.indices.contains(index) else { return }
                store.channels[store.activeIndex].models[index] = newValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                Button { store.requestModelDelete(at: index) } label: {
                    Image(systemName: "trash").font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .pointingHand()
                .disabled(store.busy)
            }
            LabeledField(title: "模型 ID", placeholder: "gpt-6-astra", text: model.id)
            // 客户端按模型 ID 发请求、按显示名称渲染选择器：名字只影响列表里怎么显示。
            LabeledField(title: "显示名称", placeholder: "留空就用模型 ID", text: model.displayName)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("上下文窗口（k）")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("272", text: contextText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .fieldBox()
                        .frame(width: 180)
                }
                Text("约 \(contextConversionLabel(model.wrappedValue.context))")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("输入类型与能力")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Toggle("文本", isOn: modality("text"))
                    Toggle("图片", isOn: modality("image"))
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 14))
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 1)
    }

    private func modality(_ name: String) -> Binding<Bool> {
        Binding(
            get: { model.wrappedValue.inputModalities.contains(name) },
            set: { store.toggleModality(at: index, modality: name, on: $0) }
        )
    }

    /// 窗口是 k 数，只收数字，别让系统加上千分位。
    private var contextText: Binding<String> {
        Binding(
            get: { String(model.wrappedValue.context) },
            set: { value in
                let digits = value.filter(\.isNumber)
                if let parsed = Int(digits), parsed >= 1 { model.wrappedValue.context = parsed }
            }
        )
    }
}

struct LabeledField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var width: CGFloat?
    var secure = false
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                // 密钥默认打码；要核对时点右边的眼睛看一眼。
                Group {
                    if secure && !revealed {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                if secure {
                    Button { revealed.toggle() } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .pointingHand()
                }
            }
            .fieldBox()
            .frame(width: width)
        }
    }
}

/// 系统 roundedBorder 会画一圈很重的聚焦蓝框，跟参考图那种浅灰输入框不一样。
private struct FieldBox: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(focused ? accentBottom.opacity(0.6) : Color.primary.opacity(0.14))
            )
            .fieldCursor()
    }
}

extension View {
    func fieldBox() -> some View { modifier(FieldBox()) }
}

/// SwiftUI 的按钮在 macOS 上默认不换成手型光标，得自己推栈。
private struct CursorPush: ViewModifier {
    let cursor: NSCursor
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard isEnabled else { return }
                if inside, !hovering {
                    hovering = true
                    cursor.push()
                } else if !inside, hovering {
                    hovering = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if hovering {
                    hovering = false
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    func pointingHand() -> some View { modifier(CursorPush(cursor: .pointingHand)) }
    /// 输入框整框都要 I 型光标：系统只在文字区弹，左右内边距上还是箭头，鼠标划过去会来回跳。
    func fieldCursor() -> some View { modifier(CursorPush(cursor: .iBeam)) }
    /// 自绘的 flat 按钮不要系统焦点环：Tab 照样能选中它，只是不再套一圈蓝框。
    @ViewBuilder func withoutFocusRing() -> some View {
        if #available(macOS 14.0, *) { focusEffectDisabled() } else { self }
    }
}

struct DashedRowButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .withoutFocusRing()
        .pointingHand()
        .opacity(isEnabled ? 1 : 0.45)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}

private struct PanelFeedbackBar: View {
    @ObservedObject var store: PanelStore
    let restartHint: String
    @Environment(\.colorScheme) private var colorScheme

    /// 提醒重启那行字：跟原来那档灰一个明度，只把色相换成红，所以看着是淡红不是正红。
    private var restartInk: Color {
        colorScheme == .dark ? Color(red: 0.93, green: 0.72, blue: 0.71)
                             : Color(red: 0.87, green: 0.55, blue: 0.54)
    }

    /// 这行只说两件事：操作失败的原文，和「配置改了还没写进客户端」。
    private var hint: String {
        if store.feedbackIsError { return store.feedback }
        guard store.restartNeeded else { return store.feedback }
        return restartHint
    }

    private var hintInk: AnyShapeStyle {
        if store.feedbackIsError { return AnyShapeStyle(Color.red) }
        if store.restartNeeded { return AnyShapeStyle(restartInk) }
        return AnyShapeStyle(.tertiary)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(hintInk)
                .lineLimit(1)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 28)
        .frame(height: 36)
        .background(panelBackground)
        .overlay(alignment: .top) {
            if !hint.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            }
        }
    }
}

// MARK: - 控制器

final class StatusMenuController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let parentPID: pid_t
    let iconPath: String
    var statusItem: NSStatusItem?
    var parentMonitor: Timer?
    var window: NSWindow?
    var store: PanelStore?
    /// 仅测试可替换关闭确认结果，生产路径仍由系统对话框询问用户。
    #if STATUS_MENU_TEST
    var discardChangesChoice: (() -> Bool)?
    #endif
    /// 自己主动退出时置位；否则终止请求（程序坞的「退出」、⌘Q）只当作关窗口，
    /// 免得菜单栏图标跟着进程一起没掉，又没人把它拉回来。
    var quitRequested = false

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
        // 图标带品牌色（青蓝渐变）。模板渲染只取 alpha、由系统填成单色，那就和 ChatGPT 官方图标长得一模一样，
        // 等于没换，所以这里按原图绘制。
        icon?.isTemplate = false
        statusItem?.button?.image = icon
        statusItem?.button?.imageScaling = .scaleProportionallyDown
        statusItem?.button?.toolTip = "GPT Switch"
        statusItem?.button?.setAccessibilityLabel("GPT Switch")
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
                self.quitRequested = true
                NSApp.terminate(nil)
            }
        }
    }

    /// 点程序坞图标（或窗口已关掉时再次打开 App）要把面板叫回来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPanel()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitRequested else { return .terminateNow }
        guard canDiscardChanges() else { return .terminateCancel }
        window?.close()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        parentMonitor?.invalidate()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    /// 关窗口只是缩回菜单栏，程序坞图标跟着窗口一起收起来。
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    @objc func openPanel() {
        NSApp.setActivationPolicy(.regular)
        applyPluginApplicationIcon()
        if window == nil { buildPanel() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let store, !store.busy, !store.isDirty, !store.proxyDirty, !store.agentsDirty {
            store.busy = true
            store.feedback = "正在读取配置…"
            sendRequest(["action": "load"])
        }
    }

    /// 切成普通 App 之后程序坞和 ⌘Tab 才出现，macOS 这时会用自己给这个进程挑的图标：这个二进制住在
    /// Contents/Resources 里而不是 Contents/MacOS，系统挑不到 app 包时会借启动它的客户端图标。直接读
    /// 同一个目录里的 AppIcon.icns，和打包脚本放进去的那份一致。
    private func applyPluginApplicationIcon() {
        guard let executable = Bundle.main.executablePath ?? CommandLine.arguments.first else { return }
        let iconURL = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("AppIcon.icns")
        guard let icon = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = icon
    }

    func buildPanel() {
        let store = PanelStore()
        store.send = { [weak self] message in self?.sendRequest(message) }
        self.store = store
        let hosting = NSHostingView(rootView: PanelView(store: store))
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.title = "GPT Switch"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // 窗口本身不画底：毛玻璃才透得出桌面，浅色/深色也跟着系统材质走。
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = hosting
        panel.minSize = NSSize(width: 820, height: 560)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        window = panel
    }

    func receive(_ response: [String: Any]) {
        store?.apply(response)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { canDiscardChanges() }

    func canDiscardChanges() -> Bool {
        // 面板还没建过（没打开过面板就点退出）时没有可丢的改动，直接放行。
        guard let store else { return true }
        if store.savingAgents {
            #if !STATUS_MENU_TEST
            let alert = NSAlert()
            alert.messageText = "正在保存公共指令"
            alert.informativeText = "请等待保存完成后再关闭或退出。"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
            #endif
            return false
        }
        guard store.isDirty || store.proxyDirty || store.agentsDirty else { return true }
        #if STATUS_MENU_TEST
        // 自动化测试不能让人工模态框永久等待；只替换按钮选择，仍走同一套回滚。
        guard discardChangesChoice?() == true else { return false }
        #else
        let alert = NSAlert()
        alert.messageText = "放弃未保存的更改？"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃更改")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        #endif
        store.channels = store.savedChannels
        store.proxyHost = store.savedProxyHost
        store.proxyPort = store.savedProxyPort
        store.discardAgentsDraft()
        store.editingIndex = nil
        return true
    }

    @objc func quitPlugin() {
        guard canDiscardChanges() else { return }
        quitRequested = true
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
        // 面板没有菜单栏，但输入框的 ⌘X/⌘C/⌘V/⌘A 靠主菜单的快捷键派发，缺了它粘贴没反应。
        func buildEditMenu() -> NSMenu {
            let edit = NSMenu(title: "编辑")
            edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            let editItem = NSMenuItem()
            editItem.submenu = edit
            let main = NSMenu()
            main.addItem(editItem)
            return main
        }
        let application = NSApplication.shared
        // 平时只挂菜单栏图标；打开面板时再切成普通 App，程序坞和 ⌘Tab 里才看得到。
        application.setActivationPolicy(.accessory)
        application.mainMenu = buildEditMenu()
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
