import Foundation

public enum ProcessingMode: String, CaseIterable {
    case cloudOnly = "cloud_only"
    case omni = "omni"

    public static let userDefaultsKey = "voicepolish.processingMode"
    public static var appGroupSuiteName: String { SharedContainer.appGroupID }

    public var menuTitle: String {
        switch self {
        case .cloudOnly:
            return "全云端：云端识别直出"
        case .omni:
            return "全模态：Qwen Omni 一步直出"
        }
    }

    public var debugName: String {
        switch self {
        case .cloudOnly:
            return "cloud_only"
        case .omni:
            return "omni"
        }
    }

    public var usesCloudTranscription: Bool {
        self == .cloudOnly
    }

    public var usesOmniDirectAudio: Bool {
        self == .omni
    }

    public var transcriptionOverlayMessage: String {
        switch self {
        case .cloudOnly:
            return "云端识别中..."
        case .omni:
            return "全模态处理中..."
        }
    }

    public var polishOverlayMessage: String {
        switch self {
        case .cloudOnly:
            return "结果整理中..."
        case .omni:
            return "整理中..."
        }
    }

    private static let deprecatedLocalOnlyRaw = "local_only"
    private static let deprecatedHybridRaw = "hybrid"

    /// 启动时调用一次：
    /// 1. 把已废弃的 local_only / hybrid 迁移成 cloud_only（standard + group suite 都处理）
    /// 2. 如果 group suite 还没有 mode 而 standard 有有效值（cloud_only/omni），种子复制过去（防止用户阶段 1 选过的 omni 在阶段 2 切 group suite 后被默认值覆盖）
    public static func migrateUserDefaultsIfNeeded() {
        let suites: [UserDefaults] = {
            var list: [UserDefaults] = [.standard]
            if let group = UserDefaults(suiteName: appGroupSuiteName) {
                list.append(group)
            }
            return list
        }()

        for store in suites {
            let raw = store.string(forKey: userDefaultsKey)
            if raw == deprecatedLocalOnlyRaw || raw == deprecatedHybridRaw {
                store.set(ProcessingMode.cloudOnly.rawValue, forKey: userDefaultsKey)
            }
        }

        // standard → group seed（仅当 group 还没值时）
        if let group = UserDefaults(suiteName: appGroupSuiteName) {
            if group.string(forKey: userDefaultsKey) == nil {
                if let standardValue = UserDefaults.standard.string(forKey: userDefaultsKey),
                   ProcessingMode(rawValue: standardValue) != nil {
                    group.set(standardValue, forKey: userDefaultsKey)
                }
            }
        }
    }
}
