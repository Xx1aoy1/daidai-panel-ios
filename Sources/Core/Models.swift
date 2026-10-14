import Foundation

// MARK: - 脚本

enum RunMode: String, Codable, CaseIterable {
    /// 定时 / 手动触发，跑完即退出
    case task
    /// 常驻守护：开机即启动，一直运行到被杀
    case daemon

    var label: String {
        switch self {
        case .task: return "定时任务"
        case .daemon: return "常驻守护"
        }
    }
}

struct Script: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var filename: String = ""
    /// "js" / "py"
    var language: String = "js"
    var content: String = ""
    var enabled: Bool = true
    var runMode: RunMode = .task
    /// 标准 5 段 cron，常驻脚本可留空
    var cron: String = ""
    var timeout: Int = 300
    var remark: String = ""

    var lastRunAt: Date?
    var lastStatus: String?
    var lastDuration: Double?

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var isPython: Bool { language.lowercased() == "py" }

    var cronDescription: String {
        cron.trimmingCharacters(in: .whitespaces).isEmpty ? "手动" : cron
    }

    static func blank(language: String = "js") -> Script {
        let ext = language == "py" ? "py" : "js"
        let stamp = Int(Date().timeIntervalSince1970)
        var s = Script()
        s.name = "新脚本-\(stamp)"
        s.filename = "script_\(stamp).\(ext)"
        s.language = ext
        s.content = language == "py" ? Script.pyTemplate : Script.jsTemplate
        return s
    }

    static let jsTemplate = """
    /**
     * daidai-panel JS 脚本
     * 可用：$.http / axios / console.log / $.notify / $.env / require
     * 环境变量在「环境变量」页添加，脚本里用 $.env.KEY 或 process.env.KEY 读取
     */
    (async () => {
      console.log('hello daidai-panel');

      const res = await axios.get('https://httpbin.org/get', { timeout: 10000 });
      console.log('status =', res.status);

      // 发送 Bark 通知
      // await $.notify('任务完成', '脚本执行成功');

      $.done();
    })().catch(e => {
      console.error('脚本异常:', e && e.stack ? e.stack : e);
      $.done(e);
    });
    """

    static let pyTemplate = """
    #!/usr/bin/env python3
    # daidai-panel PY 脚本（内置 requests / urllib3 / certifi / idna / charset_normalizer）
    import os
    import requests


    def main():
        print("hello daidai-panel")
        r = requests.get("https://httpbin.org/get", timeout=10)
        print("status =", r.status_code)


    if __name__ == "__main__":
        main()
    """
}

// MARK: - 环境变量

struct EnvVar: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var key: String = ""
    var value: String = ""
    var remark: String = ""
    var enabled: Bool = true
}

// MARK: - 定时任务视图

struct ScheduledTask: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    /// "shell" = 内置能力：bark 推送 / 心跳；"script" = 执行脚本
    var kind: String = "script"
    var scriptId: String = ""
    var cron: String = ""
    var enabled: Bool = true
    var payload: String = ""
    var lastRunAt: Date?
    var lastStatus: String?

    var cronDescription: String {
        cron.trimmingCharacters(in: .whitespaces).isEmpty ? "手动" : cron
    }
}

// MARK: - 运行日志

struct LogEntry: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var scriptId: String = ""
    var scriptName: String = ""
    var trigger: String = "manual"
    var startedAt: Date = Date()
    var finishedAt: Date?
    var status: String = "running" // running / success / fail / timeout
    var output: String = ""
    /// 每次执行独立文件，避免 json 体积爆炸
    var file: String = ""

    var duration: Double? {
        guard let f = finishedAt else { return nil }
        return f.timeIntervalSince(startedAt)
    }

    var statusLabel: String {
        switch status {
        case "running": return "运行中"
        case "success": return "成功"
        case "fail": return "失败"
        case "timeout": return "超时"
        default: return status
        }
    }
}

// MARK: - 面板设置

struct PanelSettings: Codable, Equatable {
    var panelEnabled: Bool = true
    var panelPort: Int = 5700
    var panelToken: String = ""
    var allowLAN: Bool = false

    var barkEnabled: Bool = false
    /// bark 完整地址，如 https://api.day.app/你的key
    var barkURL: String = ""
    var barkGroup: String = "daidai-panel"
    var barkSound: String = ""

    /// 保活
    var keepAliveAudio: Bool = true
    /// 额外用定位保活（更稳，但会弹权限、略费电）
    var keepAliveLocation: Bool = false
    var keepAliveBackgroundTask: Bool = true
    var autoStart: Bool = true

    /// 通知过滤：只推送失败 / 都推送
    var notifyOnlyFailure: Bool = false

    var maxLogs: Int = 300
    var logKeepDays: Int = 7
}

// MARK: - 运行结果

struct RunResult {
    var status: String
    var output: String
    var duration: Double
}

enum ScriptError: LocalizedError {
    case engineUnavailable(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable(let m): return m
        case .runtime(let m): return m
        }
    }
}
