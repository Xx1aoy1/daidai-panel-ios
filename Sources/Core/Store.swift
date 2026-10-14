import Foundation
import Combine

/// 全局数据仓库：脚本、环境变量、定时任务、日志索引、设置。
/// 面板 HTTP 服务与原生 UI 共用同一份实例。
///
/// 线程约定：所有会触发 @Published 变更的写操作都切到主线程执行，
/// 因为脚本线程 / HTTP 服务线程都会调用它们。
final class Store: ObservableObject {

    static let shared = Store()

    @Published var scripts: [Script] = []
    @Published var env: [EnvVar] = []
    @Published var tasks: [ScheduledTask] = []
    @Published var logs: [LogEntry] = []
    @Published var settings: PanelSettings = PanelSettings()

    private let saveQueue = DispatchQueue(label: "com.daidai.store.save", qos: .utility)
    private var dirty = Set<String>()
    private let dirtyLock = NSLock()

    private init() {
        load()
    }

    // MARK: - 主线程调度

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    /// 同步版本：需要立即拿到写入结果时使用（如面板 API）
    private func onMainSync(_ block: () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.sync(execute: block) }
    }

    // MARK: - 载入 / 保存

    func load() {
        scripts = Paths.readJSON([Script].self, from: Paths.scriptsIndex, default: [])
        env = Paths.readJSON([EnvVar].self, from: Paths.envFile, default: [])
        tasks = Paths.readJSON([ScheduledTask].self, from: Paths.tasksFile, default: [])
        logs = Paths.readJSON([LogEntry].self, from: Paths.logsIndex, default: [])
        settings = Paths.readJSON(PanelSettings.self, from: Paths.settingsFile, default: PanelSettings())

        if scripts.isEmpty {
            seedDefaults()
        }
        // 上次被强杀时残留的 running 记录，标记为异常结束
        for i in logs.indices where logs[i].status == "running" {
            logs[i].status = "fail"
            logs[i].finishedAt = Date()
        }
        persistLogs()
        LogStore.shared.purge(keepDays: settings.logKeepDays)
    }

    private func seedDefaults() {
        var s = Script.blank(language: "js")
        s.name = "示例-每日签到"
        s.filename = "demo_checkin.js"
        s.cron = "0 8 * * *"
        scripts = [s]
        saveScripts()
    }

    private func mark(_ key: String) {
        dirtyLock.lock()
        dirty.insert(key)
        dirtyLock.unlock()
        saveQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.flush() }
    }

    /// 落盘。所有 @Published 数据都在主线程读写，这里统一切回主线程再读。
    private func flush() {
        onMainSync { self.flushOnMain() }
    }

    private func flushOnMain() {
        dirtyLock.lock()
        let keys = dirty
        dirty.removeAll()
        dirtyLock.unlock()

        if keys.contains("scripts") {
            Paths.writeJSON(scripts, to: Paths.scriptsIndex)
            syncScriptFiles()
        }
        if keys.contains("env") { Paths.writeJSON(env, to: Paths.envFile) }
        if keys.contains("tasks") { Paths.writeJSON(tasks, to: Paths.tasksFile) }
        if keys.contains("logs") { Paths.writeJSON(logs, to: Paths.logsIndex) }
        if keys.contains("settings") { Paths.writeJSON(settings, to: Paths.settingsFile) }
    }

    func saveScripts() { mark("scripts") }
    func saveEnv() { mark("env") }
    func saveTasks() { mark("tasks") }
    func saveSettings() { mark("settings") }
    func persistLogs() { mark("logs") }

    /// 立即落盘（退出前 / 面板写操作后）
    func saveAllNow() {
        flush()
    }

    /// 把脚本正文同步一份到 Documents/daidai-panel/scripts/ 方便用户导出或拖回
    private func syncScriptFiles() {
        let fm = FileManager.default
        var names = Set<String>()
        for s in scripts {
            guard !s.filename.isEmpty else { continue }
            names.insert(s.filename)
            let url = Paths.scripts.appendingPathComponent(s.filename)
            if (try? String(contentsOf: url, encoding: .utf8)) != s.content {
                try? s.content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        if let files = try? fm.contentsOfDirectory(at: Paths.scripts, includingPropertiesForKeys: nil) {
            for f in files where !names.contains(f.lastPathComponent) {
                try? fm.removeItem(at: f)
            }
        }
    }

    /// 从 Documents/daidai-panel/scripts/ 反向导入用户手工放进去的文件
    @discardableResult
    func importFromDisk() -> Int {
        var added = 0
        guard let files = try? FileManager.default.contentsOfDirectory(at: Paths.scripts,
                                                                       includingPropertiesForKeys: nil) else { return 0 }
        for f in files {
            let ext = f.pathExtension.lowercased()
            guard ext == "js" || ext == "py" else { continue }
            let name = f.lastPathComponent
            if scripts.contains(where: { $0.filename == name }) { continue }
            guard let content = try? String(contentsOf: f, encoding: .utf8) else { continue }
            var s = Script.blank(language: ext)
            s.name = f.deletingPathExtension().lastPathComponent
            s.filename = name
            s.language = ext
            s.content = content
            scripts.append(s)
            added += 1
        }
        if added > 0 { mark("scripts") }
        return added
    }

    // MARK: - 脚本 CRUD

    func script(id: String) -> Script? { scripts.first { $0.id == id } }

    func upsert(_ script: Script) {
        onMain {
            var s = script
            s.updatedAt = Date()
            if s.filename.isEmpty {
                s.filename = "script_\(Int(Date().timeIntervalSince1970)).\(s.isPython ? "py" : "js")"
            }
            if let idx = self.scripts.firstIndex(where: { $0.id == s.id }) {
                self.scripts[idx] = s
            } else {
                self.scripts.append(s)
            }
            self.mark("scripts")
        }
    }

    func deleteScript(id: String) {
        onMain {
            self.scripts.removeAll { $0.id == id }
            self.tasks.removeAll { $0.scriptId == id }
            ScriptRunner.shared.stopDaemon(scriptId: id)
            self.mark("scripts")
            self.mark("tasks")
        }
    }

    func setEnabled(scriptId: String, enabled: Bool) {
        onMain {
            guard let idx = self.scripts.firstIndex(where: { $0.id == scriptId }) else { return }
            self.scripts[idx].enabled = enabled
            self.mark("scripts")
        }
    }

    func updateRunState(scriptId: String, status: String, duration: Double) {
        onMain {
            guard let idx = self.scripts.firstIndex(where: { $0.id == scriptId }) else { return }
            self.scripts[idx].lastRunAt = Date()
            self.scripts[idx].lastStatus = status
            self.scripts[idx].lastDuration = duration
            self.mark("scripts")
        }
    }

    // MARK: - 环境变量

    func upsertEnv(_ item: EnvVar) {
        onMain {
            if let idx = self.env.firstIndex(where: { $0.id == item.id }) {
                self.env[idx] = item
            } else {
                self.env.append(item)
            }
            self.mark("env")
        }
    }

    func deleteEnv(id: String) {
        onMain {
            self.env.removeAll { $0.id == id }
            self.mark("env")
        }
    }

    // MARK: - 定时任务

    func upsertTask(_ task: ScheduledTask) {
        onMain {
            if let idx = self.tasks.firstIndex(where: { $0.id == task.id }) {
                self.tasks[idx] = task
            } else {
                self.tasks.append(task)
            }
            self.mark("tasks")
        }
    }

    func deleteTask(id: String) {
        onMain {
            self.tasks.removeAll { $0.id == id }
            self.mark("tasks")
        }
    }

    // MARK: - 设置

    func updateSettings(_ mutate: @escaping (inout PanelSettings) -> Void) {
        onMain {
            var s = self.settings
            mutate(&s)
            self.settings = s
            self.mark("settings")
        }
    }

    // MARK: - 日志

    func addLog(_ entry: LogEntry) {
        onMain {
            self.logs.insert(entry, at: 0)
            let maxCount = max(20, self.settings.maxLogs)
            if self.logs.count > maxCount {
                let dropped = self.logs.suffix(from: maxCount)
                for d in dropped { LogStore.shared.remove(logId: d.id) }
                self.logs = Array(self.logs.prefix(maxCount))
            }
            self.mark("logs")
        }
    }

    func addSystemLog(_ message: String) {
        let entry = LogEntry(scriptId: "", scriptName: "系统", trigger: "system",
                             startedAt: Date(), finishedAt: Date(),
                             status: "success", output: message, file: "")
        onMain {
            self.logs.insert(entry, at: 0)
            let maxCount = max(20, self.settings.maxLogs)
            if self.logs.count > maxCount { self.logs = Array(self.logs.prefix(maxCount)) }
            self.mark("logs")
        }
    }

    func updateLog(id: String, status: String, output: String) {
        onMain {
            guard let idx = self.logs.firstIndex(where: { $0.id == id }) else { return }
            self.logs[idx].status = status
            self.logs[idx].output = output
            self.logs[idx].finishedAt = Date()
            self.mark("logs")
        }
    }

    func clearLogs() {
        onMain {
            for l in self.logs where !l.id.isEmpty { LogStore.shared.remove(logId: l.id) }
            self.logs.removeAll()
            self.mark("logs")
        }
    }

    // MARK: - 环境变量字典

    func envDictionary() -> [String: String] {
        var dict: [String: String] = [:]
        for e in env where e.enabled && !e.key.isEmpty {
            dict[e.key] = e.value
        }
        return dict
    }
}
