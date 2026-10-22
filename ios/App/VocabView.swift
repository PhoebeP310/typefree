import SwiftUI
import VoicePolishCore

/// 词库：纠错词（正确写法 + 常被识别成）和按分组折叠的热词；全部 / 自动学到 / 手动添加 三个筛选
struct VocabView: View {
    @State private var store = VocabStore.load()
    @State private var filter: SyncedHotWords.Filter = .all
    @State private var query = ""
    @State private var adding = false

    private var terms: [VocabStore.Term] {
        store.terms.filter { t in
            switch filter {
            case .all: break
            case .autoLearned: if !t.isAuto { return false }
            case .manual: if t.isAuto { return false }
            }
            guard !query.isEmpty else { return true }
            return t.target.localizedCaseInsensitiveContains(query)
                || t.variants.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var groups: [SyncedHotWords.Group] {
        SyncedHotWords.filter(store.groups, by: filter, query: query.isEmpty ? nil : query)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("筛选", selection: $filter) {
                        Text("全部").tag(SyncedHotWords.Filter.all)
                        Text("自动学到").tag(SyncedHotWords.Filter.autoLearned)
                        Text("手动添加").tag(SyncedHotWords.Filter.manual)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if !terms.isEmpty {
                    Section("纠错词 · \(terms.count)") {
                        ForEach(terms) { TermRow(term: $0) }
                            .onDelete { offsets in
                                store.deleteTerms(ids: Set(offsets.map { terms[$0].id }))
                            }
                    }
                }

                if !groups.isEmpty {
                    Section("热词 · \(groups.reduce(0) { $0 + $1.words.count })") {
                        ForEach(groups, id: \.name) { group in
                            NavigationLink {
                                HotWordGroupView(name: group.name, store: $store)
                            } label: {
                                HStack {
                                    Text(group.name)
                                    Spacer()
                                    Text("\(group.words.count)").foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if terms.isEmpty && groups.isEmpty {
                    Text(query.isEmpty ? "还没有词" : "没找到").foregroundColor(.secondary)
                }
            }
            .searchable(text: $query, prompt: "搜索")
            .navigationTitle("词库")
            .overlay(alignment: .bottomTrailing) {
                Button { adding = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(Color(.systemBackground))
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.primary))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                }
                .accessibilityLabel("添加词条")
                .padding(.trailing, 24)
                .padding(.bottom, 20)
            }
            .sheet(isPresented: $adding) {
                AddWordView(categories: store.categories) { term in store.add(term) }
                    .presentationDetents([.medium, .large])
            }
        }
        .onAppear { store = VocabStore.load() }
    }
}

struct TermRow: View {
    let term: VocabStore.Term

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: term.isAuto ? "sparkle" : "pencil")
                .font(.system(size: 15, weight: term.isAuto ? .bold : .regular))
                .foregroundColor(term.isAuto ? Color(red: 0.19, green: 0.77, blue: 0.55) : .secondary)
                .frame(width: 20)
                .accessibilityLabel(term.isAuto ? "自动学到" : "手动添加")
            VStack(alignment: .leading, spacing: 3) {
                Text(term.target)
                if !term.variants.isEmpty {
                    Text(term.variants.joined(separator: " · ")).font(.footnote).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct HotWordGroupView: View {
    let name: String
    @Binding var store: VocabStore

    private var words: [String] { store.groups.first { $0.name == name }?.words ?? [] }

    var body: some View {
        List {
            ForEach(words, id: \.self) { Text($0) }
                .onDelete { offsets in
                    for i in offsets { store.blockHotWord(words[i]) }
                }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 添加词条：正确写法 · 常被识别成（多个）· 分组
struct AddWordView: View {
    let categories: [String]
    let onSave: (VocabStore.Term) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var variants: [String] = []
    @State private var newVariant = ""
    @State private var category = VocabStore.defaultCategory
    @FocusState private var focus: Field?

    private enum Field { case target, variant }

    var body: some View {
        NavigationStack {
            Form {
                Section("正确写法") {
                    TextField("", text: $target)
                        .focused($focus, equals: .target)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("常被识别成") {
                    ForEach(variants, id: \.self) { v in
                        HStack {
                            Text(v)
                            Spacer()
                            Button { variants.removeAll { $0 == v } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("去掉 \(v)")
                        }
                    }
                    HStack {
                        TextField("添加", text: $newVariant)
                            .focused($focus, equals: .variant)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(addVariant)
                        if !newVariant.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("添加", action: addVariant)
                        }
                    }
                }
                Section("分组") {
                    Picker("分组", selection: $category) {
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle("添加词条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        addVariant()
                        onSave(VocabStore.Term(target: target.trimmingCharacters(in: .whitespacesAndNewlines),
                                               variants: variants, category: category, source: ""))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focus = .target }
        }
    }

    private func addVariant() {
        let v = newVariant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, !variants.contains(v) else { newVariant = ""; return }
        variants.append(v)
        newVariant = ""
    }
}

/// 词库的读写：term_corrections + hot_words / hot_words_groups，都在 VoicePolishConfig 里
struct VocabStore {
    struct Term: Identifiable, Equatable {
        var id: String { target.lowercased() }
        var target: String
        var variants: [String]
        var category: String
        var source: String
        var isAuto: Bool { source == "auto" }

        var json: [String: Any] { ["target": target, "variants": variants, "category": category, "source": source] }
    }

    static let defaultCategory = "其他"

    var terms: [Term] = []
    var groups: [SyncedHotWords.Group] = []

    var categories: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in terms.map(\.category) + [Self.defaultCategory] where !c.isEmpty && seen.insert(c).inserted {
            out.append(c)
        }
        return out
    }

    static func load() -> VocabStore {
        let json = VoicePolishConfig.shared.loadConfig()
        var store = VocabStore()
        store.terms = (json["term_corrections"] as? [[String: Any]] ?? []).compactMap { item in
            guard let target = item["target"] as? String, !target.isEmpty else { return nil }
            return Term(target: target,
                        variants: item["variants"] as? [String] ?? [],
                        category: item["category"] as? String ?? defaultCategory,
                        source: item["source"] as? String ?? "")
        }
        let all = SyncedHotWords.groups(hotWords: json[SyncedHotWords.hotWordsKey] as? [String] ?? [],
                                        groupMap: json[SyncedHotWords.groupsKey] as? [String: [String]])
        store.groups = SyncedHotWords.excluding(all, terms: store.terms.map(\.target))
        return store
    }

    private func saveTerms(_ terms: [Term]) {
        VoicePolishConfig.shared.save(values: ["term_corrections": terms.map(\.json)])
    }

    /// 同一个正确写法已存在时合并「常被识别成」
    mutating func add(_ term: Term) {
        guard !term.target.isEmpty else { return }
        var list = Self.load().terms
        if let i = list.firstIndex(where: { $0.id == term.id }) {
            list[i].variants = Array(NSOrderedSet(array: list[i].variants + term.variants)) as? [String] ?? list[i].variants
        } else {
            list.insert(term, at: 0)
        }
        saveTerms(list)
        self = Self.load()
    }

    mutating func deleteTerms(ids: Set<String>) {
        saveTerms(Self.load().terms.filter { !ids.contains($0.id) })
        self = Self.load()
    }

    /// 删一个热词：同时记进屏蔽表，Mac 同步脚本导进来时不会再加回来
    mutating func blockHotWord(_ word: String) {
        let config = VoicePolishConfig.shared
        config.save(values: SyncedHotWords.blockValues(word, config: config.loadConfig()))
        self = Self.load()
    }
}
