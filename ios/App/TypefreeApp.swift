import AVFoundation
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
    @State private var configured = StandbyEngine.shared.isConfigured
    @State private var importMessage: String?

    var body: some View {
        TabView {
            HomeView(configured: $configured)
                .tabItem { Label("首页", systemImage: "house") }
            HistoryView()
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
            VocabView()
                .tabItem { Label("词库", systemImage: "book.closed") }
            SettingsView(configured: $configured)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(.primary)
        .onAppear {
            importFromPushedFile()
            autoStartStandby()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            importFromPushedFile()
            autoStartStandby()
        }
        .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("好") { importMessage = nil }
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

    /// 打开 App 就顺手把语音输入开起来：iOS 只允许在前台启动麦克风，开着之后键盘里就不用再跳
    private func autoStartStandby() {
        guard configured, engine.phase == .off,
              AVAudioSession.sharedInstance().recordPermission == .granted else { return }
        engine.startStandby()
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
