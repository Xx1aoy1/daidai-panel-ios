import Foundation
import Darwin

/// 每个运行线程自己的日志出口（Python 的 stdout 回调没有上下文，
/// 用 Thread.threadDictionary 定位当前归属）。
final class PyLogSink {
    private let handler: (String, Bool) -> Void
    init(_ handler: @escaping (String, Bool) -> Void) { self.handler = handler }
    func write(_ text: String, _ isErr: Bool) { handler(text, isErr) }
}

/// 嵌入式 CPython 运行时。
///
/// 线程模型：解释器在某个线程上初始化后立刻 PyEval_SaveThread 释放 GIL；
/// 之后每个执行线程用 PyGILState_Ensure/Release 成对获取 GIL。
final class PyRuntime {

    static let shared = PyRuntime()

    private let lock = NSLock()
    private var initialized = false
    private(set) var unavailableReason: String?

    private static let sinkKey = "daidai.py.sink"

    private init() {}

    // MARK: - 运行时定位

    /// 标准库位置：<App>.app/python （由 Scripts/install_python.sh 装进去）
    static var pythonHome: String? {
        let home = Bundle.main.bundlePath + "/python"
        guard FileManager.default.fileExists(atPath: home + "/lib") else { return nil }
        return home
    }

    static var isRuntimeInstalled: Bool { pythonHome != nil }

    // MARK: - C 回调

    private static let writeHook: DaidaiPyWriteHook = { text, isErr in
        guard let text = text else { return }
        let s = String(cString: text)
        if let sink = Thread.current.threadDictionary[PyRuntime.sinkKey] as? PyLogSink {
            sink.write(s, isErr != 0)
        } else {
            NSLog("[daidai-py] %@", s)
        }
    }

    private static let callHook: DaidaiPyCallHook = { op, a, b in
        guard let op = op else { return nil }
        let result = PyRuntime.dispatch(op: String(cString: op),
                                        a: a.map { String(cString: $0) } ?? "",
                                        b: b.map { String(cString: $0) } ?? "")
        return result.isEmpty ? nil : strdup(result)
    }

    /// daidai_bridge.call 支持的操作，给 Python 脚本多一个轻量出口
    private static func dispatch(op: String, a: String, b: String) -> String {
        switch op {
        case "bark":
            let ok = Notifier.bark(title: a.isEmpty ? "daidai-panel" : a, body: b)
            return ok ? "1" : "0"
        case "md5": return CryptoBridge.md5(a)
        case "sha1": return CryptoBridge.sha1(a)
        case "sha256": return CryptoBridge.sha256(a)
        case "hmac256": return CryptoBridge.hmacSHA256(a, key: b)
        case "b64e": return CryptoBridge.base64Encode(a)
        case "b64d": return CryptoBridge.base64Decode(a)
        case "http_get":
            let r = HTTPClient.send(method: "GET", url: a, timeout: 30)
            return r.body
        case "http_post":
            let r = HTTPClient.send(method: "POST", url: a, body: b, timeout: 30)
            return r.body
        default: return ""
        }
    }

    // MARK: - 初始化

    @discardableResult
    func ensureInitialized() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if initialized { return true }

        guard let home = PyRuntime.pythonHome else {
            unavailableReason = "App 内没有 Python 标准库（python/lib 缺失）。"
                + "这通常说明构建阶段 Scripts/install_python.sh 没有执行成功。"
            return false
        }

        setenv("PYTHONHOME", home, 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUTF8", "1", 1)
        setenv("PYTHONNOUSERSITE", "1", 1)
        setenv("PYTHONUNBUFFERED", "1", 1)
        // 让脚本能 import 自己放在 scripts 目录里的模块
        setenv("PYTHONPATH", Paths.scripts.path, 1)

        daidai_py_set_hooks(PyRuntime.writeHook, PyRuntime.callHook)

        if daidai_py_bootstrap() != 0 {
            unavailableReason = "CPython 初始化失败（Py_Initialize 返回错误）。"
            return false
        }

        // 预热一下，把常见模块的错误提前暴露在启动日志里
        daidai_py_acquire_gil()
        _ = daidai_py_exec("import sys, os, json, time, hashlib, base64, urllib.request",
                           "<daidai-preflight>")
        daidai_py_release_gil()

        initialized = true
        return true
    }

    // MARK: - 执行

    /// 执行一段 Python 源码。必须已经通过 ensureInitialized()。
    /// 返回 0 表示成功。
    func execute(source: String, filename: String,
                 env: [String: String],
                 logSink: @escaping (String, Bool) -> Void) -> Int {

        guard ensureInitialized() else { return -1 }

        let sink = PyLogSink(logSink)
        let threadDict = Thread.current.threadDictionary
        threadDict[PyRuntime.sinkKey] = sink
        defer { threadDict.removeObject(forKey: PyRuntime.sinkKey) }

        daidai_py_acquire_gil()
        defer { daidai_py_release_gil() }

        for (k, v) in env {
            daidai_py_set_env(k, v)
        }

        return Int(daidai_py_exec(source, filename))
    }

    /// 供面板展示的运行状态
    var statusText: String {
        if PyRuntime.isRuntimeInstalled {
            return initialized ? "Python 运行时已就绪" : "Python 运行时已安装（未初始化）"
        }
        return unavailableReason ?? "Python 运行时未安装"
    }
}
