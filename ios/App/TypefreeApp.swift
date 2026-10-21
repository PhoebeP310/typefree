import SwiftUI
import UIKit
import VoicePolishCore

@main
struct TypefreeApp: App {
    @StateObject private var engine = StandbyEngine.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .onOpenURL { engine.handle(url: $0) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var engine: StandbyEngine
    @State private var duration = StandbyDuration.current
    @State private var mode = StandbyMode.current
    @State private var importMessage: String?
    @State private var configured = StandbyEngine.shared.isConfigured
    @State private var now = Date()
    @State private var copiedID: String?

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            List {
                standbySection
                if !configured { setupKeysSection }
                keyboardSection
                historySection
                settingsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Typefree")
        }
        .navigationViewStyle(.stack)
        .onReceive(clock) { now = $0 }
        .onAppear { importFromPushedFile() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            importFromPushedFile()
        }
    }

    // MARK: - 语音输入状态

    private var standbySection: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.footnote).foregroundColor(.secondary)
                }
                Spacer()
                if engine.phase != .off {
                    Button("关闭") { engine.stopStandby() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)

            Button {
                engine.toggleTestRecording()
            } label: {
                HStack {
                    Image(systemName: engine.phase == .recording ? "stop.circle.fill" : "mic.circle")
                    Text(testButtonTitle)
                    Spacer()
                    if engine.phase == .recording {
                        LevelBar(level: engine.level).frame(width: 80, height: 6)
                    }
                }
            }
            .disabled(!configured || engine.phase == .processing)

            if let error = engine.lastError {
                Text(error).font(.footnote).foregroundColor(.red)
            }
        } footer: {
            Text(mode == .onDemand
                 ? "iOS 不让键盘自己用麦克风，所以由 Typefree 在后台帮键盘录音。这个方式下 Typefree 在后台放一段没有声音的音频保持运行，麦克风只在你说话时打开，橙色标记说完就消失。"
                 : "iOS 不让键盘自己用麦克风，所以由 Typefree 在后台帮键盘录音：开启期间状态栏会有橙色麦克风标记，键盘里点一下就能说。一段时间没用会自动关闭，下次在键盘里点麦克风会再跳过来一次。")
        }
    }

    private var statusColor: Color {
        switch engine.phase {
        case .off: return .gray
        case .idle: return .green
        case .recording: return .red
        case .processing: return .orange
        }
    }

    private var statusTitle: String {
        switch engine.phase {
        case .off: return "语音输入未开启"
        case .idle: return "语音输入已就绪"
        case .recording: return "正在听"
        case .processing: return "整理中"
        }
    }

    private var statusDetail: String {
        switch engine.phase {
        case .off:
            return configured ? "在键盘里点麦克风会自动开启" : "先导入设置或填 Key"
        case .idle:
            guard let expiresAt = engine.expiresAt else { return "" }
            if StandbyDuration.current == .unlimited { return "一直开着，直到手动关闭" }
            let left = max(0, Int(expiresAt.timeIntervalSince(now)))
            return "\(left / 60) 分 \(left % 60) 秒没用会自动关闭"
        case .recording:
            return engine.isKeyboardSession
                ? "点左上角「◀︎」回到刚才的 App 说话，说完在键盘上点停止"
                : "说完点下面的按钮结束"
        case .processing:
            return "完成后文字会自动打到输入框"
        }
    }

    private var testButtonTitle: String {
        switch engine.phase {
        case .recording: return "说完了，点这里结束"
        case .processing: return "整理中…"
        default: return "在这里试说一句"
        }
    }

    // MARK: - Key

    private var setupKeysSection: some View {
        Section {
            Button("从剪贴板导入 Mac 设置") { importFromClipboard() }
            NavigationLink("手动填 Key") {
                KeyEntryView { configured = engine.isConfigured }
            }
            if let importMessage {
                Text(importMessage).font(.footnote).foregroundColor(.secondary)
            }
        } header: {
            Text("识别 / 润色服务")
        } footer: {
            Text("在 Mac 终端运行 ios/scripts/export_mac_config.sh，会把 Key、热词、纠错词、润色规则复制到剪贴板，通过通用剪贴板贴到这里。")
        }
    }

    /// 公司电脑登不了 iCloud 时没有通用剪贴板：install_device.sh --import 用数据线把设置写到 Documents，这里打开 App 时自动导入
    private func importFromPushedFile() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = docs.appendingPathComponent(ConfigImport.pushedFileName)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)   // 文件里有 Key，读完就删
        do {
            let summary = try ConfigImport.importFromJSON(text)
            configured = engine.isConfigured
            importMessage = "已从数据线导入 \(summary.secretCount) 个 Key、\(summary.settingCount) 项设置（热词 \(summary.hotWordCount) 个）"
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string else {
            importMessage = "剪贴板是空的"
            return
        }
        do {
            let summary = try ConfigImport.importFromJSON(text)
            UIPasteboard.general.string = ""   // 剪贴板里有 Key，导入完就清掉
            configured = engine.isConfigured
            importMessage = "已导入 \(summary.secretCount) 个 Key、\(summary.settingCount) 项设置（热词 \(summary.hotWordCount) 个）"
        } catch {
            importMessage = error.localizedDescription
        }
    }

    // MARK: - 键盘

    private var keyboardSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → Typefree")
                Text("2. 点进 Typefree，打开「允许完全访问」")
                Text("3. 打字时长按 🌐 切到 Typefree，点麦克风开始说话")
            }
            .font(.callout)
            Button("打开系统设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("添加键盘")
        } footer: {
            Text("「完全访问」是键盘和 Typefree 互相传录音指令和结果用的，键盘本身不联网、不记录你打的字。")
        }
    }

    // MARK: - 历史

    private var historySection: some View {
        Section("最近") {
            if engine.history.isEmpty {
                Text("还没有记录").foregroundColor(.secondary)
            }
            ForEach(engine.history.prefix(10)) { item in
                Button {
                    UIPasteboard.general.string = item.text
                    copiedID = item.id
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text).foregroundColor(.primary).lineLimit(4)
                        Text(copiedID == item.id ? "已复制" : item.time.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 设置

    private var settingsSection: some View {
        Section("设置") {
            Picker("免跳转方式", selection: $mode) {
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
            Picker("多久没用自动关闭", selection: $duration) {
                ForEach(StandbyDuration.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: duration) { newValue in
                StandbyDuration.current = newValue
                if engine.phase != .off { engine.startStandby() }
            }
            if configured {
                Button("重新从剪贴板导入 Mac 设置") { importFromClipboard() }
                NavigationLink("手动改 Key") {
                    KeyEntryView { configured = engine.isConfigured }
                }
                if let importMessage {
                    Text(importMessage).font(.footnote).foregroundColor(.secondary)
                }
            }
        }
    }
}

struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Color.red).frame(width: geo.size.width * CGFloat(min(max(level, 0.05), 1)))
            }
        }
    }
}

struct KeyEntryView: View {
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var volcanoKey = VoicePolishConfig.shared.string(forKey: "bigasr_api_key") ?? ""
    @State private var deepseekKey = VoicePolishConfig.shared.string(forKey: "deepseek_api_key") ?? ""
    @State private var dashscopeKey = VoicePolishConfig.shared.string(forKey: "dashscope_api_key") ?? ""

    var body: some View {
        Form {
            Section {
                SecureField("火山引擎 API Key", text: $volcanoKey)
            } header: {
                Text("语音识别（火山）")
            } footer: {
                Text("火山引擎 → 豆包语音 → 录音文件识别大模型 的 API Key")
            }
            Section("润色（DeepSeek）") {
                SecureField("DeepSeek API Key", text: $deepseekKey)
            }
            Section {
                SecureField("百炼 API Key（可选）", text: $dashscopeKey)
            } header: {
                Text("阿里百炼")
            } footer: {
                Text("只有识别或润色选了百炼时才需要")
            }
            Button("保存") {
                let config = VoicePolishConfig.shared
                config.saveSecret(volcanoKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "bigasr_api_key")
                config.saveSecret(deepseekKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "deepseek_api_key")
                config.saveSecret(dashscopeKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "dashscope_api_key")
                if !deepseekKey.isEmpty, config.string(forKey: "polish_provider") == nil {
                    config.save(value: "deepseek", forKey: "polish_provider")
                }
                onSave()
                dismiss()
            }
        }
        .navigationTitle("填 Key")
    }
}
