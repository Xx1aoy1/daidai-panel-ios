import Foundation

/// 所有可写数据的落点。放在 Documents 下，配合 Info.plist 的
/// UIFileSharingEnabled，用户可以直接在「文件」App 里看到并拖拽脚本。
enum Paths {

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var root: URL { ensure(documents.appendingPathComponent("daidai-panel")) }
    static var scripts: URL { ensure(root.appendingPathComponent("scripts")) }
    static var logs: URL { ensure(root.appendingPathComponent("logs")) }
    static var data: URL { ensure(root.appendingPathComponent("data")) }
    static var sitePackages: URL { ensure(root.appendingPathComponent("site-packages")) }

    static var scriptsIndex: URL { data.appendingPathComponent("scripts.json") }
    static var envFile: URL { data.appendingPathComponent("env.json") }
    static var tasksFile: URL { data.appendingPathComponent("tasks.json") }
    static var logsIndex: URL { data.appendingPathComponent("logs.json") }
    static var settingsFile: URL { data.appendingPathComponent("settings.json") }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL, default def: T) -> T {
        guard let data = try? Data(contentsOf: url) else { return def }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(T.self, from: data)) ?? def
    }
}
