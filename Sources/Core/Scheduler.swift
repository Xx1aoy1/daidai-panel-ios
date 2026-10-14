import Foundation

/// 极简调度器：每 20 秒扫描一次，命中的脚本就丢给 ScriptRunner。
/// 用「上一次触发的分钟」去重，避免同一分钟内重复触发。
final class Scheduler {

    static let shared = Scheduler()

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.daidai.scheduler", qos: .utility)
    private var lastFiredMinute: [String: Int] = [:]
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 20, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        Store.shared.addSystemLog("调度器已启动")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        started = false
    }

    /// 开机 / 回到前台时，把所有守护脚本拉起来
    func startDaemonsIfNeeded() {
        guard Store.shared.settings.autoStart else { return }
        for s in Store.shared.scripts where s.enabled && s.runMode == .daemon {
            if !ScriptRunner.shared.isDaemonRunning(scriptId: s.id) {
                ScriptRunner.shared.startDaemon(s)
            }
        }
    }

    func stopAllDaemons() {
        ScriptRunner.shared.stopAllDaemons()
    }

    // MARK: - 心跳

    private func tick() {
        let now = Date()
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let minuteKey = ((comps.day ?? 0) * 24 + (comps.hour ?? 0)) * 60 + (comps.minute ?? 0)

        let scripts = Store.shared.scripts

        // 1. 脚本自带的 cron
        for script in scripts where script.enabled && script.runMode == .task {
            let expr = script.cron.trimmingCharacters(in: .whitespaces)
            guard !expr.isEmpty, let cron = CronParser(expr) else { continue }

            // 当前这一分钟是否应当触发
            guard let prev = calendar.date(byAdding: .minute, value: -1, to: now) else { continue }
            guard let fire = cron.next(after: prev) else { continue }
            let fireComps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let fKey = ((fireComps.day ?? 0) * 24 + (fireComps.hour ?? 0)) * 60 + (fireComps.minute ?? 0)
            guard fKey == minuteKey else { continue }

            let stateKey = "script:\(script.id)"
            if lastFiredMinute[stateKey] == minuteKey { continue }
            lastFiredMinute[stateKey] = minuteKey

            Store.shared.addSystemLog("定时触发：\(script.name)（\(expr)）")
            ScriptRunner.shared.run(script, trigger: "cron")
        }

        // 2. 面板里建的任务
        for task in Store.shared.tasks where task.enabled {
            let expr = task.cron.trimmingCharacters(in: .whitespaces)
            guard !expr.isEmpty, let cron = CronParser(expr) else { continue }
            guard let prev = calendar.date(byAdding: .minute, value: -1, to: now) else { continue }
            guard let fire = cron.next(after: prev) else { continue }
            let fc = calendar.dateComponents([.day, .hour, .minute], from: fire)
            let fKey = ((fc.day ?? 0) * 24 + (fc.hour ?? 0)) * 60 + (fc.minute ?? 0)
            guard fKey == minuteKey else { continue }

            let stateKey = "task:\(task.id)"
            if lastFiredMinute[stateKey] == minuteKey { continue }
            lastFiredMinute[stateKey] = minuteKey

            run(task: task)
        }

        // 3. 隔一段时间清理一下去重表，避免无限增长
        if lastFiredMinute.count > 500 {
            lastFiredMinute = lastFiredMinute.filter { $0.value == minuteKey || $0.value == minuteKey - 1 }
        }
    }

    private func run(task: ScheduledTask) {
        switch task.kind {
        case "bark":
            let parts = task.payload.split(separator: "|", maxSplits: 1).map(String.init)
            let title = parts.first ?? "代代面板"
            let body = parts.count > 1 ? parts[1] : "定时提醒"
            Notifier.bark(title: title, body: body)
            Store.shared.addSystemLog("Bark 推送已发送：\(title)")

        case "script":
            guard let script = Store.shared.script(id: task.scriptId) else {
                Store.shared.addSystemLog("定时任务「\(task.name)」找不到目标脚本")
                return
            }
            ScriptRunner.shared.run(script, trigger: "task")

        default:
            Store.shared.addSystemLog("未知任务类型：\(task.kind)")
        }
    }
}
