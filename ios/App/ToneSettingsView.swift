import SwiftUI

/// 设置 → 语气风格：每个语气的 emoji、名字、是否在键盘上显示、提示词和示例；篇幅（精简 / 扩充 / 梳理）的提示词
struct ToneSettingsView: View {
    @State private var version = 0   // 从编辑页回来刷新列表

    var body: some View {
        List {
            Section("语气") {
                ForEach(Tone.defaultVoiceGrid, id: \.self) { tone in
                    NavigationLink {
                        ToneEditView(target: .tone(tone))
                    } label: {
                        HStack(spacing: 12) {
                            Text(tone.emoji).font(.system(size: 26)).frame(width: 34)
                                .opacity(tone.isHidden ? 0.35 : 1)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(tone.name)
                                    if tone.isHidden {
                                        Text("已隐藏").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Text(tone == .review ? "大众点评代笔" : tone.rule)
                                    .font(.footnote).foregroundColor(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Section("篇幅") {
                ForEach([ToneEditView.Target.tone(.concise), .tone(.expand), .organize], id: \.key) { target in
                    NavigationLink {
                        ToneEditView(target: target)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(target.lengthName)
                            Text(target.currentRule).font(.footnote).foregroundColor(.secondary).lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .id(version)
        .onAppear { ToneCustomization.reload(); version += 1 }
        .navigationTitle("语气风格")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ToneEditView: View {
    enum Target {
        case tone(Tone)
        case organize

        var key: String {
            switch self {
            case .tone(let t): return t.rawValue
            case .organize: return ToneCustomization.organizeKey
            }
        }

        /// 篇幅里的三项：名字固定，只改提示词
        var isLength: Bool {
            switch self {
            case .tone(let t): return t == .concise || t == .expand
            case .organize: return true
            }
        }

        var lengthName: String {
            switch self {
            case .tone(.concise): return ToneLength.concise.name
            case .tone(.expand): return ToneLength.expand.name
            case .organize: return ToneLength.organize.name
            case .tone(let t): return t.name
            }
        }

        var defaultRule: String {
            switch self {
            case .tone(let t): return t.defaultEditableRule
            case .organize: return StyleSelection.organizeRule
            }
        }

        var currentRule: String {
            switch self {
            case .tone(let t): return t == .review ? (t.rule.isEmpty ? StyleSelection.reviewPrompt : t.rule) : t.rule
            case .organize: return ToneCustomization.organizeRule
            }
        }

        /// 发给模型的完整提示词（只读预览）
        var fullPrompt: String {
            switch self {
            case .tone(.concise): return StyleSelection(length: .concise).systemPrompt ?? ""
            case .tone(.expand): return StyleSelection(length: .expand).systemPrompt ?? ""
            case .tone(let t): return StyleSelection(tones: [t]).systemPrompt ?? ""
            case .organize: return "在原来的「整理」提示词末尾追加一条要求：\n\n" + ToneCustomization.organizeRule
            }
        }
    }

    let target: Target
    @State private var override = ToneOverride()
    @State private var rule = ""
    @State private var exampleInput = ""
    @State private var exampleOutput = ""
    @State private var loaded = false

    private var tone: Tone? {
        if case .tone(let t) = target { return t }
        return nil
    }

    private var hasExample: Bool {
        guard let tone else { return false }
        return tone != .review
    }

    var body: some View {
        Form {
            if let tone, !target.isLength {
                Section("键盘上") {
                    HStack {
                        Text("Emoji")
                        Spacer()
                        TextField(tone.defaultEmoji, text: Binding(
                            get: { override.emoji ?? "" },
                            set: { override.emoji = $0.isEmpty ? nil : String($0.suffix(1)) }
                        ))
                        .font(.system(size: 28))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    }
                    HStack {
                        Text("名字")
                        Spacer()
                        TextField(tone.defaultName, text: Binding(
                            get: { override.name ?? "" },
                            set: { override.name = $0.isEmpty ? nil : $0 }
                        ))
                        .multilineTextAlignment(.trailing)
                    }
                    Toggle("在键盘上显示", isOn: Binding(
                        get: { !override.hidden },
                        set: { override.hidden = !$0 }
                    ))
                }
            }

            Section {
                TextEditor(text: $rule)
                    .font(.callout)
                    .frame(minHeight: tone == .review ? 360 : 120)
            } header: {
                Text("提示词")
            } footer: {
                if rule != target.defaultRule {
                    Text("已改过，和默认不同")
                }
            }

            if hasExample {
                Section {
                    TextField("原话", text: $exampleInput, axis: .vertical)
                    TextField("改写后", text: $exampleOutput, axis: .vertical)
                } header: {
                    Text("示例")
                } footer: {
                    Text("模型照着示例的力度改，示例越像你想要的效果越好。")
                }
            }

            Section {
                NavigationLink("查看完整提示词") {
                    ScrollView {
                        Text(currentDraft().fullPrompt)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("完整提示词")
                    .navigationBarTitleDisplayMode(.inline)
                }
                Button("恢复默认", role: .destructive) {
                    override = ToneOverride()
                    loadFields()
                    save()
                }
            }
        }
        .navigationTitle(target.isLength ? target.lengthName : (tone?.name ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            override = ToneCustomization.overrides[target.key] ?? ToneOverride()
            loadFields()
        }
        .onChange(of: override) { _ in save() }
        .onChange(of: rule) { _ in save() }
        .onChange(of: exampleInput) { _ in save() }
        .onChange(of: exampleOutput) { _ in save() }
    }

    private func loadFields() {
        rule = override.rule ?? target.defaultRule
        if let tone, hasExample {
            exampleInput = override.exampleInput ?? tone.defaultExample.input
            exampleOutput = override.exampleOutput ?? tone.defaultExample.output
        }
    }

    /// 和默认一样的字段不存，免得以后默认改了这里还卡在旧值
    private func currentOverride() -> ToneOverride {
        var o = override
        o.rule = rule.trimmingCharacters(in: .whitespacesAndNewlines) == target.defaultRule ? nil : rule
        if let tone, hasExample {
            o.exampleInput = exampleInput == tone.defaultExample.input ? nil : exampleInput
            o.exampleOutput = exampleOutput == tone.defaultExample.output ? nil : exampleOutput
        }
        return o
    }

    private func save() {
        guard loaded else { return }
        ToneCustomization.set(currentOverride(), for: target.key)
    }

    private func currentDraft() -> Target {
        save()
        return target
    }
}
