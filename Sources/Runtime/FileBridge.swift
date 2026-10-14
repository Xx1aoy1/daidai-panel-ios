import Foundation

/// 给 JS 的 fs shim 提供真实的文件操作。所有路径都被限制在 App 的
/// Documents/daidai-panel 目录内，防止脚本越权读写。
enum FileBridge {

    static func handle(op: String, path rawPath: String, payload: String) -> String {
        guard let url = resolve(rawPath) else { return "" }
        let fm = FileManager.default

        switch op {
        case "read":
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        case "write", "append":
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if op == "write" {
                try? payload.write(to: url, atomically: true, encoding: .utf8)
            } else if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                if let d = payload.data(using: .utf8) { try? handle.write(contentsOf: d) }
            } else {
                try? payload.write(to: url, atomically: true, encoding: .utf8)
            }
            return "1"

        case "exists":
            return fm.fileExists(atPath: url.path) ? "1" : "0"

        case "mkdir":
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return "1"

        case "list":
            let items = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            return (try? json(items)) ?? "[]"

        case "remove":
            try? fm.removeItem(at: url)
            return "1"

        case "stat":
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return "{}" }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let mtime = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            return (try? json(["size": size, "mtime": mtime, "isDir": isDir])) ?? "{}"

        default:
            return ""
        }
    }

    private static func json(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 相对路径一律基于 documents 目录解析，并拒绝逃逸到沙箱外。
    static func resolve(_ path: String) -> URL? {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return nil }

        var url: URL
        if p.hasPrefix("/") {
            if p.hasPrefix(Paths.documents.path) {
                url = URL(fileURLWithPath: p)
            } else {
                // 允许脚本用 /daidai-panel/xxx 这种「伪绝对路径」
                url = Paths.documents.appendingPathComponent(p.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            }
        } else {
            url = Paths.scripts.appendingPathComponent(p)
        }

        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix(Paths.documents.standardizedFileURL.path) else { return nil }
        return standardized
    }
}
