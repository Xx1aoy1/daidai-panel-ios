import SwiftUI
import UIKit

struct LogsView: View {

    @EnvironmentObject var store: Store
    @State private var selected: LogEntry?

    var body: some View {
        NavigationView {
            List {
                ForEach(store.logs) { log in
                    Button {
                        selected = log
                    } label: {
                        LogRow(log: log)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("日志")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        store.clearLogs()
                    } label: {
                        Text("清空")
                    }
                }
            }
            .sheet(item: $selected) { log in
                LogDetailView(log: log)
            }
            .overlay {
                if store.logs.isEmpty {
                    Text("暂无日志").foregroundColor(.secondary)
                }
            }
        }
    }
}

struct LogDetailView: View {

    let log: LogEntry
    @Environment(\.dismiss) private var dismiss
    @State private var content: String = ""

    var body: some View {
        NavigationView {
            ScrollView {
                Text(content.isEmpty ? "（没有输出）" : content)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle(log.scriptName.isEmpty ? "系统" : log.scriptName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = content
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
            .onAppear {
                content = LogStore.shared.text(of: log.id)
                if content.isEmpty { content = log.output }
            }
        }
    }
}
