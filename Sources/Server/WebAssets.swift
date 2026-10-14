import Foundation

/// 内置面板前端（Resources/web 以 folder reference 打进 bundle）。
enum WebAssets {

    static var root: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("web")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func file(for path: String) -> (Data, String)? {
        guard let root = root else { return nil }
        var relative = path
        if relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = "index.html" }

        // 防目录穿越
        guard !relative.contains("..") else { return nil }

        var url = root.appendingPathComponent(relative)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir {
            url = url.appendingPathComponent("index.html")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // SPA 兜底：未知路径一律回 index.html
            let index = root.appendingPathComponent("index.html")
            guard let data = try? Data(contentsOf: index) else { return nil }
            return (data, "text/html; charset=utf-8")
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (data, mimeType(for: url.pathExtension))
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
