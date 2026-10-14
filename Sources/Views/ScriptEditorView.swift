import SwiftUI

struct ScriptEditorView: View {

    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Script
    private let isNew: Bool

    init(script: Script, isNew: Bool) {
        _draft = State(initialValue: script)
        self.isNew = isNew
    }

    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $draft.name)
                    TextField("文件名", text: $draft.filename)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    Picker("语言", selection: $draft.language) {
                        Text("JavaScript").tag("js")
                        Text("Python").tag("py")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draft.language) { newValue in
                        let ext = newValue == "py" ? "py" : "js"
                        if let dot = draft.filename.lastIndex(of: ".") {
                            draft.filename = String(draft.filename[..<dot]) + "." + ext
                        } else if !draft.filename.isEmpty {
                            draft.filename += "." + ext
                        }
                    }

                    Picker("运行方式", selection: $draft.runMode) {
                        ForEach(RunMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }

                Section("调度") {
                    if draft.runMode == .task {
                        TextField("cron（分 时 日 月 周）", text: $draft.cron)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text(hintFor(draft.cron))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Stepper("超时：\(draft.timeout) 秒", value: $draft.timeout, in: 10...86400, step: 10)
                    } else {
                        Text("常驻脚本在 App 启动后自动运行，异常退出会按退避策略自动重启。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Toggle("启用", isOn: $draft.enabled)
                }

                Section("备注") {
                    TextField("备注", text: $draft.remark)
                }

                Section {
                    TextEditor(text: $draft.content)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 260)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("脚本内容")
                } footer: {
                    Text(helpText)
                        .font(.caption)
                }
            }
            .navigationTitle(isNew ? "新建脚本" : "编辑脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        store.upsert(draft)
                        if draft.runMode == .daemon && draft.enabled {
                            ScriptRunner.shared.startDaemon(draft)
                        }
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }

    private var helpText: String {
        if draft.isPython {
            return "内置 requests / urllib3 / certifi / idna，可用 os.environ 读取环境变量。"
                + "import daidai_bridge 后调用 daidai_bridge.call('bark','标题','内容') 可推送。"
        }
        return "可用 axios / $.http / $.notify / $.env / require('crypto-js'|'fs'|'path')。"
            + "setTimeout 是同步等待实现，await sleep(1000) 正常可用。"
    }

    private func hintFor(_ cron: String) -> String {
        let e = cron.trimmingCharacters(in: .whitespaces)
        if e.isEmpty { return "留空表示只手动执行" }
        if CronParser(e) == nil { return "格式不正确，需要 5 段，例如 0 8 * * *" }
        return CronParser.describe(e)
    }
}
