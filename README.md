# 代代面板 · iOS 版（daidai-panel）

把青龙面板的「跑 JS / PY 脚本」这件事，搬进一台 iPhone。
**不需要 Linux，不需要 Docker，不需要服务器** —— 一个 IPA 装上去就能跑。

- JS 引擎：系统自带 **JavaScriptCore**（零依赖）
- Python 引擎：嵌入官方 **CPython 3.12**（BeeWare Python-Apple-support 预编译 xcframework）
- 管理方式：机身本地的 Web 面板（`http://127.0.0.1:5700`）+ 原生 App 界面
- 后台存活：音频保活 + BGTask + 定位保活（多手段叠加）
- 编译方式：GitHub Actions 在线编译，产出**免签名 IPA**

---

## 1. 先说清楚 iOS 的现实

在动手之前，你需要知道这几件事，否则预期会错位：

| 事情 | 现实 |
| --- | --- |
| 「装上去就 24 小时常驻后台」 | iOS **不允许**普通 App 无限后台。本项目用「循环播放静音音频」拿到后台音频权限，这是非越狱环境下效果最好的手段，实测可长期存活；但**不要手动上划杀掉 App**，杀掉了要重新打开一次。 |
| 免签名 IPA 怎么装 | iOS 系统本身不校验「IPA 是否签名」这一步，但安装工具会。三条路：<br>① **TrollStore**（最省事，不重签、永久有效，要求 iOS 14.0–17.0 且设备支持）；<br>② **AltStore / Sideloadly + Apple ID**（免费账号 7 天要重签一次）；<br>③ 付费开发者账号签名（1 年）。 |
| 能不能上架 App Store | 不能。静音保活、任意网络访问都不符合审核规则。这是自用工具。 |
| 复杂 Node 生态 | JS 跑在 JavaScriptCore 上，**不是 Node**。已内置 `axios`、`crypto-js`、`fs`、`path`、`os`、`require` 等 shim，覆盖青龙脚本的常见用法；但 npm 里的原生模块（如 `sharp`、`puppeteer`）用不了。 |
| 复杂 Python 生态 | Python 只能跑**纯 Python 包**。已内置 `requests / urllib3 / certifi / idna / charset_normalizer`。带 C 扩展的包（如 `numpy`、`lxml`）需要交叉编译，本项目不提供。 |

---

## 2. 编译（GitHub Actions，全程在线）

### 2.1 准备

你只需要一个 GitHub 账号，**不需要 Mac，不需要付费**。

1. 在 GitHub 上新建一个**空仓库**（比如 `daidai-panel-ios`），不要勾选 README / .gitignore。
2. 把本目录推到该仓库：

```bash
cd daidai-panel-ios
git init
git add .
git commit -m "feat: daidai-panel iOS 初版"
git branch -M main
git remote add origin https://github.com/<你的用户名>/daidai-panel-ios.git
git push -u origin main
```

3. 推送完成后，GitHub 会自动开始跑 `.github/workflows/build-ipa.yml`。
   也可以手动触发：仓库页 → **Actions** → 左侧 **Build unsigned IPA** → **Run workflow**。

### 2.2 拿产物

构建大约 5–10 分钟。跑完：

**Actions → 那次运行 → 底部 Artifacts → `daidai-panel-unsigned-ipa`**

下载、解压，得到 `daidai-panel-1.0.0-unsigned.ipa`。

### 2.3 本地构建（如果你有 Mac）

```bash
brew install xcodegen
./Scripts/fetch_python.sh              # 下载 Python.xcframework（约 33MB）
./Scripts/vendor_python_packages.sh    # 可选：拉纯 Python 包
xcodegen generate
xcodebuild -project daidai-panel.xcodeproj -scheme daidai-panel \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  ARCHS=arm64 build
./Scripts/make_ipa.sh
```

---

## 3. 安装到手机

### 方式 A：TrollStore（推荐）

1. 手机装好 TrollStore（见 TrollStore 官方文档，需 iOS 14.0–17.0）。
2. 把 `.ipa` 传到手机（AirDrop / iCloud / 文件 App）。
3. 用 TrollStore 打开该 IPA → **Install**。

TrollStore 会用 fakesign 给整个 App 打上伪签名，App 内的 `Frameworks/` 会被正确加载。

### 方式 B：AltStore / Sideloadly

把 IPA 拖进工具里，用 Apple ID 签名安装。免费账号 **7 天过期**，到期重新签一次即可（脚本和数据都在 App 沙箱里，重签不会丢）。

### 首次打开

1. 允许「后台 App 刷新」（设置 → 通用 → 后台 App 刷新 → 代代面板）。
2. 如果开了定位保活，同意「始终允许」定位。
3. 保持 App 在前台几秒，让音频保活起来，然后切后台即可。

---

## 4. 怎么用

### 4.1 手机上的原生界面

四个页签：

- **概览** —— 面板状态、后台心跳、守护进程一键启停、最近日志
- **脚本** —— 增删改查、运行、启用/停用、切换常驻
- **日志** —— 每次执行的完整输出，可复制
- **设置** —— 面板端口、Bark 推送、保活开关、环境变量、数据目录

### 4.2 浏览器面板

手机 Safari 打开 `http://127.0.0.1:5700`。

在设置里打开「允许局域网访问」后，同一 Wi-Fi 下的电脑也能访问
`http://<手机IP>:5700` —— 这样在电脑上写脚本、手机上跑，很舒服。

### 4.3 用「文件」App 传脚本

App 开了文件共享。在 **文件 → 我的 iPhone → 代代面板 → daidai-panel → scripts** 里
直接拖入 `.js` / `.py`，然后在「脚本」页点左上角的「导入」即可。

---

## 5. 脚本怎么写

### 5.1 JavaScript（青龙风格）

```js
(async () => {
  console.log('开始执行');

  // 1) axios（已内置，支持 await / .then / interceptors / create）
  const res = await axios.get('https://httpbin.org/get', {
    headers: { 'User-Agent': 'daidai' },
    timeout: 10000,
    params: { a: 1 }
  });
  console.log('status =', res.status, res.data);

  // 2) 环境变量（在「设置 → 环境变量」里加，或面板环境变量页加）
  const ck = $.env.TAOBAO_CK || process.env.TAOBAO_CK;
  console.log('ck 长度 =', ck ? ck.length : 0);

  // 3) 加密（crypto-js 兼容）
  const CryptoJS = require('crypto-js');
  console.log(CryptoJS.MD5('abc').toString());          // 900150983cd24fb0d6963f7d28e17f72
  console.log(CryptoJS.SHA256('abc').toString());

  // 4) 文件（沙箱内，相对路径基于 scripts 目录）
  const fs = require('fs');
  fs.writeFileSync('result.json', JSON.stringify(res.data));

  // 5) 暂停
  await sleep(1000);
  // 也支持 await new Promise(r => setTimeout(r, 1000))

  // 6) 推送
  await $.notify('签到完成', '金币 +10');

  // 7) 结束（可选，异步脚本建议保留）
  $.done();
})().catch(e => {
  console.error(e && e.stack ? e.stack : e);
  $.done(e);   // 传入 error 会被判定为失败
});
```

**内置能力**

| 名称 | 说明 |
| --- | --- |
| `axios` / `$.http` | 同步底层 + async 包装，GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS、`create()`、`interceptors.response.use()` |
| `$.get/post/put/delete` | `axios` 的简写 |
| `$.notify(title, body)` / `$.sendNotify` | Bark 推送 |
| `$.env` / `process.env` | 环境变量 |
| `$.log` / `console.*` | 写日志（带时间戳） |
| `$.done(err)` | 标记结束；传 err 记为失败 |
| `$.sleep(ms)` / `sleep(ms)` | 异步等待 |
| `require('crypto-js')` | `MD5 / SHA1 / SHA256 / HmacSHA256`、`enc.Hex/Base64/Utf8` |
| `require('fs')` | `readFileSync / writeFileSync / appendFileSync / existsSync / readdirSync / statSync / unlinkSync / mkdirSync` |
| `require('path')` | `join / resolve / basename / dirname / extname / sep` |
| `require('os')` | `platform() → 'ios'`、`arch() → 'arm64'` |
| `require('request'/'got')` | 映射到 axios 兼容层 |
| `fetch` | async，返回 `{ ok, status, text(), json() }` |
| `Buffer` / `atob` / `btoa` / `TextEncoder` / `TextDecoder` / `URLSearchParams` / `URL` | 基础实现 |

> **注意**：`setTimeout` 是「同步等待后立即执行」的实现，
> 所以 `await sleep(1000)`、`await new Promise(r => setTimeout(r, 1000))` 都正常，
> 但 `setTimeout` 不会在脚本返回后才触发（不会异步跳出来）。
> `setInterval` 由运行线程驱动，可用于常驻脚本。

### 5.2 Python

```python
#!/usr/bin/env python3
import os
import json
import requests

def main():
    ck = os.environ.get("TAOBAO_CK", "")
    print("ck 长度 =", len(ck))

    r = requests.get("https://httpbin.org/get", timeout=10)
    print("status =", r.status_code)
    print(json.dumps(r.json(), ensure_ascii=False))

    with open("result.json", "w", encoding="utf-8") as f:
        f.write(r.text)

    # 可选：走宿主桥接发 Bark
    import daidai_bridge
    daidai_bridge.call("bark", "任务完成", "Python 脚本执行成功")

if __name__ == "__main__":
    main()
```

**内置**：完整标准库 + `requests / urllib3 / certifi / idna / charset_normalizer`

**多线程**：Python 脚本可以并发跑（GIL 由运行时正确配对），
但 `sys.stdout` 的输出会按线程归属正确分流。

---

## 6. 常驻守护（24 小时跑的核心）

在脚本编辑页把「运行方式」改成**常驻守护**，然后启用：

- App 启动时自动拉起（设置里「启动时自动运行常驻脚本」）
- 脚本异常退出 → 按退避策略自动重启（5s → 10s → 20s … 最多 5 分钟）
- 面板 / 原生界面都能看到守护状态

常驻脚本的两种写法：

```js
// 写法一：自己死循环（推荐）
(async () => {
  while (true) {
    try {
      await doSomething();
    } catch (e) {
      console.error(e);
    }
    await sleep(60000);
  }
})();
```

```js
// 写法二：用 setInterval，脚本主体直接返回
setInterval(() => { doSomething(); }, 60000);
```

---

## 7. 保活原理

App 启动后会同时开启：

1. **音频保活**（主力）
   `AVAudioSession` 设为 `.playback` + `.mixWithOthers`，
   用 `AVAudioPlayer` 无限循环播放 `Resources/silence.wav`（真静音文件，不发声，
   也不会打断你正在听的音乐）。系统据此认为 App 在放音频，从而持续给它后台时间。
   电话打断 / 音频路由变化 / 媒体服务重启都做了自动恢复。
2. **BGTaskScheduler**（补充）
   注册 `com.daidai.panel.refresh` 和 `com.daidai.panel.processing`，
   每 15 / 30 分钟申请一次系统唤醒，醒来后自检并补拉守护进程。
3. **beginBackgroundTask 续期**（补充）
   在系统给的收尾时间里反复续命。
4. **定位保活**（可选）
   设置里打开后，用低精度持续定位换取更强的后台权限。会弹定位权限、略费电。

此外有一个 30 秒心跳：音频被掐会自动重放，调度器/守护挂了会自动补起。

---

## 8. 目录结构

```
daidai-panel-ios/
├─ .github/workflows/build-ipa.yml   GitHub Actions 在线编译
├─ project.yml                       XcodeGen 工程描述
├─ Scripts/
│   ├─ fetch_python.sh               下载 Python.xcframework
│   ├─ install_python.sh             构建后：装标准库 + .so→framework 转换
│   ├─ vendor_python_packages.sh     拉纯 Python 包
│   ├─ make_ipa.sh                   打包免签名 IPA
│   └─ make_silence.py               生成静音音频
├─ Resources/
│   ├─ Info.plist
│   ├─ silence.wav
│   └─ web/                          内置面板前端（原生 JS）
└─ Sources/
    ├─ App/          SwiftUI 界面 + AppDelegate
    ├─ Core/         模型 / 存储 / cron / 调度器 / 日志 / Bark
    ├─ Runtime/      JS 引擎、Python 引擎、HTTP、加密、文件桥
    ├─ Server/       轻量 HTTP 服务 + REST API + 静态资源
    ├─ KeepAlive/    后台保活
    ├─ Views/        各页签界面
    └─ Bridge/       只暴露自定义 C 接口的 Bridging Header
```

---

## 9. 面板 API（方便你自己接自动化）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/status` | 运行状态 |
| GET/POST | `/api/scripts` | 列出 / 新建脚本 |
| GET/POST/DELETE | `/api/scripts/{id}` | 读取 / 更新 / 删除 |
| POST | `/api/scripts/{id}/run` | 立即执行 |
| POST | `/api/scripts/{id}/toggle` | 启用 / 停用 |
| POST | `/api/scripts/{id}/daemon` | `{"start":true/false}` 启停守护 |
| GET/DELETE | `/api/logs` `/api/logs/{id}` | 日志列表 / 正文 |
| GET/POST/DELETE | `/api/env` | 环境变量 |
| GET/POST/DELETE | `/api/tasks` | 定时任务 |
| GET/POST | `/api/settings` | 读写设置 |
| POST | `/api/notify` | 测试 Bark |
| POST | `/api/import` | 重新扫描脚本目录 |
| POST | `/api/daemons/startAll` `/stopAll` | 守护批量启停 |

设了 token 后，请求需要带 `?token=xxx` 或 `Authorization: Bearer xxx`。

---

## 10. 已知限制

- iOS 无 `fork/exec`，所以脚本里**不能** `child_process` / `subprocess`。
- 任务脚本超时后**不会真正被中断**（JS 和 CPython 都无法从外部安全打断），
  只会标记超时；线程会在自己跑完后回收，期间该脚本不会重复触发。
  常驻脚本不设超时。
- Python 是**全局单解释器**：`os.environ` 是全局的，同名变量以后写入的为准。
- 只支持纯 Python 包；带 C 扩展的包需要自己交叉编译 wheel。
- 后台存活率受 iOS 版本、机型、系统内存压力影响。真要在生产环境 7×24 跑，
  建议同时保留一台便宜 VPS 做兜底。
