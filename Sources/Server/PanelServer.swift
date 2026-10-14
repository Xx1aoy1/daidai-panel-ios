import Foundation

/// 面板服务生命周期管理。
///
/// 手机自己访问：http://127.0.0.1:5700
/// 开了「允许局域网访问」后，同一 Wi-Fi 下的电脑 / 平板也能打开
/// http://<手机IP>:5700 来管理脚本。
final class PanelServer {

    static let shared = PanelServer()

    private var server: HTTPServer?
    private(set) var lastError: String?

    private init() {}

    var isRunning: Bool { server?.isRunning ?? false }

    var port: UInt16 { UInt16(Store.shared.settings.panelPort) }

    var localURL: String { "http://127.0.0.1:\(port)" }

    var statusText: String {
        if let s = server, s.isRunning {
            return Store.shared.settings.allowLAN ? "运行中 · 端口 \(port) · 局域网可访问" : "运行中 · 端口 \(port)"
        }
        return lastError ?? "未启动"
    }

    func start() {
        let s = Store.shared.settings
        guard s.panelEnabled else {
            lastError = "面板已在设置中关闭"
            return
        }

        let port = UInt16(max(1, min(65535, s.panelPort)))
        let handler: HTTPServer.Handler = { request in
            if Thread.isMainThread { return PanelAPI.handle(request) }
            return DispatchQueue.main.sync { PanelAPI.handle(request) }
        }

        let server = HTTPServer(port: port, bindAll: s.allowLAN, handler: handler)
        server.start()
        self.server = server
        lastError = nil
    }

    func stop() {
        server?.stop()
        server = nil
    }

    func restart() {
        stop()
        // 让旧监听先释放端口
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.start()
        }
    }
}
