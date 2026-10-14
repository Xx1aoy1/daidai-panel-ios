import SwiftUI
import UIKit

struct SettingsView: View {

    @EnvironmentObject var store: Store
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var testResult: String?

    var body: some View {
        NavigationView {
            Form {
                panelSection
                barkSection
                keepAliveSection
                envSection
                dataSection
                aboutSection
            }
            .navigationTitle("设置")
        }
    }

    // MARK: - 面板

    private var panelSection: some View {
        Section {
            Toggle("启用本地面板", isOn: setting(\.panelEnabled) {
                PanelServer.shared.restart()
            })
            Stepper("端口：\(store.settings.panelPort)",
                    value: setting(\.panelPort) { PanelServer.shared.restart() },
                    in: 1024...65535, step: 1)
            Toggle("允许局域网访问", isOn: setting(\.allowLAN) {
                PanelServer.shared.restart()
            })
            TextField("访问 token（留空表示不需要）", text: setting(\.panelToken))
                .autocapitalization(.none)
                .disableAutocorrection(true)
        } header: {
            Text("面板")
        } footer: {
            Text("手机浏览器打开 http://127.0.0.1:\(store.settings.panelPort)。"
                 + "开启局域网访问后，同一 Wi-Fi 下的电脑也能管理。当前状态：\(PanelServer.shared.statusText)")
                .font(.caption)
        }
    }

    // MARK: - Bark

    private var barkSection: some View {
        Section {
            Toggle("启用 Bark 推送", isOn: setting(\.barkEnabled))
            TextField("Bark 地址，如 https://api.day.app/你的key", text: setting(\.barkURL))
                .autocapitalization(.none)
                .disableAutocorrection(true)
            TextField("分组", text: setting(\.barkGroup))
            TextField("铃声（可留空）", text: setting(\.barkSound))
            Toggle("仅失败时推送", isOn: setting(\.notifyOnlyFailure))

            Button {
                let ok = Notifier.bark(title: "代代面板", body: "测试推送 \(Date().description(with: .current))", force: true)
                testResult = ok ? "推送成功 ✅" : "推送失败 ❌ 请检查地址"
            } label: {
                Label("发送测试推送", systemImage: "paperplane")
            }

            if let testResult = testResult {
                Text(testResult).font(.caption).foregroundColor(.secondary)
            }
        } header: {
            Text("通知")
        } footer: {
            Text("脚本执行结束后自动推送。JS 里也可用 await $.notify('标题','内容')。")
                .font(.caption)
        }
    }

    // MARK: - 保活

    private var keepAliveSection: some View {
        Section {
            Toggle("音频保活（推荐）", isOn: setting(\.keepAliveAudio) {
                KeepAliveManager.shared.refreshState()
            })
            Toggle("定位保活（更稳，略费电）", isOn: setting(\.keepAliveLocation) {
                KeepAliveManager.shared.refreshState()
            })
            Toggle("后台任务续期", isOn: setting(\.keepAliveBackgroundTask) {
                KeepAliveManager.shared.refreshState()
            })
            Toggle("启动时自动运行常驻脚本", isOn: setting(\.autoStart))
        } header: {
            Text("后台保活")
        } footer: {
            Text("iOS 不允许 App 真正常驻，音频保活是效果最好的方式：循环播放一段静音音频，"
                 + "让系统认为 App 正在放音乐。配合定位保活可以进一步提高存活率。"
                 + "建议把 App 切到后台后不要手动上划杀掉。")
                .font(.caption)
        }
    }

    // MARK: - 环境变量

    private var envSection: some View {
        Section {
            ForEach(store.env) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("变量名", text: Binding(
                            get: { item.key },
                            set: { v in var e = item; e.key = v; store.upsertEnv(e) }
                        ))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.footnote, design: .monospaced))

                        Toggle("", isOn: Binding(
                            get: { item.enabled },
                            set: { v in var e = item; e.enabled = v; store.upsertEnv(e) }
                        ))
                        .labelsHidden()
                    }
                    TextField("值", text: Binding(
                        get: { item.value },
                        set: { v in var e = item; e.value = v; store.upsertEnv(e) }
                    ))
                    .font(.system(.footnote, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                }
                .padding(.vertical, 2)
            }
            .onDelete { indexSet in
                for i in indexSet { store.deleteEnv(id: store.env[i].id) }
            }

            HStack {
                TextField("新变量名", text: $newKey)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("值", text: $newValue)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button {
                    guard !newKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    var item = EnvVar()
                    item.key = newKey.trimmingCharacters(in: .whitespaces)
                    item.value = newValue
                    store.upsertEnv(item)
                    newKey = ""; newValue = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("环境变量")
        } footer: {
            Text("脚本里 JS 用 $.env.KEY / process.env.KEY，Python 用 os.environ['KEY'] 读取。")
                .font(.caption)
        }
    }

    // MARK: - 数据

    private var dataSection: some View {
        Section {
            InfoRow(label: "数据目录", value: "Documents/daidai-panel")
            Stepper("保留日志条数：\(store.settings.maxLogs)",
                    value: setting(\.maxLogs), in: 20...2000, step: 20)
            Stepper("日志保留天数：\(store.settings.logKeepDays)",
                    value: setting(\.logKeepDays), in: 1...60, step: 1)

            Button {
                UIPasteboard.general.string = Paths.scripts.path
                store.addSystemLog("已复制脚本目录路径")
            } label: {
                Label("复制脚本目录路径", systemImage: "doc.on.doc")
            }

            Button(role: .destructive) {
                store.clearLogs()
            } label: {
                Label("清空全部日志", systemImage: "trash")
            }
        } header: {
            Text("数据")
        } footer: {
            Text("在「文件」App → 我的 iPhone → 代代面板 里可以直接拖入 / 导出 js、py 文件。")
                .font(.caption)
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            InfoRow(label: "版本", value: PanelAPI.version)
            InfoRow(label: "Python", value: PyRuntime.shared.statusText)
            InfoRow(label: "JS 引擎", value: "系统 JavaScriptCore")
            if let first = KeepAliveManager.shared.firstLaunch {
                InfoRow(label: "首次启动", value: shortDate(first))
            }
            if let hb = KeepAliveManager.shared.lastHeartbeat {
                InfoRow(label: "最近心跳", value: shortDate(hb))
            }
        } header: {
            Text("关于")
        }
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    // MARK: - 绑定助手

    private func setting<T>(_ keyPath: WritableKeyPath<PanelSettings, T>,
                            sideEffect: (() -> Void)? = nil) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                store.updateSettings { $0[keyPath: keyPath] = newValue }
                sideEffect?()
            }
        )
    }
}
