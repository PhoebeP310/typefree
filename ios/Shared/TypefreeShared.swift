import Foundation
import VoicePolishCore

/// 主 App 与键盘扩展共用的常量和跨进程通知。
/// 数据走 AppGroupBridge 的 JSON 文件，通知只负责「去读一下」。
enum TypefreeShared {
    /// 键盘 → 主 App：有新的录音指令（start / stop）
    static let commandNotification = "com.phoebep310.typefree.command"
    /// 主 App → 键盘：录音快照变了（recording / processing / done / error）或待机状态变了
    static let stateNotification = "com.phoebep310.typefree.state"

    static let urlScheme = "typefree"

    /// 待机心跳间隔与判活阈值：主 App 每 heartbeatInterval 秒写一次心跳，键盘看到超过 staleAfter 秒没更新就当它没在待机
    static let heartbeatInterval: TimeInterval = 2
    static let staleAfter: TimeInterval = 6

    /// 各进程自己的设置（待机时长、历史、键盘的待上屏会话），不跨进程共享
    static var defaults: UserDefaults { .standard }

    /// 主 App 能不能直接接录音指令（在待机、心跳新鲜、没过期）
    static func isStandbyAlive(_ status: AppGroupBridge.StandbyStatus?, now: Date = Date()) -> Bool {
        guard let status, status.active else { return false }
        let t = now.timeIntervalSince1970
        return t - status.heartbeat < staleAfter && t < status.expiresAt
    }
}

/// 免跳转方式：后台一直开着麦克风，或者后台放无声音频保活、说话时才开麦（实验）
enum StandbyMode: String, CaseIterable, Identifiable {
    case alwaysOn = "always_on"
    case onDemand = "on_demand"

    static let defaultsKey = "standby_mode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysOn: return "后台常开麦克风"
        case .onDemand: return "说话时才开麦（实验）"
        }
    }

    static var current: StandbyMode {
        get { StandbyMode(rawValue: TypefreeShared.defaults.string(forKey: defaultsKey) ?? "") ?? .onDemand }
        set { TypefreeShared.defaults.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

enum StandbyDuration: Int, CaseIterable, Identifiable {
    case five = 5
    case fifteen = 15
    case sixty = 60
    case unlimited = 0

    /// v2：旧键里存着早期测试选的 5 分钟，默认改成不自动关闭后旧值还在生效，换键让所有人回到默认
    static let defaultsKey = "standby_minutes_v2"

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .five: return "5 分钟"
        case .fifteen: return "15 分钟"
        case .sixty: return "1 小时"
        case .unlimited: return "不自动关闭"
        }
    }

    /// 最后一次使用后保持待机多久；unlimited 用一个很大的值
    var interval: TimeInterval {
        rawValue == 0 ? 60 * 60 * 24 * 365 : TimeInterval(rawValue * 60)
    }

    static var current: StandbyDuration {
        get {
            // 默认不自动关闭：iOS 规定后台起不了麦克风，关了下次就得跳一次 App
            let raw = TypefreeShared.defaults.object(forKey: defaultsKey) as? Int ?? StandbyDuration.unlimited.rawValue
            return StandbyDuration(rawValue: raw) ?? .unlimited
        }
        set { TypefreeShared.defaults.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// Darwin 通知：跨进程、不带数据。回调在主线程派发。
final class DarwinNotifier {
    static let shared = DarwinNotifier()

    private var handlers: [String: () -> Void] = [:]
    private let lock = NSLock()

    func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true
        )
    }

    func observe(_ name: String, handler: @escaping () -> Void) {
        lock.lock()
        let isNew = handlers[name] == nil
        handlers[name] = handler
        lock.unlock()
        guard isNew else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, cfName, _, _ in
                guard let observer, let cfName else { return }
                let notifier = Unmanaged<DarwinNotifier>.fromOpaque(observer).takeUnretainedValue()
                notifier.fire(cfName.rawValue as String)
            },
            name as CFString, nil, .deliverImmediately
        )
    }

    func remove(_ name: String) {
        lock.lock(); handlers[name] = nil; lock.unlock()
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString), nil
        )
    }

    private func fire(_ name: String) {
        lock.lock(); let handler = handlers[name]; lock.unlock()
        DispatchQueue.main.async { handler?() }
    }
}
