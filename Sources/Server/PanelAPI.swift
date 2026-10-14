import Foundation

/// 面板 REST API。所有方法都假定运行在主线程上。
enum PanelAPI {

    static let version = "1.0.0"

    static func handle(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.path

        // 静态资源
        if !path.hasPrefix("/api/") {
            if path == "/health" { return .text("ok") }
            guard let (data, mime) = WebAssets.file(for: path) else {
                return .error("面板前端资源缺失（Resources/web 没有被打进 App）", status: 404)
            }
            return .data(data, contentType: mime)
        }

        // 鉴权
        if !Store.shared.settings.panelToken.isEmpty {
            let token = request.query["token"] ?? request.authorization ?? ""
            guard token == Store.shared.settings.panelToken else {
                return .error("token 无效", status: 401)
            }
        }

        let segments = path.split(separator: "/").map(String.init)
        // ["api", "scripts", "<id>", "run"]
        guard segments.count >= 2 else { return .error("未知接口", status: 404) }
        let resource = segments[1]

        switch resource {
        case "status":   return status()
        case "scripts":  return scripts(request, segments: segments)
        case "env":      return env(request, segments: segments)
        case "tasks":    return tasks(request, segments: segments)
        case "logs":     return logs(request, segments: segments)
        case "settings": return settings(request)
        case "notify":   return testNotify(request)
        case "daemons":  return daemons(request, segments: segments)
        case "import":   return importFromDisk(request)
        default:         return .error("未知接口 \(path)", status: 404)
        }
    }

    // MARK: - 状态

    private static func status() -> HTTPResponse {
        let scripts = Store.shared.scripts
        let running = ScriptRunner.shared.runningCount
        let daemons = ScriptRunner.shared.runningDaemonIds()
        let s = Store.shared.settings

        var payload: [String: Any] = [
            "code": 0,
            "version": version,
            "python": PyRuntime.shared.statusText,
            "pythonReady": PyRuntime.isRuntimeInstalled,
            "scripts": scripts.count,
            "enabled": scripts.filter { $0.enabled }.count,
            "running": running,
            "daemons": daemons.count,
            "daemonIds": daemons,
            "panelEnabled": s.panelEnabled,
            "panelPort": s.panelPort,
            "keepAliveAudio": s.keepAliveAudio,
            "keepAliveLocation": s.keepAliveLocation,
            "barkEnabled": s.barkEnabled
        ]
        if let hb = KeepAliveManager.shared.lastHeartbeat {
            payload["lastHeartbeat"] = ISO8601DateFormatter().string(from: hb)
            payload["heartbeatAge"] = Int(Date().timeIntervalSince(hb))
        }
        if let first = KeepAliveManager.shared.firstLaunch {
            payload["firstLaunchAt"] = ISO8601DateFormatter().string(from: first)
            payload["uptimeHours"] = Int(Date().timeIntervalSince(first) / 3600)
        }
        return .json(payload)
    }

    // MARK: - 脚本

    private static func scripts(_ request: HTTPRequest, segments: [String]) -> HTTPResponse {
        let id = segments.count >= 3 ? segments[2] : ""
        let action = segments.count >= 4 ? segments[3] : ""

        switch request.method {
        case "GET":
            if id.isEmpty {
                let list = Store.shared.scripts.map { scriptJSON($0, withContent: false) }
                return .json(["code": 0, "data": list])
            }
            guard let s = Store.shared.script(id: id) else { return .error("脚本不存在", status: 404) }
            if action == "log" || action == "logs" { return scriptLog(id: id) }
            return .json(["code": 0, "data": scriptJSON(s, withContent: true)])

        case "POST", "PUT":
            if action == "run" {
                guard let s = Store.shared.script(id: id) else { return .error("脚本不存在", status: 404) }
                let started = ScriptRunner.shared.run(s, trigger: "manual")
                return started
                    ? .ok(["message": "已开始执行 \(s.name)"])
                    : .ok(["message": "\(s.name) 正在执行中，已跳过"])
            }
            if action == "toggle" {
                guard let s = Store.shared.script(id: id) else { return .error("脚本不存在", status: 404) }
                let enabled = (request.json["enabled"] as? Bool) ?? !s.enabled
                Store.shared.setEnabled(scriptId: id, enabled: enabled)
                return .ok(["enabled": enabled])
            }
            if action == "daemon" {
                guard let s = Store.shared.script(id: id) else { return .error("脚本不存在", status: 404) }
                let start = (request.json["start"] as? Bool) ?? true
                if start {
                    ScriptRunner.shared.startDaemon(s)
                } else {
                    ScriptRunner.shared.stopDaemon(scriptId: id)
                }
                return .ok(["running": start])
            }

            // 新建或更新
            var script: Script
            if id.isEmpty {
                script = Script.blank(language: (request.json["language"] as? String) ?? "js")
            } else if let existing = Store.shared.script(id: id) {
                script = existing
            } else {
                return .error("脚本不存在", status: 404)
            }

            let j = request.json
            if let v = j["name"] as? String { script.name = v }
            if let v = j["filename"] as? String, !v.isEmpty { script.filename = v }
            if let v = j["content"] as? String { script.content = v }
            if let v = j["cron"] as? String { script.cron = v }
            if let v = j["language"] as? String { script.language = v }
            if let v = j["timeout"] as? Int { script.timeout = max(0, v) }
            if let v = j["remark"] as? String { script.remark = v }
            if let v = j["enabled"] as? Bool { script.enabled = v }
            if let v = j["runMode"] as? String, let m = RunMode(rawValue: v) { script.runMode = m }
            if script.name.isEmpty { script.name = script.filename }

            if script.cron.trimmingCharacters(in: .whitespaces).isEmpty == false,
               CronParser(script.cron) == nil {
                return .error("cron 表达式不合法（需要 5 段，例：0 8 * * *）")
            }

            Store.shared.upsert(script)

            // 改成常驻 / 关掉常驻时同步启停
            if script.runMode == .daemon && script.enabled {
                if !ScriptRunner.shared.isDaemonRunning(scriptId: script.id) {
                    ScriptRunner.shared.startDaemon(script)
                }
            } else if script.runMode != .daemon {
                ScriptRunner.shared.stopDaemon(scriptId: script.id)
            }

            return .ok(["data": scriptJSON(script, withContent: true)])

        case "DELETE":
            guard !id.isEmpty else { return .error("缺少脚本 id") }
            Store.shared.deleteScript(id: id)
            return .ok()

        default:
            return .error("不支持的方法", status: 405)
        }
    }

    private static func scriptLog(id: String) -> HTTPResponse {
        let entry = Store.shared.logs.first { $0.scriptId == id }
        guard let e = entry else { return .json(["code": 0, "data": ""]) }
        return .json(["code": 0, "data": LogStore.shared.text(of: e.id)])
    }

    private static func scriptJSON(_ s: Script, withContent: Bool) -> [String: Any] {
        var d: [String: Any] = [
            "id": s.id,
            "name": s.name,
            "filename": s.filename,
            "language": s.language,
            "enabled": s.enabled,
            "runMode": s.runMode.rawValue,
            "cron": s.cron,
            "timeout": s.timeout,
            "remark": s.remark,
            "running": ScriptRunner.shared.isRunning(scriptId: s.id),
            "daemonRunning": ScriptRunner.shared.isDaemonRunning(scriptId: s.id)
        ]
        if withContent { d["content"] = s.content }
        if let t = s.lastRunAt { d["lastRunAt"] = ISO8601DateFormatter().string(from: t) }
        if let st = s.lastStatus { d["lastStatus"] = st }
        if let dd = s.lastDuration { d["lastDuration"] = dd }
        return d
    }

    // MARK: - 环境变量

    private static func env(_ request: HTTPRequest, segments: [String]) -> HTTPResponse {
        let id = segments.count >= 3 ? segments[2] : ""
        switch request.method {
        case "GET":
            let list = Store.shared.env.map { ["id": $0.id, "key": $0.key, "value": $0.value,
                                               "remark": $0.remark, "enabled": $0.enabled] as [String: Any] }
            return .json(["code": 0, "data": list])

        case "POST":
            var item: EnvVar
            if !id.isEmpty, let existing = Store.shared.env.first(where: { $0.id == id }) {
                item = existing
            } else if let eid = request.json["id"] as? String,
                      let existing = Store.shared.env.first(where: { $0.id == eid }) {
                item = existing
            } else {
                item = EnvVar()
            }
            let j = request.json
            if let v = j["key"] as? String { item.key = v.trimmingCharacters(in: .whitespaces) }
            if let v = j["value"] as? String { item.value = v }
            if let v = j["remark"] as? String { item.remark = v }
            if let v = j["enabled"] as? Bool { item.enabled = v }
            if item.key.isEmpty { return .error("变量名不能为空") }
            Store.shared.upsertEnv(item)
            return .ok()

        case "DELETE":
            guard !id.isEmpty else { return .error("缺少 id") }
            Store.shared.deleteEnv(id: id)
            return .ok()

        default:
            return .error("不支持的方法", status: 405)
        }
    }

    // MARK: - 定时任务

    private static func tasks(_ request: HTTPRequest, segments: [String]) -> HTTPResponse {
        let id = segments.count >= 3 ? segments[2] : ""
        switch request.method {
        case "GET":
            let list = Store.shared.tasks.map { t -> [String: Any] in
                var d: [String: Any] = [
                    "id": t.id, "name": t.name, "kind": t.kind,
                    "scriptId": t.scriptId, "cron": t.cron,
                    "enabled": t.enabled, "payload": t.payload
                ]
                if let s = Store.shared.script(id: t.scriptId) { d["scriptName"] = s.name }
                return d
            }
            return .json(["code": 0, "data": list])

        case "POST":
            var tid = id
            if tid.isEmpty { tid = (request.json["id"] as? String) ?? "" }

            var task: ScheduledTask
            if !tid.isEmpty, let existing = Store.shared.tasks.first(where: { $0.id == tid }) {
                task = existing
            } else {
                task = ScheduledTask()
            }
            let j = request.json
            if let v = j["name"] as? String { task.name = v }
            if let v = j["kind"] as? String { task.kind = v }
            if let v = j["scriptId"] as? String { task.scriptId = v }
            if let v = j["cron"] as? String { task.cron = v }
            if let v = j["payload"] as? String { task.payload = v }
            if let v = j["enabled"] as? Bool { task.enabled = v }
            if task.name.isEmpty { task.name = "任务" }
            if !task.cron.isEmpty && CronParser(task.cron) == nil {
                return .error("cron 表达式不合法（需要 5 段，例：*/30 * * * *）")
            }
            Store.shared.upsertTask(task)
            return .ok(["id": task.id])

        case "DELETE":
            guard !id.isEmpty else { return .error("缺少 id") }
            Store.shared.deleteTask(id: id)
            return .ok()

        default:
            return .error("不支持的方法", status: 405)
        }
    }

    // MARK: - 日志

    private static func logs(_ request: HTTPRequest, segments: [String]) -> HTTPResponse {
        let id = segments.count >= 3 ? segments[2] : ""

        if request.method == "DELETE" {
            if id.isEmpty {
                Store.shared.clearLogs()
                return .ok()
            }
            Store.shared.updateLog(id: id, status: "fail", output: "")
            LogStore.shared.remove(logId: id)
            return .ok()
        }

        if !id.isEmpty {
            return .json(["code": 0, "data": LogStore.shared.text(of: id)])
        }

        let limit = max(1, min(200, Int(request.query["limit"] ?? "50") ?? 50))
        let list = Store.shared.logs.prefix(limit).map { e -> [String: Any] in
            var d: [String: Any] = [
                "id": e.id, "scriptId": e.scriptId, "scriptName": e.scriptName,
                "trigger": e.trigger, "status": e.status,
                "startedAt": ISO8601DateFormatter().string(from: e.startedAt)
            ]
            if let f = e.finishedAt { d["finishedAt"] = ISO8601DateFormatter().string(from: f) }
            if let dd = e.duration { d["duration"] = dd }
            return d
        }
        return .json(["code": 0, "data": list])
    }

    // MARK: - 设置

    private static func settings(_ request: HTTPRequest) -> HTTPResponse {
        if request.method == "GET" {
            let s = Store.shared.settings
            return .json([
                "code": 0,
                "data": [
                    "panelEnabled": s.panelEnabled,
                    "panelPort": s.panelPort,
                    "panelToken": s.panelToken,
                    "allowLAN": s.allowLAN,
                    "barkEnabled": s.barkEnabled,
                    "barkURL": s.barkURL,
                    "barkGroup": s.barkGroup,
                    "barkSound": s.barkSound,
                    "keepAliveAudio": s.keepAliveAudio,
                    "keepAliveLocation": s.keepAliveLocation,
                    "keepAliveBackgroundTask": s.keepAliveBackgroundTask,
                    "autoStart": s.autoStart,
                    "notifyOnlyFailure": s.notifyOnlyFailure,
                    "maxLogs": s.maxLogs,
                    "logKeepDays": s.logKeepDays
                ] as [String: Any]
            ])
        }

        guard request.method == "POST" || request.method == "PUT" else {
            return .error("不支持的方法", status: 405)
        }

        let j = request.json
        var needRestart = false
        var needKeepAliveRefresh = false

        Store.shared.updateSettings { s in
            if let v = j["panelEnabled"] as? Bool { s.panelEnabled = v; needRestart = true }
            if let v = j["panelPort"] as? Int, v > 0, v < 65536 { s.panelPort = v; needRestart = true }
            if let v = j["panelToken"] as? String { s.panelToken = v }
            if let v = j["allowLAN"] as? Bool { s.allowLAN = v; needRestart = true }
            if let v = j["barkEnabled"] as? Bool { s.barkEnabled = v }
            if let v = j["barkURL"] as? String { s.barkURL = v.trimmingCharacters(in: .whitespaces) }
            if let v = j["barkGroup"] as? String { s.barkGroup = v }
            if let v = j["barkSound"] as? String { s.barkSound = v }
            if let v = j["keepAliveAudio"] as? Bool { s.keepAliveAudio = v; needKeepAliveRefresh = true }
            if let v = j["keepAliveLocation"] as? Bool { s.keepAliveLocation = v; needKeepAliveRefresh = true }
            if let v = j["keepAliveBackgroundTask"] as? Bool { s.keepAliveBackgroundTask = v }
            if let v = j["autoStart"] as? Bool { s.autoStart = v }
            if let v = j["notifyOnlyFailure"] as? Bool { s.notifyOnlyFailure = v }
            if let v = j["maxLogs"] as? Int { s.maxLogs = max(20, min(2000, v)) }
            if let v = j["logKeepDays"] as? Int { s.logKeepDays = max(1, v) }
        }

        if needKeepAliveRefresh { KeepAliveManager.shared.refreshState() }
        if needRestart { PanelServer.shared.restart() }

        return .ok(["restart": needRestart])
    }

    // MARK: - 通知

    private static func testNotify(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "POST" else { return .error("不支持的方法", status: 405) }
        let title = (request.json["title"] as? String) ?? "代代面板"
        let body = (request.json["body"] as? String) ?? "这是一条测试推送"
        let ok = Notifier.bark(title: title, body: body, force: true)
        return .json(["code": ok ? 0 : 1, "message": ok ? "推送成功" : "推送失败，请检查 Bark 地址"])
    }

    // MARK: - 守护进程

    private static func daemons(_ request: HTTPRequest, segments: [String]) -> HTTPResponse {
        let action = segments.count >= 3 ? segments[2] : ""
        if action == "stopAll" {
            ScriptRunner.shared.stopAllDaemons()
            return .ok()
        }
        if action == "startAll" {
            Scheduler.shared.startDaemonsIfNeeded()
            return .ok()
        }
        if action == "stop", let id = request.json["id"] as? String {
            ScriptRunner.shared.stopDaemon(scriptId: id)
            return .ok()
        }
        return .json(["code": 0, "data": ScriptRunner.shared.runningDaemonIds()])
    }

    // MARK: - 导入

    private static func importFromDisk(_ request: HTTPRequest) -> HTTPResponse {
        let n = Store.shared.importFromDisk()
        return .ok(["imported": n])
    }
}
