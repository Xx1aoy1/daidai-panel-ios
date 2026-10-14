import Foundation

/// 脚本执行器。
///
/// 每个脚本跑在独立的 Thread 上：
///   * 任务脚本 —— 有超时，跑完即回收
///   * 常驻守护 —— 无超时，跑挂了自动按退避重启
final class ScriptRunner {

    static let shared = ScriptRunner()

    private let lock = NSLock()
    /// 正在执行的脚本 id（含守护）
    private var busy: Set<String> = []
    private var daemonStop: Set<String> = []
    private var daemonThreads: [String: Thread] = [:]
    private var daemonFailures: [String: Int] = [:]

    private init() {}

    // MARK: - 状态查询

    var runningCount: Int {
        lock.lock(); defer { lock.unlock() }
        return busy.count
    }

    func isRunning(scriptId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return busy.contains(scriptId)
    }

    func isDaemonRunning(scriptId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return daemonThreads[scriptId] != nil
    }

    func runningDaemonIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(daemonThreads.keys)
    }

    // MARK: - 一次性执行

    /// 非阻塞执行。completion 在脚本线程上回调。
    @discardableResult
    func run(_ script: Script, trigger: String,
             completion: ((RunResult) -> Void)? = nil) -> Bool {
        lock.lock()
        if busy.contains(script.id) {
            lock.unlock()
            completion?(RunResult(status: "skipped",
                                  output: "上一次执行还没结束，本次触发已跳过",
                                  duration: 0))
            return false
        }
        busy.insert(script.id)
        lock.unlock()

        let thread = Thread { [weak self] in
            guard let self = self else { return }
            let result = self.executeOnce(script: script, trigger: trigger, isDaemon: false)
            self.lock.lock()
            self.busy.remove(script.id)
            self.lock.unlock()
            completion?(result)
        }
        thread.name = "daidai.task.\(script.filename)"
        thread.stackSize = 8 << 20
        thread.qualityOfService = .utility
        thread.start()
        return true
    }

    // MARK: - 常驻守护

    func startDaemon(_ script: Script) {
        lock.lock()
        if daemonThreads[script.id] != nil {
            lock.unlock()
            return
        }
        daemonStop.remove(script.id)
        daemonFailures[script.id] = 0
        let thread = Thread { [weak self] in
            self?.daemonLoop(script)
        }
        daemonThreads[script.id] = thread
        lock.unlock()

        thread.name = "daidai.daemon.\(script.filename)"
        thread.stackSize = 8 << 20
        thread.qualityOfService = .utility
        thread.start()

        Store.shared.addSystemLog("守护进程已启动：\(script.name)")
    }

    func stopDaemon(scriptId: String) {
        lock.lock()
        daemonStop.insert(scriptId)
        lock.unlock()
        Store.shared.addSystemLog("守护进程正在停止：\(scriptId)")
    }

    func stopAllDaemons() {
        lock.lock()
        for id in daemonThreads.keys { daemonStop.insert(id) }
        lock.unlock()
    }

    private func daemonLoop(_ script: Script) {
        while true {
            lock.lock()
            let shouldStop = daemonStop.contains(script.id)
            lock.unlock()
            if shouldStop { break }

            // 每次重启前重新读一遍脚本内容，方便面板改了立即生效
            let current = Store.shared.script(id: script.id) ?? script
            if !current.enabled {
                Store.shared.addSystemLog("脚本已停用，守护退出：\(current.name)")
                break
            }

            let start = Date()
            let result = executeOnce(script: current, trigger: "daemon", isDaemon: true)
            let elapsed = Date().timeIntervalSince(start)

            lock.lock()
            let stopNow = daemonStop.contains(script.id)
            if result.status == "success" {
                daemonFailures[script.id] = 0
            } else {
                daemonFailures[script.id] = (daemonFailures[script.id] ?? 0) + 1
            }
            let failures = daemonFailures[script.id] ?? 0
            lock.unlock()

            if stopNow { break }

            // 退避：5s 起，失败越多等越久，最多 5 分钟
            var delay = 5.0
            if failures > 1 { delay = min(300.0, 5.0 * pow(2.0, Double(min(failures - 1, 6)))) }
            // 如果脚本是「瞬间返回」型的，也别让它变成忙等
            if elapsed < 1.0 { delay = max(delay, 10.0) }

            Store.shared.addSystemLog(String(format: "守护 %@ 第 %d 次退出（%@，%.1fs），%.0fs 后重启",
                                             current.name, failures, result.status, elapsed, delay))

            var remain = delay
            while remain > 0 {
                lock.lock()
                let stop = daemonStop.contains(script.id)
                lock.unlock()
                if stop { break }
                Thread.sleep(forTimeInterval: 0.5)
                remain -= 0.5
            }
        }

        lock.lock()
        daemonThreads[script.id] = nil
        daemonStop.remove(script.id)
        lock.unlock()
        Store.shared.addSystemLog("守护进程已退出：\(script.name)")
    }

    // MARK: - 核心执行

    private func executeOnce(script: Script, trigger: String, isDaemon: Bool) -> RunResult {
        let logId = UUID().uuidString
        let started = Date()

        Store.shared.addLog(LogEntry(id: logId,
                                     scriptId: script.id,
                                     scriptName: script.name,
                                     trigger: trigger,
                                     startedAt: started,
                                     finishedAt: nil,
                                     status: "running",
                                     output: "",
                                     file: "\(logId).log"))
        LogStore.shared.begin(logId: logId)

        let state = FinalizeState()
        let finishLock = NSLock()

        func finish(_ status: String) {
            finishLock.lock()
            let already = state.done
            state.done = true
            finishLock.unlock()
            if already { return }

            let output = LogStore.shared.end(logId)
            let duration = Date().timeIntervalSince(started)

            Store.shared.updateLog(id: logId, status: status, output: String(output.suffix(30000)))
            Store.shared.updateRunState(scriptId: script.id, status: status, duration: duration)
            ScriptRunner.notifyIfNeeded(script: script, status: status, duration: duration, output: output)
        }

        var watchdog: DispatchWorkItem?
        if !isDaemon && script.timeout > 0 {
            let item = DispatchWorkItem {
                LogStore.shared.append(logId, "\n[daidai] 执行超过 \(script.timeout)s，已标记为超时。"
                    + "注意：iOS 上无法强制中断 JS/Python 线程，线程会在自行结束后回收。\n")
                finish("timeout")
            }
            watchdog = item
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .seconds(max(5, script.timeout)), execute: item)
        }

        let env = Store.shared.envDictionary()
        let sink: (String, Bool) -> Void = { text, _ in
            LogStore.shared.append(logId, text)
        }

        var status = "success"

        if script.isPython {
            if PyRuntime.shared.ensureInitialized() {
                let rc = PyRuntime.shared.execute(source: script.content,
                                                  filename: script.filename.isEmpty ? "script.py" : script.filename,
                                                  env: env,
                                                  logSink: sink)
                if rc != 0 { status = "fail" }
            } else {
                let reason = PyRuntime.shared.unavailableReason ?? "Python 运行时不可用"
                LogStore.shared.append(logId, "[daidai] 无法执行 Python 脚本：\(reason)\n")
                status = "fail"
            }
        } else {
            let js = JSRuntime(scriptName: script.filename,
                               env: env,
                               logSink: { text in LogStore.shared.append(logId, text) })
            let ok = js.evaluate(script.content)
            if !ok {
                status = "fail"
            } else if let err = js.doneError, !err.isEmpty {
                _ = err
                status = "fail"
            }

            if ok {
                // 任务脚本：给 setInterval 一点时间自然结束
                let deadline = Date().addingTimeInterval(2)
                while js.hasIntervals && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.2)
                    js.tickIntervals()
                }
            }
            js.shutdown()
        }

        watchdog?.cancel()
        finish(status)

        return RunResult(status: status,
                         output: LogStore.shared.text(of: logId),
                         duration: Date().timeIntervalSince(started))
    }

    // MARK: - 通知

    private static func notifyIfNeeded(script: Script, status: String, duration: Double, output: String) {
        let s = Store.shared.settings
        guard s.barkEnabled else { return }
        if s.notifyOnlyFailure && status == "success" { return }
        // 守护脚本成功退出通常意味着意外结束，值得推送
        let icon = status == "success" ? "✅" : (status == "timeout" ? "⏱" : "❌")
        let tail = output.split(separator: "\n").suffix(3).joined(separator: "\n")
        let body = "[\(statusLabel(status))] \(script.name)\n耗时 \(Int(duration))s\n\(tail)"
        Notifier.bark(title: "\(icon) 代代面板", body: body)
    }

    private static func statusLabel(_ status: String) -> String {
        switch status {
        case "success": return "成功"
        case "fail": return "失败"
        case "timeout": return "超时"
        default: return status
        }
    }
}

/// finish() 可能被工作线程和看门狗线程同时调用，用引用类型做去重标记
private final class FinalizeState {
    var done = false
}
