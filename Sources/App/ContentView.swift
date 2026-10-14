import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("概览", systemImage: "gauge") }

            ScriptsView()
                .tabItem { Label("脚本", systemImage: "doc.text") }

            LogsView()
                .tabItem { Label("日志", systemImage: "list.bullet.rectangle") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

/// 状态小圆点 + 文本
struct StatusBadge: View {
    let text: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }
}

/// 键值行（LabeledContent 需要 iOS 16，这里自己实现一个）
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
