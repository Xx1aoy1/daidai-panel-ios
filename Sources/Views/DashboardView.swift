import SwiftUI
import UIKit
import Darwin

struct DashboardView: View {

    @EnvironmentObject var store: Store
    @State private var tick = 0
    @State private var toast: String?

    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            List {
                Section("运行状态") {
                    StatusBadge(text: "本地面板：\(PanelServer.shared.statusText)",
                                ok: PanelServer.shared.isRunning)

                    if let hb = KeepAliveManager.shared.lastHeartbeat {
                        let age = Int(Date().timeIntervalSince(hb))
                        StatusBadge(text: "后台心跳：\(age) 秒前", ok: age < 90)
                    } else {
                        StatusBadge(text: "后台心跳：暂无", ok: false)
                    }

                    if let first = KeepAliveManager.shared.firstLaunch {
                        let hours = Date().timeIntervalSince(first) / 3600
                        StatusBadge(text: String(format: "本次安装已连续运行：%.1f 小时", hours), ok: true)
                    }

                    StatusBadge(text: "Python：\(PyRuntime.shared.statusText)",
                                ok: PyRuntime.isRuntimeInstalled)
                }

                Section("脚本") {
                    InfoRow(label: "脚本总数", value: "\(store.scripts.count)")
                    InfoRow(label: "已启用", value: "\(store.scripts.filter { $0.enabled }.count)")
                    InfoRow(label: "正在执行", value: "\(ScriptRunner.shared.runningCount)")
                    InfoRow(label: "常驻守护", value: "\(ScriptRunner.shared.runningDaemonIds().count)")
                }

                Section("守护进程") {
                    HStack(spacing: 12) {
                        Button {
                            Scheduler.shared.startDaemonsIfNeeded()
                            toast = "已尝试启动所有守护脚本"
                        } label: {
                            Label("全部启动", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            ScriptRunner.shared.stopAllDaemons()
                            toast = "已请求停止全部守护"
                        } label: {
                            Label("全部停止", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }

                Section("管理面板") {
                    Button {
                        if let url = URL(string: "http://127.0.0.1:\(store.settings.panelPort)") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("在 Safari 中打开面板", systemImage: "safari")
                    }

                    if store.settings.allowLAN {
                        Button {
                            UIPasteboard.general.string = "http://\(localIP()):\(store.settings.panelPort)"
                            toast = "已复制局域网地址"
                        } label: {
                            Label("复制局域网地址（\(localIP()):\(store.settings.panelPort)）",
                                  systemImage: "doc.on.doc")
                        }
                    }

                    Text("面板地址：http://127.0.0.1:\(store.settings.panelPort)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("最近日志") {
                    if store.logs.isEmpty {
                        Text("暂无记录").foregroundColor(.secondary)
                    }
                    ForEach(store.logs.prefix(5)) { log in
                        LogRow(log: log)
                    }
                }
            }
            .navigationTitle("代代面板")
            .onReceive(timer) { _ in tick += 1 }
            .overlay(alignment: .bottom) {
                if let toast = toast {
                    Text(toast)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .padding(.bottom, 20)
                        .transition(.opacity)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                self.toast = nil
                            }
                        }
                }
            }
        }
    }

    /// 取当前 Wi-Fi 的 IPv4，方便展示局域网面板地址
    private func localIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK

            if isUp && !isLoopback, current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(current.pointee.ifa_addr,
                               socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                    if current.pointee.ifa_name.map({ String(cString: $0) })?.hasPrefix("en") == true {
                        return address
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return address
    }
}

struct LogRow: View {
    let log: LogEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(log.scriptName.isEmpty ? "系统" : log.scriptName)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var icon: String {
        switch log.status {
        case "success": return "checkmark.circle.fill"
        case "fail": return "xmark.circle.fill"
        case "timeout": return "clock.badge.exclamationmark.fill"
        case "running": return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }

    private var color: Color {
        switch log.status {
        case "success": return .green
        case "fail": return .red
        case "timeout": return .orange
        case "running": return .blue
        default: return .gray
        }
    }

    private var subtitle: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        var s = "\(log.statusLabel) · \(f.string(from: log.startedAt))"
        if let d = log.duration { s += String(format: " · %.1fs", d) }
        return s
    }
}
