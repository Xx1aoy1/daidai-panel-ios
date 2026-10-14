import SwiftUI

struct ScriptsView: View {

    @EnvironmentObject var store: Store
    @State private var editing: Script?
    @State private var creating = false
    @State private var search = ""

    var body: some View {
        NavigationView {
            List {
                ForEach(filtered) { script in
                    ScriptCell(script: script) {
                        editing = script
                    } onRun: {
                        ScriptRunner.shared.run(script, trigger: "manual")
                    } onToggle: {
                        store.setEnabled(scriptId: script.id, enabled: !script.enabled)
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet {
                        store.deleteScript(id: filtered[i].id)
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索脚本")
            .navigationTitle("脚本")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        let n = store.importFromDisk()
                        store.addSystemLog(n > 0 ? "从文件目录导入了 \(n) 个脚本" : "文件目录里没有新脚本")
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("新建 JS 脚本") { editing = Script.blank(language: "js"); creating = true }
                        Button("新建 PY 脚本") { editing = Script.blank(language: "py"); creating = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { script in
                ScriptEditorView(script: script, isNew: creating)
                    .environmentObject(store)
            }
        }
    }

    private var filtered: [Script] {
        guard !search.isEmpty else { return store.scripts }
        return store.scripts.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.filename.localizedCaseInsensitiveContains(search)
        }
    }
}

private struct ScriptCell: View {

    let script: Script
    let onEdit: () -> Void
    let onRun: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onRun) {
                Image(systemName: script.isPython ? "chevron.left.forwardslash.chevron.right" : "play.circle.fill")
                    .font(.title2)
                    .foregroundColor(script.enabled ? .accentColor : .gray)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(script.name)
                        .font(.body)
                        .lineLimit(1)
                    if script.runMode == .daemon {
                        Text("常驻")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                    if ScriptRunner.shared.isRunning(scriptId: script.id) {
                        Text("运行中")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.18))
                            .foregroundColor(.green)
                            .clipShape(Capsule())
                    }
                }

                Text("\(script.filename) · \(script.cronDescription)"
                     + (script.lastStatus.map { " · 上次\(statusText($0))" } ?? ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(get: { script.enabled }, set: { _ in onToggle() }))
                .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
    }

    private func statusText(_ s: String) -> String {
        switch s {
        case "success": return "成功"
        case "fail": return "失败"
        case "timeout": return "超时"
        default: return s
        }
    }
}
