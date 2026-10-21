import Foundation

/// 本地改动：App Group / 钥匙串共享组不再写死原作者的团队标识。
/// iOS 从 Info.plist 读（TypefreeAppGroup / TypefreeKeychainGroup，主 App 与键盘扩展各写一份）；
/// macOS 不用 App Group 容器，保持原值不变。
public enum SharedContainer {
    public static let defaultAppGroupID = "group.com.voicepolish.shared"

    public static var appGroupID: String {
        #if os(iOS)
        if let id = Bundle.main.object(forInfoDictionaryKey: "TypefreeAppGroup") as? String, !id.isEmpty {
            return id
        }
        #endif
        return defaultAppGroupID
    }

    /// iOS 钥匙串共享组；没配就返回 nil（只在本进程钥匙串里存，键盘扩展不读 Key）。macOS 必须是 nil。
    public static var keychainAccessGroup: String? {
        #if os(iOS)
        if let group = Bundle.main.object(forInfoDictionaryKey: "TypefreeKeychainGroup") as? String,
           !group.isEmpty, !group.hasPrefix("$(") {
            return group
        }
        #endif
        return nil
    }

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// iOS 存配置 / 历史的目录：有 App Group 用 App Group，没有（免费签名不注册 App Group）就用本 App 的 Application Support。
    public static var storageURL: URL {
        if let containerURL { return containerURL }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("Typefree", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
