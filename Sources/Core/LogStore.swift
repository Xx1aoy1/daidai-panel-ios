import Foundation

/// 线程安全的日志缓冲：每次执行写一个独立文件，索引只保存元数据。
final class LogStore {

    static let shared = LogStore()

    /// 日志正文订阅者（面板 WebSocket 不可用，改用轮询；这里给原生 UI 实时刷新用）
    var onAppend: ((String, String) -> Void)?

    private let root: URL
    private let queue = DispatchQueue(label: "com.daidai.log", qos: .utility)

    private var buffers: [String: String] = [:]
    private let lock = NSLock()

    init(root: URL = Paths.logs) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - 实时写入

    func begin(logId: String) {
        lock.lock()
        buffers[logId] = ""
        lock.unlock()
        // 同步创建空文件，避免 append 早于文件创建时把首段内容覆盖掉
        FileManager.default.createFile(atPath: root.appendingPathComponent("\(logId).log").path,
                                       contents: Data())
    }

    func append(_ logId: String, _ text: String) {
        guard !logId.isEmpty, !text.isEmpty else { return }
        lock.lock()
        var cur = buffers[logId] ?? ""
        cur += text
        // 单次执行日志上限 4MB，防止脚本死循环刷爆磁盘
        if cur.utf8.count > 4 * 1024 * 1024 {
            cur = String(cur.suffix(2 * 1024 * 1024))
        }
        buffers[logId] = cur
        lock.unlock()

        onAppend?(logId, text)

        queue.async {
            let url = self.root.appendingPathComponent("\(logId).log")
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                if let data = text.data(using: .utf8) { try? handle.write(contentsOf: data) }
            } else {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    func end(_ logId: String) -> String {
        lock.lock()
        let s = buffers[logId] ?? ""
        buffers[logId] = nil
        lock.unlock()
        return s
    }

    func text(of logId: String) -> String {
        lock.lock()
        if let live = buffers[logId] { lock.unlock(); return live }
        lock.unlock()
        return (try? String(contentsOf: root.appendingPathComponent("\(logId).log"), encoding: .utf8)) ?? ""
    }

    func remove(logId: String) {
        lock.lock(); buffers[logId] = nil; lock.unlock()
        try? FileManager.default.removeItem(at: root.appendingPathComponent("\(logId).log"))
    }

    /// 清理超过保留天数的日志文件
    func purge(keepDays: Int) {
        queue.async {
            let cutoff = Date().addingTimeInterval(-Double(max(1, keepDays)) * 86400)
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: self.root,
                                                          includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            for f in files where f.pathExtension == "log" {
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if date < cutoff { try? fm.removeItem(at: f) }
            }
        }
    }
}
