import Foundation

/// 主 App 的排障日志：Documents/typefree-debug.log，Mac 上用 scripts/pull_log.sh 经数据线拉回来看。
/// 只记状态和报错，不记识别出来的文字。超过 512KB 时砍掉前一半。
enum DebugLog {
    private static let queue = DispatchQueue(label: "typefree.debuglog")
    private static let maxBytes = 512 * 1024
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("typefree-debug.log")
    }

    static func write(_ message: String) {
        NSLog("[Typefree] %@", message)
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let url = fileURL, let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                let size = handle.offsetInFile
                try? handle.close()
                if size > maxBytes, let all = try? Data(contentsOf: url) {
                    try? all.suffix(maxBytes / 2).write(to: url)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
