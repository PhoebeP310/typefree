import SwiftUI
import UIKit

/// 历史：按天分组，每条 时间 · 正文 · 这次用的写法；右上复制，左滑删除，顶部搜索
struct HistoryView: View {
    @EnvironmentObject private var engine: StandbyEngine
    @State private var query = ""
    @State private var copiedID: String?

    private var sections: [(title: String, items: [StandbyEngine.HistoryItem])] {
        let items = query.isEmpty ? engine.history
            : engine.history.filter { $0.text.localizedCaseInsensitiveContains(query) }
        let calendar = Calendar.current
        var result: [(String, [StandbyEngine.HistoryItem])] = []
        for item in items {
            let title = Self.dayTitle(item.time, calendar: calendar)
            if result.last?.0 == title { result[result.count - 1].1.append(item) } else { result.append((title, [item])) }
        }
        return result.map { (title: $0.0, items: $0.1) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.title) { section in
                    Section {
                        ForEach(section.items) { item in
                            HistoryRow(item: item, copied: copiedID == item.id) { copy(item) }
                        }
                        .onDelete { offsets in
                            engine.deleteHistory(ids: Set(offsets.map { section.items[$0].id }))
                        }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if engine.history.isEmpty {
                    Text("还没有记录").foregroundColor(.secondary)
                }
            }
            .searchable(text: $query, prompt: "搜索")
            .navigationTitle("历史")
        }
    }

    private func copy(_ item: StandbyEngine.HistoryItem) {
        UIPasteboard.general.string = item.text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        copiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == item.id { copiedID = nil }
        }
    }

    static func dayTitle(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日 EEEE" : "yyyy年M月d日"
        return f.string(from: date)
    }
}

struct HistoryRow: View {
    let item: StandbyEngine.HistoryItem
    let copied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.time.formatted(date: .omitted, time: .shortened))
                    .font(.footnote).foregroundColor(.secondary)
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 28, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "已复制" : "复制")
            }
            Text(item.text)
                .font(.system(size: 16))
                .lineSpacing(3)
                .textSelection(.enabled)
            if let style = item.style {
                Text(style).font(.caption).foregroundColor(.secondary).padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }
}
