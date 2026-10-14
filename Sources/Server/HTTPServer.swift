import Foundation
import Network

// MARK: - 请求

struct HTTPRequest {
    var method: String = "GET"
    var path: String = "/"
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var body: Data = Data()

    var bodyString: String { String(data: body, encoding: .utf8) ?? "" }

    var json: [String: Any] {
        guard !body.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return obj
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var authorization: String? {
        guard let v = header("authorization") else { return nil }
        if v.lowercased().hasPrefix("bearer ") { return String(v.dropFirst(7)) }
        return v
    }

    var form: [String: String] {
        var out: [String: String] = [:]
        let raw = bodyString
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                let k = kv[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[0]
                let v = kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]
                out[k] = v
            }
        }
        return out
    }
}

// MARK: - 响应

struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        var r = HTTPResponse(status: status, headers: [:], body: data)
        r.headers["Content-Type"] = "application/json; charset=utf-8"
        return r
    }

    static func ok(_ extra: [String: Any] = [:]) -> HTTPResponse {
        var payload: [String: Any] = ["code": 0, "message": "ok"]
        for (k, v) in extra { payload[k] = v }
        return .json(payload)
    }

    static func error(_ message: String, status: Int = 400) -> HTTPResponse {
        .json(["code": status, "message": message], status: status)
    }

    static func text(_ s: String, status: Int = 200) -> HTTPResponse {
        var r = HTTPResponse(status: status, headers: [:], body: Data(s.utf8))
        r.headers["Content-Type"] = "text/plain; charset=utf-8"
        return r
    }

    static func data(_ d: Data, contentType: String, status: Int = 200) -> HTTPResponse {
        var r = HTTPResponse(status: status, headers: [:], body: d)
        r.headers["Content-Type"] = contentType
        return r
    }

    static func redirect(_ location: String) -> HTTPResponse {
        var r = HTTPResponse(status: 302, headers: [:], body: Data())
        r.headers["Location"] = location
        return r
    }

    func serialized() -> Data {
        let reason: String = {
            switch status {
            case 200: return "OK"
            case 201: return "Created"
            case 204: return "No Content"
            case 302: return "Found"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 500: return "Internal Server Error"
            default: return "OK"
            }
        }()

        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var h = headers
        h["Content-Length"] = "\(body.count)"
        h["Connection"] = "close"
        h["Server"] = "daidai-panel"
        if h["Cache-Control"] == nil { h["Cache-Control"] = "no-store" }
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}

// MARK: - 服务

/// 极简 HTTP/1.1 服务：够面板用（短连接、Content-Length 定长）。
final class HTTPServer {

    typealias Handler = (HTTPRequest) -> HTTPResponse

    private let queue = DispatchQueue(label: "com.daidai.http", qos: .userInitiated)
    private var listener: NWListener?
    private let handler: Handler
    private let bindAll: Bool
    private(set) var port: UInt16
    private(set) var isRunning = false
    private var lastError: String?

    init(port: UInt16, bindAll: Bool, handler: @escaping Handler) {
        self.port = port
        self.bindAll = bindAll
        self.handler = handler
    }

    var statusText: String {
        if isRunning { return "运行中，端口 \(port)" }
        return lastError ?? "未启动"
    }

    func start() {
        stop()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "端口不合法：\(port)"
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if !bindAll {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        }

        do {
            let l = try NWListener(using: params, on: nwPort)
            l.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            l.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.lastError = nil
                    NSLog("[daidai] 面板已监听 \(self.bindAll ? "0.0.0.0" : "127.0.0.1"):\(self.port)")
                case .failed(let error):
                    self.isRunning = false
                    self.lastError = "监听失败：\(error.localizedDescription)"
                    NSLog("[daidai] 面板监听失败 %@", error.localizedDescription)
                case .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            lastError = "启动失败：\(error.localizedDescription)"
            NSLog("[daidai] 面板启动失败 %@", error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - 连接处理

    private final class ConnBuffer {
        var data = Data()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveLoop(connection: connection, box: ConnBuffer())
    }

    private func receiveLoop(connection: NWConnection, box: ConnBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { connection.cancel(); return }

            if let data = data, !data.isEmpty {
                box.data.append(data)
            }

            if let error = error {
                NSLog("[daidai] 连接错误 %@", error.localizedDescription)
                connection.cancel()
                return
            }

            // 请求是否已经收全
            if let request = HTTPServer.parse(&box.data) {
                let response = self.handler(request)
                connection.send(content: response.serialized(),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }

            if isComplete || box.data.count > 16 * 1024 * 1024 {
                connection.cancel()
                return
            }

            self.receiveLoop(connection: connection, box: box)
        }
    }

    /// 解析成功则返回请求，并把 buffer 中已消费的部分移除；数据不完整返回 nil。
    static func parse(_ buffer: inout Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else { return nil }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }

        var request = HTTPRequest()
        request.method = parts[0].uppercased()

        let target = parts[1]
        if let qIndex = target.firstIndex(of: "?") {
            request.path = String(target[..<qIndex])
            let queryString = String(target[target.index(after: qIndex)...])
            var q: [String: String] = [:]
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 {
                    let k = kv[0].removingPercentEncoding ?? kv[0]
                    let v = kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]
                    q[k] = v
                } else if kv.count == 1 {
                    q[kv[0]] = ""
                }
            }
            request.query = q
        } else {
            request.path = target
        }
        request.path = request.path.removingPercentEncoding ?? request.path

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        request.headers = headers

        let contentLength = max(0, Int(headers["content-length"] ?? "0") ?? 0)

        let bodyStartOffset = buffer.distance(from: buffer.startIndex, to: headerRange.upperBound)
        guard buffer.count >= bodyStartOffset + contentLength else { return nil }

        let bodyStart = buffer.index(buffer.startIndex, offsetBy: bodyStartOffset)
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        request.body = Data(buffer[bodyStart..<bodyEnd])

        buffer.removeFirst(bodyStartOffset + contentLength)

        return request
    }
}
