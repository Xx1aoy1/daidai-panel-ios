import Foundation
import JavaScriptCore

/// 单次 JS 脚本的运行环境。
/// 每个脚本线程一个 JSContext，绝不跨线程使用。
final class JSRuntime {

    let context: JSContext
    private let env: [String: String]
    private let logSink: (String) -> Void
    private let scriptName: String

    /// 脚本内 setInterval 注册表（由运行线程自行驱动，避免跨线程访问 JSContext）
    private var intervalIds: Set<String> = []
    /// $.done(err) 之后记录的错误
    private(set) var doneError: String?
    private(set) var exitCode: Int = 0

    init(scriptName: String,
         env: [String: String],
         logSink: @escaping (String) -> Void) {
        self.scriptName = scriptName
        self.env = env
        self.logSink = logSink
        self.context = JSContext(virtualMachine: JSVirtualMachine())!
        installBridges()
        context.exceptionHandler = { [weak self] _, exception in
            guard let self = self, let e = exception else { return }
            let msg = e.toString() ?? "unknown JS error"
            self.logSink("[JS 异常] \(msg)\n")
        }
    }

    // MARK: - 原生桥

    private func installBridges() {
        let ctx = context

        let logBlock: @convention(block) (String, String) -> Void = { [weak self] level, text in
            guard let self = self else { return }
            self.logSink(text)
            _ = level
        }
        ctx.setObject(logBlock, forKeyedSubscript: "__dd_log" as NSString)

        let reqBlock: @convention(block) (String) -> String = { json in
            guard let data = json.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return "{\"status\":0,\"data\":\"bad request payload\",\"headers\":{}}"
            }
            let method = (obj["method"] as? String) ?? "GET"
            let url = (obj["url"] as? String) ?? ""
            let headers = (obj["headers"] as? [String: String]) ?? [:]
            var body: String?
            if let b = obj["body"] as? String {
                body = b
            } else if let d = obj["data"], !(d is NSNull) {
                if let s = d as? String {
                    body = s
                } else if let enc = obj["dataEncoding"] as? String, enc == "base64" {
                    body = (d as? String)
                } else if JSONSerialization.isValidJSONObject(d),
                          let raw = try? JSONSerialization.data(withJSONObject: d),
                          let s = String(data: raw, encoding: .utf8) {
                    body = s
                }
            }
            let timeout = (obj["timeout"] as? Double).map { $0 / 1000.0 } ?? 30
            let resp = HTTPClient.send(method: method, url: url, headers: headers,
                                       body: body, timeout: timeout)
            if let raw = try? JSONSerialization.data(withJSONObject: resp.json),
               let s = String(data: raw, encoding: .utf8) {
                return s
            }
            return "{\"status\":0,\"data\":\"serialize error\",\"headers\":{}}"
        }
        ctx.setObject(reqBlock, forKeyedSubscript: "__dd_request" as NSString)

        let envBlock: @convention(block) () -> String = { [weak self] in
            guard let self = self,
                  let raw = try? JSONSerialization.data(withJSONObject: self.env),
                  let s = String(data: raw, encoding: .utf8) else { return "{}" }
            return s
        }
        ctx.setObject(envBlock, forKeyedSubscript: "__dd_env" as NSString)

        let sleepBlock: @convention(block) (Double) -> Void = { ms in
            let seconds = max(0, ms) / 1000.0
            // 分段睡眠，避免长时间完全不可中断
            var remain = seconds
            while remain > 0 {
                let slice = min(remain, 0.25)
                Thread.sleep(forTimeInterval: slice)
                remain -= slice
            }
        }
        ctx.setObject(sleepBlock, forKeyedSubscript: "__dd_sleep" as NSString)

        let notifyBlock: @convention(block) (String, String) -> Bool = { title, body in
            Notifier.bark(title: title, body: body)
        }
        ctx.setObject(notifyBlock, forKeyedSubscript: "__dd_notify" as NSString)

        let cryptoBlock: @convention(block) (String, String, String) -> String = { op, a, b in
            switch op {
            case "md5": return CryptoBridge.md5(a)
            case "md5upper": return CryptoBridge.md5(a, upper: true)
            case "sha1": return CryptoBridge.sha1(a)
            case "sha256": return CryptoBridge.sha256(a)
            case "hmac256": return CryptoBridge.hmacSHA256(a, key: b)
            case "b64e": return CryptoBridge.base64Encode(a)
            case "b64d": return CryptoBridge.base64Decode(a)
            default: return ""
            }
        }
        ctx.setObject(cryptoBlock, forKeyedSubscript: "__dd_crypto" as NSString)

        let nowBlock: @convention(block) () -> Double = { Date().timeIntervalSince1970 * 1000 }
        ctx.setObject(nowBlock, forKeyedSubscript: "__dd_now" as NSString)

        let fsBlock: @convention(block) (String, String, String) -> String = { op, path, payload in
            FileBridge.handle(op: op, path: path, payload: payload)
        }
        ctx.setObject(fsBlock, forKeyedSubscript: "__dd_fs" as NSString)

        let dlBlock: @convention(block) (String) -> String = { url in
            HTTPClient.downloadBase64(url: url)
        }
        ctx.setObject(dlBlock, forKeyedSubscript: "__dd_download_b64" as NSString)

        // 关闭 window / document，避免脚本误判为浏览器环境
        ctx.evaluateScript("var window = undefined; var document = undefined; var navigator = undefined;")
    }

    // MARK: - 执行

    /// 执行脚本正文。返回是否正常结束（false 表示抛错）。
    @discardableResult
    func evaluate(_ source: String) -> Bool {
        context.setObject(scriptName, forKeyedSubscript: "__dd_script_name" as NSString)
        context.evaluateScript(JSRuntime.bootstrap)
        if let ex = context.exception {
            logSink("[bootstrap 失败] \(ex.toString() ?? "")\n")
            return false
        }

        // setInterval 被调用时会写入 __dd_intervals
        context.evaluateScript("globalThis.__dd_intervals = {};")
        let result = context.evaluateScript(source)
        if let ex = context.exception {
            let line = ex.objectForKeyedSubscript("line")?.toInt32() ?? 0
            let msg = ex.toString() ?? "unknown"
            logSink("[执行失败] 第 \(line) 行: \(msg)\n")
            if let stack = ex.objectForKeyedSubscript("stack")?.toString() {
                logSink("\(stack)\n")
            }
            return false
        }
        _ = result

        // 收集 setInterval 注册的 id
        if let keys = context.evaluateScript("Object.keys(globalThis.__dd_intervals || {})")?.toArray() as? [String] {
            intervalIds = Set(keys)
        }
        if let d = context.evaluateScript("globalThis.__dd_done_error")?.toString(), !d.isEmpty, d != "null" {
            doneError = d
        }
        if let c = context.evaluateScript("globalThis.__dd_exit_code")?.toInt32() {
            exitCode = Int(c)
        }
        return true
    }

    var hasIntervals: Bool { !intervalIds.isEmpty }

    /// 由运行线程调用，驱动一次 setInterval 回调（同线程，安全）
    func tickIntervals() {
        guard !intervalIds.isEmpty else { return }
        _ = context.evaluateScript("globalThis.__dd_tick_all && globalThis.__dd_tick_all();")
        if let ex = context.exception {
            logSink("[setInterval 异常] \(ex.toString() ?? "")\n")
        }
        // 回调里可能 clearInterval
        if let keys = context.evaluateScript("Object.keys(globalThis.__dd_intervals || {})")?.toArray() as? [String] {
            intervalIds = Set(keys)
        }
    }

    func shutdown() {
        intervalIds.removeAll()
    }

    // MARK: - 注入的 JS 运行库

    static let bootstrap = #"""
    (function () {
      'use strict';
      var g = globalThis;

      // ============ console ============
      function fmt(v, depth) {
        depth = depth || 0;
        if (v === null) return 'null';
        if (v === undefined) return 'undefined';
        var t = typeof v;
        if (t === 'string') return depth === 0 ? v : JSON.stringify(v);
        if (t === 'number' || t === 'boolean' || t === 'bigint') return String(v);
        if (t === 'function') return '[Function ' + (v.name || 'anonymous') + ']';
        if (v instanceof Error) return (v.stack || (v.name + ': ' + v.message));
        if (depth > 3) return '[Object]';
        if (Array.isArray(v)) {
          var arr = [];
          for (var i = 0; i < v.length && i < 50; i++) arr.push(fmt(v[i], depth + 1));
          return '[' + arr.join(', ') + ']';
        }
        try {
          var keys = Object.keys(v);
          var pairs = [];
          for (var k = 0; k < keys.length && k < 50; k++) {
            var key = keys[k];
            var val;
            try { val = fmt(v[key], depth + 1); } catch (e) { val = '[Getter]'; }
            pairs.push(key + ': ' + val);
          }
          return '{ ' + pairs.join(', ') + ' }';
        } catch (e) {
          return String(v);
        }
      }
      function stamp() {
        var d = new Date();
        function p(n, w) { n = String(n); while (n.length < w) n = '0' + n; return n; }
        return p(d.getHours(), 2) + ':' + p(d.getMinutes(), 2) + ':' + p(d.getSeconds(), 2);
      }
      var console = {};
      var timers = {};
      ['log', 'info', 'debug'].forEach(function (k) {
        console[k] = function () {
          var a = [];
          for (var i = 0; i < arguments.length; i++) a.push(fmt(arguments[i], 0));
          __dd_log('info', '[' + stamp() + '] ' + a.join(' ') + '\n');
        };
      });
      console.warn = function () {
        var a = []; for (var i = 0; i < arguments.length; i++) a.push(fmt(arguments[i], 0));
        __dd_log('warn', '[' + stamp() + '][WARN] ' + a.join(' ') + '\n');
      };
      console.error = function () {
        var a = []; for (var i = 0; i < arguments.length; i++) a.push(fmt(arguments[i], 0));
        __dd_log('error', '[' + stamp() + '][ERROR] ' + a.join(' ') + '\n');
      };
      console.trace = console.error;
      console.time = function (label) { timers[label] = Date.now(); };
      console.timeEnd = function (label) {
        if (timers[label] === undefined) return;
        console.log(label + ': ' + (Date.now() - timers[label]) + 'ms');
        delete timers[label];
      };
      console.assert = function (cond) {
        if (!cond) console.error.apply(null, Array.prototype.slice.call(arguments, 1));
      };
      g.console = console;

      // ============ 定时器 ============
      // 说明：daidai-panel 的 JS 引擎是同步的，setTimeout 用「等待后立即执行」实现，
      // 因此 await new Promise(r => setTimeout(r, 1000)) 这类写法完全可用。
      g.setTimeout = function (fn, ms) {
        var args = Array.prototype.slice.call(arguments, 2);
        var delay = Math.max(0, ms || 0);
        if (typeof fn === 'function') {
          if (delay > 0) __dd_sleep(delay);
          fn.apply(null, args);
        }
        return 0;
      };
      g.clearTimeout = function () {};
      g.setInterval = function (fn, ms) {
        var id = 'iv_' + (g.__dd_iv_seq = (g.__dd_iv_seq || 0) + 1);
        var delay = Math.max(50, ms || 1000);
        var args = Array.prototype.slice.call(arguments, 2);
        g.__dd_intervals = g.__dd_intervals || {};
        g.__dd_intervals[id] = { fn: fn, ms: delay, args: args, next: Date.now() + delay };
        return id;
      };
      g.clearInterval = function (id) { if (g.__dd_intervals) delete g.__dd_intervals[id]; };
      g.setImmediate = function (fn) { return g.setTimeout(fn, 0); };
      g.queueMicrotask = function (fn) { fn(); };

      g.__dd_tick_all = function () {
        var now = Date.now();
        var list = g.__dd_intervals || {};
        for (var id in list) {
          if (!Object.prototype.hasOwnProperty.call(list, id)) continue;
          var it = list[id];
          if (now >= it.next) {
            it.next = now + it.ms;
            try { it.fn.apply(null, it.args || []); }
            catch (e) { console.error('setInterval 回调异常: ' + (e && e.stack ? e.stack : e)); }
          }
        }
      };

      g.sleep = function (ms) { return new Promise(function (r) { g.setTimeout(r, ms); }); };

      // ============ 编码工具 ============
      g.atob = function (s) { return __dd_crypto('b64d', s, ''); };
      g.btoa = function (s) { return __dd_crypto('b64e', s, ''); };

      function TextEncoder() {}
      TextEncoder.prototype.encode = function (str) {
        var b64 = __dd_crypto('b64e', str, '');
        var bin = __dd_crypto('b64d', b64, '');
        var out = [];
        for (var i = 0; i < str.length; i++) {
          var c = str.charCodeAt(i);
          if (c < 0x80) out.push(c);
          else if (c < 0x800) { out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
          else { out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
        }
        return new Uint8Array(out);
      };
      TextEncoder.prototype.encodeInto = function (str, dest) {
        var e = this.encode(str);
        for (var i = 0; i < e.length && i < dest.length; i++) dest[i] = e[i];
        return { read: str.length, written: Math.min(e.length, dest.length) };
      };
      function TextDecoder() {}
      TextDecoder.prototype.decode = function (buf) {
        if (!buf) return '';
        var bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf.buffer || buf);
        var str = '';
        for (var i = 0; i < bytes.length; i++) str += String.fromCharCode(bytes[i]);
        return decodeURIComponent(escape(str));
      };
      g.TextEncoder = TextEncoder;
      g.TextDecoder = TextDecoder;

      var Buffer = {
        from: function (input, enc) {
          if (typeof input === 'string') {
            if (enc === 'base64') return { toString: function (e) { return e === 'base64' ? input : __dd_crypto('b64d', input, ''); }, length: input.length };
            return { toString: function (e) { return e === 'base64' ? __dd_crypto('b64e', input, '') : input; }, length: input.length };
          }
          return { toString: function () { return ''; }, length: 0 };
        },
        isBuffer: function () { return false; },
        alloc: function (n) { return { length: n, toString: function () { return ''; } }; }
      };
      g.Buffer = Buffer;

      // ============ URL / URLSearchParams ============
      function URLSearchParams(init) {
        this._data = [];
        if (typeof init === 'string') {
          var q = init.charAt(0) === '?' ? init.slice(1) : init;
          if (q) {
            q.split('&').forEach(function (kv) {
              if (!kv) return;
              var i = kv.indexOf('=');
              var k = i < 0 ? kv : kv.slice(0, i);
              var v = i < 0 ? '' : kv.slice(i + 1);
              this._data.push([decodeURIComponent(k), decodeURIComponent(v.replace(/\+/g, ' '))]);
            }, this);
          }
        } else if (init && typeof init === 'object') {
          var self = this;
          Object.keys(init).forEach(function (k) { self._data.push([k, String(init[k])]); });
        }
      }
      URLSearchParams.prototype.append = function (k, v) { this._data.push([k, v]); };
      URLSearchParams.prototype.set = function (k, v) {
        this.delete(k); this._data.push([k, v]);
      };
      URLSearchParams.prototype.get = function (k) {
        for (var i = 0; i < this._data.length; i++) if (this._data[i][0] === k) return this._data[i][1];
        return null;
      };
      URLSearchParams.prototype.getAll = function (k) {
        var out = [];
        for (var i = 0; i < this._data.length; i++) if (this._data[i][0] === k) out.push(this._data[i][1]);
        return out;
      };
      URLSearchParams.prototype.has = function (k) { return this.get(k) !== null; };
      URLSearchParams.prototype['delete'] = function (k) {
        this._data = this._data.filter(function (p) { return p[0] !== k; });
      };
      URLSearchParams.prototype.toString = function () {
        return this._data.map(function (p) {
          return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]);
        }).join('&');
      };
      URLSearchParams.prototype.forEach = function (fn) {
        this._data.forEach(function (p) { fn(p[1], p[0], this); }, this);
      };
      g.URLSearchParams = URLSearchParams;

      function URL(url, base) {
        var full = url;
        if (base && !/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(url)) {
          full = String(base).replace(/\/+$/, '') + '/' + String(url).replace(/^\/+/, '');
        }
        var m = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^\/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/.exec(full);
        if (!m) throw new Error('Invalid URL: ' + full);
        this.protocol = m[1] + ':';
        this.host = m[2];
        this.hostname = m[2].split(':')[0];
        this.port = m[2].indexOf(':') >= 0 ? m[2].split(':')[1] : '';
        this.pathname = m[3] || '/';
        this.search = m[4] || '';
        this.hash = m[5] || '';
        this.origin = this.protocol + '//' + this.host;
        this.searchParams = new URLSearchParams(this.search);
        this.href = full;
      }
      URL.prototype.toString = function () { return this.href; };
      URL.prototype.toJSON = function () { return this.href; };
      g.URL = URL;

      // ============ 加解密（crypto-js 兼容） ============
      function hexDigest(hex) {
        return {
          toString: function (enc) {
            if (enc === CryptoJS.enc.Base64) {
              var s = '';
              for (var i = 0; i < hex.length; i += 2) s += String.fromCharCode(parseInt(hex.substr(i, 2), 16));
              return __dd_crypto('b64e', s, '');
            }
            return hex;
          }
        };
      }
      var CryptoJS = {
        enc: {
          Hex: { name: 'Hex' },
          Base64: { name: 'Base64' },
          Utf8: { name: 'Utf8' }
        },
        MD5: function (s) { return hexDigest(__dd_crypto('md5', toStr(s), '')); },
        SHA1: function (s) { return hexDigest(__dd_crypto('sha1', toStr(s), '')); },
        SHA256: function (s) { return hexDigest(__dd_crypto('sha256', toStr(s), '')); },
        HmacSHA256: function (msg, key) { return hexDigest(__dd_crypto('hmac256', toStr(msg), toStr(key))); },
        HmacSHA1: function (msg, key) {
          // 退化为 sha1(key + msg)，够用但不严格，脚本若强依赖请自行实现
          return hexDigest(__dd_crypto('sha1', toStr(key) + toStr(msg), ''));
        },
        lib: { WordArray: { create: function () { return {}; } } }
      };
      CryptoJS.enc.Hex.stringify = function () { return ''; };
      CryptoJS.enc.Base64.stringify = function (wa) { return wa && wa.toString ? wa.toString() : ''; };
      CryptoJS.enc.Utf8.stringify = function (wa) { return wa && wa.toString ? wa.toString() : String(wa); };
      CryptoJS.enc.Utf8.parse = function (s) { return { toString: function () { return s; } }; };
      function toStr(v) {
        if (v === null || v === undefined) return '';
        if (typeof v === 'string') return v;
        if (v && typeof v.toString === 'function') {
          var s = v.toString();
          if (s === '[object Object]') {
            try { return JSON.stringify(v); } catch (e) { return s; }
          }
          return s;
        }
        return String(v);
      }
      g.CryptoJS = CryptoJS;

      // ============ HTTP ============
      function buildHeaders(config) {
        var h = {};
        var common = (axios.defaults && axios.defaults.headers && axios.defaults.headers.common) || {};
        for (var k in common) h[k] = common[k];
        var cfgH = (config && config.headers) || {};
        for (var k2 in cfgH) h[k2] = cfgH[k2];
        return h;
      }
      function encodeParams(params) {
        if (!params) return '';
        if (typeof params === 'string') return params;
        var sp = new URLSearchParams(params);
        return sp.toString();
      }
      function request(method, url, data, config) {
        config = config || {};
        var headers = buildHeaders(config);
        var finalUrl = String(url);
        var payload = null;

        var ct = headers['Content-Type'] || headers['content-type'] || '';
        if (method === 'GET' || method === 'DELETE') {
          if (config.params) {
            var qs = encodeParams(config.params);
            if (qs) finalUrl += (finalUrl.indexOf('?') >= 0 ? '&' : '?') + qs;
          }
        } else {
          if (data !== undefined && data !== null) {
            if (typeof data === 'string') {
              payload = data;
            } else if (data instanceof URLSearchParams) {
              payload = data.toString();
              if (!ct) headers['Content-Type'] = 'application/x-www-form-urlencoded';
            } else if (config.form || ct.indexOf('x-www-form-urlencoded') >= 0) {
              payload = new URLSearchParams(data).toString();
              if (!ct) headers['Content-Type'] = 'application/x-www-form-urlencoded';
            } else {
              payload = JSON.stringify(data);
              if (!ct) headers['Content-Type'] = 'application/json';
            }
          }
        }

        var timeoutMs = config.timeout || (axios.defaults && axios.defaults.timeout) || 30000;
        var raw = __dd_request(JSON.stringify({
          method: method,
          url: finalUrl,
          headers: headers,
          body: payload,
          timeout: timeoutMs
        }));

        var res;
        try { res = JSON.parse(raw); } catch (e) { res = { status: 0, data: raw, headers: {} }; }
        var text = res.data === undefined ? '' : res.data;
        var ctResp = '';
        for (var hk in (res.headers || {})) {
          if (hk.toLowerCase() === 'content-type') ctResp = res.headers[hk];
        }
        var parsed = text;
        if (ctResp.indexOf('json') >= 0 || (text && /^[\s]*[\[{]/.test(text) && config.forceJsonParse !== false)) {
          try { parsed = JSON.parse(text); } catch (e2) { parsed = text; }
        }
        var out = {
          status: res.status,
          statusCode: res.status,
          statusText: res.statusText || '',
          headers: res.headers || {},
          data: parsed,
          config: { url: finalUrl, method: method },
          request: { url: finalUrl, method: method }
        };
        if (config.rawText) out.data = text;
        return out;
      }

      var responseInterceptors = [];
      function wrapCheck(res, config) {
        var validate = (config && config.validateStatus) ||
          (axios.defaults && axios.defaults.validateStatus) ||
          function (s) { return s >= 200 && s < 300; };
        for (var i = 0; i < responseInterceptors.length; i++) {
          try { res = responseInterceptors[i].onFulfilled ? responseInterceptors[i].onFulfilled(res) : res; } catch (e) {}
        }
        if (!validate(res.status)) {
          var err = new Error('Request failed with status code ' + res.status);
          err.response = res;
          err.isAxiosError = true;
          err.config = res.config;
          throw err;
        }
        return res;
      }

      var axios = {
        defaults: { headers: { common: {} }, timeout: 30000, validateStatus: null },
        create: function (cfg) {
          cfg = cfg || {};
          var inst = {
            defaults: {
              headers: { common: {} },
              baseURL: cfg.baseURL || '',
              timeout: cfg.timeout || 30000
            }
          };
          if (cfg.headers && cfg.headers.common) {
            for (var k in cfg.headers.common) inst.defaults.headers.common[k] = cfg.headers.common[k];
          }
          var methods = ['get', 'post', 'put', 'delete', 'patch', 'head', 'options'];
          methods.forEach(function (m) {
            inst[m] = function (url, a, b) {
              var data = null, config = {};
              if (m === 'get' || m === 'delete' || m === 'head' || m === 'options') {
                config = a || {};
              } else {
                data = a; config = b || {};
              }
              config = config || {};
              var merged = { headers: {}, params: config.params, timeout: config.timeout || inst.defaults.timeout, validateStatus: config.validateStatus };
              var common = inst.defaults.headers.common;
              for (var kk in common) merged.headers[kk] = common[kk];
              for (var kk2 in (config.headers || {})) merged.headers[kk2] = config.headers[kk2];
              var full = url;
              if (inst.defaults.baseURL && !/^https?:\/\//i.test(url)) {
                full = String(inst.defaults.baseURL).replace(/\/+$/, '') + '/' + String(url).replace(/^\/+/, '');
              }
              var r = request(m.toUpperCase(), full, data, merged);
              return wrapCheck(r, merged);
            };
          });
          inst.request = function (cfg) {
            var m = (cfg.method || 'GET').toUpperCase();
            var full = cfg.url;
            if (inst.defaults.baseURL && !/^https?:\/\//i.test(cfg.url)) {
              full = String(inst.defaults.baseURL).replace(/\/+$/, '') + '/' + String(cfg.url).replace(/^\/+/, '');
            }
            var merged = { headers: {}, params: cfg.params, timeout: cfg.timeout || inst.defaults.timeout, validateStatus: cfg.validateStatus };
            var common = inst.defaults.headers.common;
            for (var kk in common) merged.headers[kk] = common[kk];
            for (var kk2 in (cfg.headers || {})) merged.headers[kk2] = cfg.headers[kk2];
            var r = request(m, full, cfg.data, merged);
            return wrapCheck(r, merged);
          };
          inst.interceptors = axios.interceptors;
          return inst;
        },
        interceptors: {
          request: { use: function () {} },
          response: {
            use: function (onFulfilled) { if (onFulfilled) responseInterceptors.push({ onFulfilled: onFulfilled }); }
          }
        },
        isAxiosError: function (e) { return !!(e && e.isAxiosError); }
      };

      // GET 等在 axios 里是 promise；这里用 async 包一层，保证 await / .then 都可用
      // 同时统一走 wrapCheck，保证非 2xx 会抛错（和 axios 行为一致）
      ['get', 'delete', 'head', 'options'].forEach(function (m) {
        axios[m] = async function (url, config) {
          config = config || {};
          return wrapCheck(request(m.toUpperCase(), url, null, config), config);
        };
      });
      ['post', 'put', 'patch'].forEach(function (m) {
        axios[m] = async function (url, data, config) {
          config = config || {};
          return wrapCheck(request(m.toUpperCase(), url, data, config), config);
        };
      });
      axios.request = async function (cfg) {
        cfg = cfg || {};
        return wrapCheck(request((cfg.method || 'GET').toUpperCase(), cfg.url, cfg.data, cfg), cfg);
      };
      g.axios = axios;

      g.fetch = async function (url, options) {
        options = options || {};
        var r = request((options.method || 'GET').toUpperCase(), url, options.body, {
          headers: options.headers || {},
          timeout: options.timeout
        });
        return {
          ok: r.status >= 200 && r.status < 300,
          status: r.status,
          statusText: r.statusText,
          headers: r.headers,
          url: r.config.url,
          text: async function () { return typeof r.data === 'string' ? r.data : JSON.stringify(r.data); },
          json: async function () { return typeof r.data === 'string' ? JSON.parse(r.data) : r.data; }
        };
      };

      // ============ 文件系统（沙箱内） ============
      var fs = {
        readFileSync: function (p, enc) { return __dd_fs('read', String(p), ''); },
        writeFileSync: function (p, data, enc) { __dd_fs('write', String(p), String(data)); },
        appendFileSync: function (p, data) { __dd_fs('append', String(p), String(data)); },
        existsSync: function (p) { return __dd_fs('exists', String(p), '') === '1'; },
        mkdirSync: function (p) { __dd_fs('mkdir', String(p), ''); },
        readdirSync: function (p) { try { return JSON.parse(__dd_fs('list', String(p), '') || '[]'); } catch (e) { return []; } },
        unlinkSync: function (p) { __dd_fs('remove', String(p), ''); },
        statSync: function (p) {
          try { return JSON.parse(__dd_fs('stat', String(p), '') || '{}'); } catch (e) { return {}; }
        },
        rmSync: function (p) { __dd_fs('remove', String(p), ''); }
      };
      fs.readFile = function (p, cb) { try { cb(null, fs.readFileSync(p)); } catch (e) { cb(e); } };
      fs.promises = {
        readFile: async function (p) { return fs.readFileSync(p); },
        writeFile: async function (p, d) { fs.writeFileSync(p, d); }
      };

      var path = {
        join: function () {
          var parts = Array.prototype.slice.call(arguments).filter(function (x) { return x !== '' && x !== undefined && x !== null; });
          return parts.join('/').replace(/\/+/g, '/');
        },
        resolve: function () {
          var parts = Array.prototype.slice.call(arguments);
          var p = parts.join('/').replace(/\/+/g, '/');
          return p;
        },
        basename: function (p) { return String(p).split('/').pop(); },
        dirname: function (p) { var a = String(p).split('/'); a.pop(); return a.join('/') || '.'; },
        extname: function (p) { var b = String(p).split('/').pop(); var i = b.lastIndexOf('.'); return i < 0 ? '' : b.slice(i); },
        sep: '/'
      };

      // ============ 模块加载 ============
      var moduleCache = {};
      function require(name) {
        if (moduleCache[name]) return moduleCache[name];
        var mod;
        switch (name) {
          case 'axios': mod = axios; break;
          case 'request':
          case 'request-promise':
          case 'got':
          case 'node-fetch':
          case 'superagent':
            mod = Object.assign({}, axios);
            mod.default = axios;
            break;
          case 'crypto-js':
          case 'crypto':
            mod = Object.assign({}, CryptoJS, { createHash: undefined });
            break;
          case 'fs': mod = fs; break;
          case 'path': mod = path; break;
          case 'querystring':
          case 'url':
            mod = { stringify: function (o) { return new URLSearchParams(o).toString(); },
                    parse: function (s) { var sp = new URLSearchParams(s); var o = {}; sp.forEach(function (v, k) { o[k] = v; }); return o; } };
            break;
          case 'os':
            mod = { platform: function () { return 'ios'; }, arch: function () { return 'arm64'; }, hostname: function () { return 'daidai-panel'; },
                    cpus: function () { return []; }, totalmem: function () { return 0; }, freemem: function () { return 0; } };
            break;
          case 'util': mod = { inspect: fmt, format: fmt, promisify: function (f) { return f; } }; break;
          case 'moment': mod = undefined; break;
          case 'child_process':
            throw new Error('daidai-panel 运行在 iOS 沙箱内，不支持 child_process');
          default:
            if (name.charAt(0) === '.' || name.charAt(0) === '/') {
              var code = __dd_fs('read', name, '');
              if (!code) throw new Error('找不到本地模块: ' + name);
              var fn = new Function('module', 'exports', 'require', code);
              var m = { exports: {} };
              fn(m, m.exports, require);
              moduleCache[name] = m.exports;
              return m.exports;
            }
            throw new Error('不支持的模块: "' + name + '"。daidai-panel 内置: axios, crypto-js, fs, path, os, util, querystring, url');
        }
        moduleCache[name] = mod;
        return mod;
      }
      g.require = require;

      // ============ process ============
      var envObj = JSON.parse(__dd_env() || '{}');
      var process = {
        platform: 'ios',
        arch: 'arm64',
        version: 'v18.0.0-daidai',
        versions: { node: '18.0.0-daidai' },
        argv: ['daidai-panel', g.__dd_script_name || 'script.js'],
        env: envObj,
        cwd: function () { return '/daidai-panel'; },
        exit: function (code) {
          g.__dd_exit_code = code || 0;
          var e = { __ddExit: true, code: code || 0, message: 'process.exit(' + (code || 0) + ')' };
          throw e;
        },
        nextTick: function (fn) { fn(); },
        on: function () {}, exitCode: 0
      };
      g.process = process;

      // ============ 青龙兼容 $ ============
      var doneCalled = false;
      var $ = {
        name: g.__dd_script_name || 'script.js',
        fileName: g.__dd_script_name || 'script.js',
        cwd: '/daidai-panel',
        isNode: false,
        platform: 'ios',
        http: axios,
        axios: axios,
        log: console.log,
        info: function (m) { console.log(m); },
        error: console.error,
        sleep: g.sleep,
        require: require,
        notify: function (a, b) {
          if (b === undefined) { return __dd_notify('daidai-panel', String(a)); }
          return __dd_notify(String(a), String(b));
        },
        sendNotify: function (title, content) { return __dd_notify(String(title), String(content)); },
        done: function (err) {
          doneCalled = true;
          if (err) {
            g.__dd_done_error = String(err && err.stack ? err.stack : err);
            console.error('$.done 收到错误: ' + g.__dd_done_error);
          }
        },
        get: function (url, config) { return axios.get(url, config); },
        post: function (url, data, config) { return axios.post(url, data, config); },
        put: function (url, data, config) { return axios.put(url, data, config); },
        delete: function (url, config) { return axios.delete(url, config); },
        randomString: function (len) {
          len = len || 16;
          var s = '';
          var chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
          for (var i = 0; i < len; i++) s += chars.charAt(Math.floor(Math.random() * chars.length));
          return s;
        }
      };
      Object.defineProperty($, 'env', {
        get: function () { return process.env; },
        enumerable: true,
        configurable: true
      });
      g.$ = $;
      g.__dd_done_called = function () { return doneCalled; };
    })();
    """#
}
