import SwiftUI
import UIKit
import VoicePolishCore

/// 设置：后台待机 · 识别和润色 · 键盘 · 数据 · 关于
struct SettingsView: View {
    @EnvironmentObject private var engine: StandbyEngine
    @Binding var configured: Bool
    @State private var mode = StandbyMode.current
    @State private var duration = StandbyDuration.current
    @State private var retention = HistoryRetention.current
    @State private var keysVersion = 0   // 改完 Key 回来刷新「已配置」

    var body: some View {
        NavigationStack {
            List {
                Section("后台待机") {
                    Picker("收音方式", selection: $mode) {
                        ForEach(StandbyMode.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: mode) { newValue in
                        StandbyMode.current = newValue
                        // 换方式要重开一次才生效
                        if engine.phase != .off {
                            engine.stopStandby()
                            engine.startStandby()
                        }
                    }
                    Picker("自动关闭", selection: $duration) {
                        ForEach(StandbyDuration.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: duration) { newValue in
                        StandbyDuration.current = newValue
                        if engine.phase != .off { engine.startStandby() }
                    }
                }

                Section("识别和润色") {
                    NavigationLink {
                        KeyEntryView { configured = engine.isConfigured; keysVersion += 1 }
                    } label: {
                        ValueRow(title: "语音识别", value: "火山引擎", ok: hasKey("bigasr_api_key"))
                    }
                    NavigationLink {
                        KeyEntryView { configured = engine.isConfigured; keysVersion += 1 }
                    } label: {
                        ValueRow(title: "润色", value: polishProviderName, ok: polishConfigured)
                    }
                    NavigationLink {
                        PolishRulesView()
                    } label: {
                        ValueRow(title: "润色规则", value: "\(PolishRulesView.count()) 条", ok: nil)
                    }
                }
                .id(keysVersion)

                Section("键盘") {
                    NavigationLink("语气风格") { ToneSettingsView() }
                    NavigationLink {
                        KeyboardSetupView()
                    } label: {
                        ValueRow(title: "添加键盘与完全访问", value: engine.keyboardConnected ? "已完成" : "未完成", ok: nil)
                    }
                    Button {
                        openSettings()
                    } label: {
                        HStack {
                            Text("从其他 App 粘贴").foregroundColor(.primary)
                            Spacer()
                            Text("去设置").foregroundColor(.secondary)
                            Image(systemName: "arrow.up.forward").font(.footnote).foregroundColor(Color(.tertiaryLabel))
                        }
                    }
                }

                Section("数据") {
                    Picker("保留历史", selection: $retention) {
                        ForEach(HistoryRetention.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: retention) { newValue in
                        HistoryRetention.current = newValue
                        engine.pruneHistory()
                    }
                    NavigationLink("从 Mac 导入设置") {
                        ImportSettingsView(configured: $configured)
                    }
                }

                Section("关于") {
                    ValueRow(title: "版本", value: appVersion, ok: nil)
                    ValueRow(title: "开源许可", value: "GPL-3.0", ok: nil)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
        }
    }

    private func hasKey(_ key: String) -> Bool {
        !(VoicePolishConfig.shared.string(forKey: key) ?? "").isEmpty
    }

    private var polishProvider: String { VoicePolishConfig.shared.string(forKey: "polish_provider") ?? "deepseek" }

    private var polishProviderName: String {
        switch polishProvider {
        case "deepseek": return "DeepSeek"
        case "qwen", "dashscope": return "阿里百炼"
        case "doubao", "ark": return "豆包"
        case "zhipu": return "智谱"
        default: return polishProvider
        }
    }

    private var polishConfigured: Bool {
        switch polishProvider {
        case "qwen", "dashscope": return hasKey("dashscope_api_key")
        case "doubao", "ark": return hasKey("ark_api_key")
        case "zhipu": return hasKey("zhipu_api_key")
        default: return hasKey("deepseek_api_key")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

struct ValueRow: View {
    let title: String
    let value: String
    /// nil = 不显示；true = 绿勾；false = 橙色「未配置」
    let ok: Bool?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            if ok == false {
                Text("未配置").foregroundColor(.orange)
            } else {
                Text(value).foregroundColor(.secondary)
                if ok == true {
                    Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundColor(.green)
                }
            }
        }
    }
}

/// 润色规则：从 Mac 导入的 polish_user_rules，只读
struct PolishRulesView: View {
    private let rules = VoicePolishConfig.shared.loadConfig()["polish_user_rules"] as? [String: Any] ?? [:]

    static func count() -> Int {
        let rules = VoicePolishConfig.shared.loadConfig()["polish_user_rules"] as? [String: Any] ?? [:]
        let apps = (rules["apps"] as? [String: [String]] ?? [:]).values.reduce(0) { $0 + $1.count }
        return (rules["global"] as? [String] ?? []).count + (rules["english"] as? [String] ?? []).count + apps
    }

    var body: some View {
        List {
            section("所有场景", rules["global"] as? [String] ?? [])
            section("英文输出时", rules["english"] as? [String] ?? [])
            ForEach((rules["apps"] as? [String: [String]] ?? [:]).sorted { $0.key < $1.key }, id: \.key) { app, list in
                section(app, list)
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if Self.count() == 0 { Text("还没有规则").foregroundColor(.secondary) } }
        .navigationTitle("润色规则")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [String]) -> some View {
        if !list.isEmpty {
            Section(title) { ForEach(list, id: \.self) { Text($0).font(.callout) } }
        }
    }
}

struct KeyboardSetupView: View {
    @EnvironmentObject private var engine: StandbyEngine

    var body: some View {
        List {
            Section {
                Text("1. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → Typefree")
                Text("2. 点进 Typefree，打开「允许完全访问」")
                Text("3. 打字时长按 🌐 切到 Typefree")
            } footer: {
                Text("「完全访问」用来在键盘和 Typefree 之间传录音指令和结果，键盘不记录你打的字。")
            }
            Section {
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("添加键盘")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 从 Mac 导入：剪贴板（通用剪贴板）或数据线推过来的文件，后者打开 App 时自动导入
struct ImportSettingsView: View {
    @EnvironmentObject private var engine: StandbyEngine
    @Binding var configured: Bool
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button("从剪贴板导入") { importFromClipboard() }
                NavigationLink("手动填 Key") {
                    KeyEntryView { configured = engine.isConfigured }
                }
            } footer: {
                Text("在 Mac 上运行 ios/scripts/export_mac_config.sh 复制设置；没有通用剪贴板时用 install_device.sh --import 通过数据线导入。")
            }
            if let message {
                Section { Text(message).font(.callout) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("从 Mac 导入设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string else {
            message = "剪贴板是空的"
            return
        }
        do {
            let summary = try ConfigImport.importFromJSON(text)
            UIPasteboard.general.string = ""   // 剪贴板里有 Key，导入完就清掉
            configured = engine.isConfigured
            message = "已导入 \(summary.secretCount) 个 Key、\(summary.settingCount) 项设置（热词 \(summary.hotWordCount) 个）"
        } catch {
            message = error.localizedDescription
        }
    }
}
