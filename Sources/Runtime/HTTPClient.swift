import Foundation

/// 同步 HTTP 客户端。JS 是同步调用进来的，这里用信号量把 URLSession 的异步
/// 回调转成同步返回。共享 URLSession 的 CookieStorage，方便「登录 -> 带着
/// cookie 请求」这类脚本。
enum HTTPClient {

    struct Response {
        var status: Int = 0
        var statusText: String = ""
        var headers: [String: String] = [:]
        var body: String = ""
        var url: String = ""
        var ok: Bool { (200..<300).contains(status) }

        var json: [String: Any] {
            [
                "status": status,
                "statusText": statusText,
                "headers": headers,
                "data": body,
                "url": url,
                "ok": ok
            ]
        }
    }

    static func send(method: String,
                     url: String,
                     headers: [String: String] = [:],
                     body: String? = nil,
                     timeout: TimeInterval = 30,
                     followRedirect: Bool = true) -> Response {

        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return Response(status: 0, statusText: "Bad URL", headers: [:],
                            body: "invalid url: \(url)", url: url)
        }

        var req = URLRequest(url: u)
        req.httpMethod = method.uppercased()
        req.timeoutInterval = max(1, timeout)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body = body, !body.isEmpty {
            req.httpBody = body.data(using: .utf8)
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }
        if !followRedirect {
            // URLSession 没有直接开关，用同步任务时天然跟随；此处保留接口
        }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
                         + "(KHTML, like Gecko) daidai-panel/1.0", forHTTPHeaderField: "User-Agent")
        }

        let sem = DispatchSemaphore(value: 0)
        var result = Response(status: 0, statusText: "No Response", headers: [:],
                              body: "request failed: \(url)", url: url)

        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err {
                result = Response(status: 0, statusText: "Error", headers: [:],
                                  body: "\(err.localizedDescription)", url: url)
                return
            }
            guard let http = resp as? HTTPURLResponse else { return }
            var hs: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                hs["\(k)"] = "\(v)"
            }
            let text = data.flatMap { String(data: $0, encoding: .utf8) }
                ?? data.flatMap { String(data: $0, encoding: .isoLatin1) }
                ?? ""
            result = Response(status: http.statusCode,
                              statusText: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                              headers: hs,
                              body: text,
                              url: http.url?.absoluteString ?? url)
        }
        task.resume()

        if sem.wait(timeout: .now() + req.timeoutInterval + 5) == .timedOut {
            task.cancel()
            return Response(status: 0, statusText: "Timeout", headers: [:],
                            body: "request timeout after \(Int(timeout))s: \(url)", url: url)
        }
        return result
    }

    /// 下载二进制并返回 base64（给 JS 处理图片 / 文件用）
    static func downloadBase64(url: String, timeout: TimeInterval = 60) -> String {
        guard let u = URL(string: url) else { return "" }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var out = ""
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data { out = data.base64EncodedString() }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        return out
    }
}
