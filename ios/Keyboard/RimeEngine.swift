import Foundation

// 头文件按 stdbool 版本编译，带 _stdbool 后缀的名字只在作为 Rime 模块导入时才会被 apinotes 去掉；这里走桥接头，自己起别名
private typealias RimeApi = RimeApi_stdbool
private typealias RimeContext = RimeContext_stdbool
private func rime_get_api() -> UnsafeMutablePointer<RimeApi> { rime_get_api_stdbool() }

/// RIME 输入法引擎的薄封装：小鹤双拼（方案 typefree_flypy，见 Keyboard/RimeData，由 scripts/build_rime_data.sh 生成）。
/// 词库在 Mac 上预编译好随键盘一起装，键盘里不做部署；用户词频写在键盘自己的 Application Support/Rime。
final class RimeEngine {
    static let shared = RimeEngine()

    struct State {
        var preedit = ""
        var candidates: [String] = []
        var isComposing: Bool { !preedit.isEmpty }
    }

    private let api: UnsafeMutablePointer<RimeApi>
    private var session: RimeSessionId = 0
    private var started = false
    /// 传给 RIME 的 C 字符串要一直活着
    private var cStrings: [UnsafeMutablePointer<CChar>] = []

    private init() {
        api = rime_get_api()
    }

    deinit {
        cStrings.forEach { free($0) }
    }

    private func keep(_ s: String) -> UnsafePointer<CChar> {
        let p = strdup(s)!
        cStrings.append(p)
        return UnsafePointer(p)
    }

    /// 第一次用双拼时调用；失败返回 false（键盘会提示）
    @discardableResult
    func start() -> Bool {
        if started { return session != 0 }
        started = true
        guard let shared = Bundle.main.resourceURL?.appendingPathComponent("RimeData"),
              FileManager.default.fileExists(atPath: shared.appendingPathComponent("build/typefree.table.bin").path) else {
            NSLog("[Rime] 缺少 RimeData")
            return false
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rime", isDirectory: true)
        try? FileManager.default.createDirectory(at: support.appendingPathComponent("build"), withIntermediateDirectories: true)

        var traits = RimeTraits()
        traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
        traits.shared_data_dir = keep(shared.path)
        traits.user_data_dir = keep(support.path)
        traits.prebuilt_data_dir = keep(shared.appendingPathComponent("build").path)
        traits.staging_dir = keep(support.appendingPathComponent("build").path)
        traits.distribution_name = keep("Typefree")
        traits.distribution_code_name = keep("typefree")
        traits.distribution_version = keep("1")
        traits.app_name = keep("rime.typefree")
        traits.min_log_level = 2
        traits.log_dir = keep("")

        api.pointee.setup(&traits)
        api.pointee.initialize(&traits)
        session = api.pointee.create_session()
        guard session != 0 else { return false }
        _ = api.pointee.select_schema(session, "typefree_flypy")
        return true
    }

    // MARK: - 输入

    /// 输入一个小写字母或分词符「'」；返回上屏的文字（多半为空）
    func input(_ char: Character) -> String? {
        guard let ascii = char.asciiValue, start() else { return nil }
        _ = api.pointee.process_key(session, Int32(ascii), 0)
        return takeCommit()
    }

    func backspace() {
        guard start() else { return }
        _ = api.pointee.process_key(session, 0xff08, 0)
    }

    /// 选第 index 个候选（全局序号）；返回上屏的文字
    func select(_ index: Int) -> String? {
        guard start() else { return nil }
        _ = api.pointee.select_candidate(session, index)
        return takeCommit()
    }

    /// 没选候选、直接要原始字母（「发送 / 换行」时用）
    func rawInput() -> String {
        guard start(), let p = api.pointee.get_input(session) else { return "" }
        return String(cString: p)
    }

    func clear() {
        guard session != 0 else { return }
        api.pointee.clear_composition(session)
    }

    // MARK: - 状态

    func state(maxCandidates: Int = 40) -> State {
        guard session != 0 else { return State() }
        var result = State()
        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        if api.pointee.get_context(session, &context) {
            if let p = context.composition.preedit { result.preedit = String(cString: p) }
            api.pointee.free_context(&context)
        }
        guard result.isComposing else { return result }
        var iterator = RimeCandidateListIterator()
        if api.pointee.candidate_list_begin(session, &iterator) {
            while result.candidates.count < maxCandidates, api.pointee.candidate_list_next(&iterator) {
                if let p = iterator.candidate.text { result.candidates.append(String(cString: p)) }
            }
            api.pointee.candidate_list_end(&iterator)
        }
        return result
    }

    private func takeCommit() -> String? {
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_commit(session, &commit) else { return nil }
        defer { _ = api.pointee.free_commit(&commit) }
        return commit.text.map { String(cString: $0) }
    }
}
