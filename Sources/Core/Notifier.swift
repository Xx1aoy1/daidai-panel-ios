import Foundation

/// Bark 推送（api.day.app 或自建服务）
enum Notifier {

    @discardableResult
    static func bark(title: String, body: String, force: Bool = false) -> Bool {
        let s = Store.shared.settings
        guard s.barkEnabled || force else { return false }
        var base = s.barkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return false }

        if !base.lowercased().hasPrefix("http") {
            base = "https://api.day.app/" + base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        base = base.hasSuffix("/") ? String(base.dropLast()) : base

        var comps = URLComponents(string: base + "/" + encode(title) + "/" + encode(body))
        var items: [URLQueryItem] = []
        if !s.barkGroup.isEmpty { items.append(URLQueryItem(name: "group", value: s.barkGroup)) }
        if !s.barkSound.isEmpty { items.append(URLQueryItem(name: "sound", value: s.barkSound)) }
        items.append(URLQueryItem(name: "isArchive", value: "1"))
        comps?.queryItems = items

        guard let url = comps?.url else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15

        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { ok = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        return ok
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}
