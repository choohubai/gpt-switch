import AppKit
import SwiftUI

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
        ["id": id, "displayName": displayName, "context": context, "inputModalities": inputModalities]
    }
}

struct ChannelRow: Codable, Equatable {
    var id: String
    var name: String
    var baseUrl: String
    var apiKey: String
    var headerName: String
    var headerValue: String
    var models: [ModelRow]

    private enum CodingKeys: String, CodingKey {
        case id, name, baseUrl, apiKey, headerName, headerValue, models
    }

    init(id: String = "", name: String = "", baseUrl: String = "", apiKey: String = "",
         headerName: String = "", headerValue: String = "", models: [ModelRow] = []) {
        self.id = id
        self.name = name
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.headerName = headerName
        self.headerValue = headerValue
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
        models = try container.decodeIfPresent([ModelRow].self, forKey: .models) ?? []
    }

    var payload: [String: Any] {
        ["id": id, "name": name, "baseUrl": baseUrl, "apiKey": apiKey,
         "headerName": headerName, "headerValue": headerValue,
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
    @Published var deletePrompt: DeletePrompt?

    var send: ([String: Any]) -> Void = { _ in }
    private var pendingUpdateURL: URL?
    private var checkingUpdate = false
    /// 删除要落盘，存盘失败时把刚拿掉的那条放回去，别让面板和文件对不上。
    private var pendingDelete: (restore: [ChannelRow], note: String)?

    var activeIndex: Int { editingIndex ?? 0 }

    var activeChannel: ChannelRow? {
        channels.indices.contains(activeIndex) ? channels[activeIndex] : nil
    }

    var hasChannel: Bool { activeChannel != nil }
    var isDirty: Bool { channels != savedChannels }

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
        feedback = "有未保存的更改"
        feedbackIsError = false
    }

    /// 删除立刻落盘并回列表页：只从内存里拿掉、人还留在编辑页，等于没删成。
    func deleteChannel(at index: Int) {
        guard channels.indices.contains(index), !busy else { return }
        let removed = channels[index]
        let restore = channels
        channels.remove(at: index)
        pendingDelete = (restore, removed.id.isEmpty ? "已删除渠道" : "已删除渠道「\(removed.id)」")
        showList()
        submit(action: "save", currentID: currentChannelID ?? "", note: "正在删除渠道…")
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

    func save() { submit(action: "save", currentID: currentChannelID ?? "") }

    func enableChannel(at index: Int) {
        guard channels.indices.contains(index), loaded, !busy else { return }
        submit(action: "switch", currentID: channels[index].id)
    }

    private func submit(action: String, currentID: String, note: String? = nil) {
        guard loaded, !busy else { return }
        busy = true
        feedback = note ?? (action == "switch" ? "正在启用渠道并重启 ChatGPT…" : "正在保存…")
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
        feedback = "正在清空并重启 ChatGPT…"
        feedbackIsError = false
        send(["action": "clear"])
    }

    func checkForUpdates() {
        if let pendingUpdateURL {
            NSWorkspace.shared.open(pendingUpdateURL)
            return
        }
        guard !checkingUpdate else { return }
        checkingUpdate = true
        updateTitle = "检查中…"
        updateEnabled = false
        send(["action": "check-update"])
    }

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
        if checkingUpdate {
            finishUpdateCheck(response)
            return
        }
        if fetchingModels {
            finishModelFetch(response)
            return
        }
        busy = false
        let ok = response["ok"] as? Bool == true
        let cleared = response["cleared"] as? Bool == true
        let pending = pendingDelete
        pendingDelete = nil
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
            if let pending { channels = pending.restore }
            feedback = response["error"] as? String ?? "操作失败"
            feedbackIsError = true
        } else if cleared {
            feedback = "已清空并重启 ChatGPT"
            feedbackIsError = false
        } else if response["restarted"] as? Bool == true {
            feedback = "已启用渠道，ChatGPT 已重启"
            feedbackIsError = false
        } else if response["saved"] as? Bool == true {
            feedback = pending?.note ?? "已保存，点列表里的「启用」才会生效"
            feedbackIsError = false
        } else {
            feedback = ""
            feedbackIsError = false
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

    var body: some View {
        VStack(spacing: 0) {
            if store.editingIndex == nil {
                ChannelListView(store: store)
            } else {
                ChannelDetailView(store: store)
            }
            BottomBar(store: store)
        }
        // 卡片只挡鼠标挡不住键盘：不把底下的表单停下，打字还会进到被遮住的输入框。
        .disabled(store.deletePromptText != nil || store.discovering)
        .frame(minWidth: 680, minHeight: 520)
        // 标题栏透明后内容要填满整窗，不然红绿灯那块会露出灰底。
        .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
        .overlay { modalLayer }
        .confirmationDialog("还原 ChatGPT 配置并重启客户端？", isPresented: $store.confirmingClear) {
            Button("还原并重启", role: .destructive) { store.clearAndRestart() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会还原插件写进 ChatGPT 的渠道配置、清掉模型目录并重启客户端；面板里保存的渠道列表保留。")
        }
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
                    .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.16))
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
            // 白底：跟卡片里的白输入框一样平，不然白框压在灰底卡片上像浮着一层。
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            )
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
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
            // 白底：跟卡片里的白输入框一样平，不然白框压在灰底卡片上像浮着一层。
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            )
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}

struct ChannelListView: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("渠道").font(.system(size: 20, weight: .semibold))
                    Text("点「启用」写进 ChatGPT 配置并重启；点右侧铅笔改配置")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("还原 ChatGPT 配置并重启") { store.confirmingClear = true }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .pointingHand()
                    .disabled(!store.loaded || store.busy)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            OverlayScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(store.channels.indices), id: \.self) { index in
                        ChannelCard(store: store, index: index)
                    }
                    DashedRowButton(title: "添加渠道", systemImage: "plus") { store.addChannel() }
                        .disabled(!store.loaded || store.busy || store.channels.count >= 50)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
    }
}

struct ChannelCard: View {
    @ObservedObject var store: PanelStore
    let index: Int

    /// 删渠道后 SwiftUI 也会用旧下标再求一次 body，越界会崩掉面板进程。
    private var channel: ChannelRow {
        store.channels.indices.contains(index) ? store.channels[index] : ChannelRow()
    }
    private var isCurrent: Bool { !channel.id.isEmpty && channel.id == store.currentChannelID }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.id.isEmpty ? "未填渠道 ID" : channel.id)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text(channel.baseUrl.isEmpty ? "还没填地址" : channel.baseUrl)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isCurrent {
                HStack(spacing: 6) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    Text("使用中").font(.system(size: 13, weight: .medium))
                }
            } else {
                Button("启用") { store.enableChannel(at: index) }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .pointingHand()
                    .disabled(store.busy)
            }
            Button { store.editChannel(at: index) } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .pointingHand()
            .disabled(store.busy)
            Button { store.requestDelete(at: index) } label: {
                Image(systemName: "trash").font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .pointingHand()
            .disabled(store.busy)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isCurrent ? Color.accentColor.opacity(0.09) : Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.09))
        )
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
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            OverlayScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    channelForm
                    HStack(spacing: 12) {
                        Text("模型目录")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 12)
                        Button(store.fetchingModels ? "获取中…" : "获取可用模型") { store.fetchModels() }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
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
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("保存") { store.save() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .pointingHand()
                    .disabled(!store.isDirty || store.busy || !store.hasChannel)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
        }
    }

    @ViewBuilder
    private var channelForm: some View {
        if store.hasChannel {
            VStack(alignment: .leading, spacing: 14) {
                LabeledField(title: "渠道 ID", placeholder: "输入渠道 ID",
                             text: $store.channels[store.activeIndex].id)
                LabeledField(title: "API 密钥", placeholder: "输入 API 密钥",
                             text: $store.channels[store.activeIndex].apiKey)
                LabeledField(title: "API 地址", placeholder: "https://gateway.example/v1",
                             text: $store.channels[store.activeIndex].baseUrl)
                LabeledField(title: "请求头名（可选）", placeholder: "Authorization",
                             text: $store.channels[store.activeIndex].headerName)
                LabeledField(title: "请求头值", placeholder: "值",
                             text: $store.channels[store.activeIndex].headerValue)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
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
                Text("输入类型")
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
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
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
                    .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.14))
            )
    }
}

extension View {
    func fieldBox() -> some View { modifier(FieldBox()) }
}

/// SwiftUI 的按钮在 macOS 上默认不换成手型光标，得自己推栈。
private struct PointingHand: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard isEnabled else { return }
                if inside, !hovering {
                    hovering = true
                    NSCursor.pointingHand.push()
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
    func pointingHand() -> some View { modifier(PointingHand()) }
}

struct DashedRowButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .pointingHand()
        .opacity(isEnabled ? 1 : 0.45)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color(nsColor: .separatorColor))
        )
    }
}

struct BottomBar: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        HStack(spacing: 18) {
            Text(store.feedback)
                .font(.system(size: 13))
                .foregroundStyle(store.feedbackIsError ? Color.red : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            if !store.version.isEmpty {
                Text("v\(store.version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Button(store.updateTitle) { store.checkForUpdates() }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .pointingHand()
                .disabled(!store.updateEnabled)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
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
        icon?.isTemplate = true
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
        if window == nil { buildPanel() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let store, !store.busy, !store.isDirty {
            store.busy = true
            store.feedback = "正在读取配置…"
            sendRequest(["action": "load"])
        }
    }

    func buildPanel() {
        let store = PanelStore()
        store.send = { [weak self] message in self?.sendRequest(message) }
        self.store = store
        let hosting = NSHostingView(rootView: PanelView(store: store))
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.title = "GPT Switch"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = hosting
        panel.minSize = NSSize(width: 680, height: 520)
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
        guard !store.busy else { return true }
        guard store.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃未保存的更改？"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃更改")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        store.channels = store.savedChannels
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
