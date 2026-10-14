import Foundation
import AVFoundation
import UIKit
import CoreLocation
import BackgroundTasks

/// 后台保活。
///
/// iOS 没有「常驻后台」的官方能力，这里是三个手段叠加：
///   1. 音频后台模式：循环播放一段**静音**音频，让系统认为 App 在放音乐。
///      这是非越狱环境下最稳定、持续时间最长的方式。
///   2. BGTaskScheduler：申请 AppRefresh / Processing 周期性唤醒，作为补充。
///   3. beginBackgroundTask 续期：在系统给的收尾时间里反复续命。
/// 另可选开启定位保活（更稳，但会弹权限、略费电）。
final class KeepAliveManager: NSObject {

    static let shared = KeepAliveManager()

    static let refreshTaskId = "com.daidai.panel.refresh"
    static let processingTaskId = "com.daidai.panel.processing"

    private var player: AVAudioPlayer?
    private var locationManager: CLLocationManager?
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var heartbeat: DispatchSourceTimer?
    private var observersInstalled = false

    private let heartbeatKey = "daidai.lastHeartbeat"
    private let launchKey = "daidai.firstLaunchAt"

    private override init() { super.init() }

    // MARK: - 启动

    func start() {
        if UserDefaults.standard.object(forKey: launchKey) == nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: launchKey)
        }
        refreshState()

        if Store.shared.settings.keepAliveAudio { startAudio() }
        if Store.shared.settings.keepAliveLocation { startLocation() }
        if Store.shared.settings.keepAliveBackgroundTask { beginBackgroundTaskRenewal() }

        installObservers()
        startHeartbeat()
    }

    func stop() {
        player?.stop()
        player = nil
        locationManager?.stopUpdatingLocation()
        locationManager = nil
        heartbeat?.cancel()
        heartbeat = nil
    }

    /// 设置变更后重新应用
    func refreshState() {
        let s = Store.shared.settings
        if s.keepAliveAudio {
            if player?.isPlaying != true { startAudio() }
        } else {
            player?.stop(); player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        if s.keepAliveLocation {
            if locationManager == nil { startLocation() }
        } else {
            locationManager?.stopUpdatingLocation()
            locationManager = nil
        }
    }

    // MARK: - 音频保活

    private func startAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback + .mixWithOthers：不打断用户的音乐，也不会被别的 App 抢走
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("[daidai] 音频会话设置失败: %@", error.localizedDescription)
        }

        if player == nil {
            guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else {
                NSLog("[daidai] 找不到 silence.wav，音频保活不可用")
                return
            }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = -1        // 无限循环
                p.volume = 1.0              // 文件本身是静音，不调音量以免被系统判定为「未播放」
                p.prepareToPlay()
                player = p
            } catch {
                NSLog("[daidai] 静音音频初始化失败: %@", error.localizedDescription)
                return
            }
        }

        player?.play()
        Store.shared.addSystemLog("音频保活已启动")
    }

    // MARK: - 定位保活

    private func startLocation() {
        let lm = CLLocationManager()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        lm.distanceFilter = 500
        lm.pausesLocationUpdatesAutomatically = false
        if #available(iOS 9.0, *) {
            lm.allowsBackgroundLocationUpdates = true
        }
        lm.requestAlwaysAuthorization()
        lm.startUpdatingLocation()
        lm.startMonitoringSignificantLocationChanges()
        locationManager = lm
        Store.shared.addSystemLog("定位保活已启动")
    }

    // MARK: - beginBackgroundTask 续期

    private func beginBackgroundTaskRenewal() {
        endBackgroundTaskRenewal()
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "daidai.keepalive") { [weak self] in
            guard let self = self else { return }
            // 系统准备回收了，立刻再申请一段
            self.endBackgroundTaskRenewal()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard Store.shared.settings.keepAliveBackgroundTask else { return }
                self.beginBackgroundTaskRenewal()
            }
        }
    }

    private func endBackgroundTaskRenewal() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
    }

    // MARK: - 心跳

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.daidai.keepalive"))
        t.schedule(deadline: .now() + 10, repeating: 30, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.beat() }
        t.resume()
        heartbeat = t
    }

    private func beat() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: heartbeatKey)

        // 音频被系统掐了就再拉起来
        if Store.shared.settings.keepAliveAudio, player?.isPlaying != true {
            DispatchQueue.main.async { [weak self] in self?.startAudio() }
        }

        // 调度器没起来就补起来（比如被后台回收后恢复）
        DispatchQueue.main.async {
            if Store.shared.settings.autoStart {
                Scheduler.shared.startDaemonsIfNeeded()
            }
            self.scheduleBackgroundTasks()
        }
    }

    var lastHeartbeat: Date? {
        let t = UserDefaults.standard.double(forKey: heartbeatKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    var firstLaunch: Date? {
        let t = UserDefaults.standard.double(forKey: launchKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    // MARK: - BGTaskScheduler

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: KeepAliveManager.refreshTaskId,
                                        using: nil) { task in
            self.handleAppRefresh(task as! BGAppRefreshTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: KeepAliveManager.processingTaskId,
                                        using: nil) { task in
            self.handleProcessing(task as! BGProcessingTask)
        }
    }

    func scheduleBackgroundTasks() {
        let refresh = BGAppRefreshTaskRequest(identifier: KeepAliveManager.refreshTaskId)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: KeepAliveManager.processingTaskId)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(processing)
    }

    private func handleAppRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundTasks()
        task.expirationHandler = { task.setTaskCompleted(success: false) }

        // 醒来后做一次保活体检
        DispatchQueue.main.async {
            self.refreshState()
            Scheduler.shared.startDaemonsIfNeeded()
            self.beginBackgroundTaskRenewal()
        }
        task.setTaskCompleted(success: true)
    }

    private func handleProcessing(_ task: BGProcessingTask) {
        scheduleBackgroundTasks()
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        DispatchQueue.main.async {
            self.refreshState()
            Scheduler.shared.startDaemonsIfNeeded()
        }
        task.setTaskCompleted(success: true)
    }

    // MARK: - 通知监听

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true

        let c = NotificationCenter.default
        c.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let userInfo = note.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            if type == .ended {
                self?.startAudio()
            }
        }
        c.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.startAudio()
        }
        c.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.player = nil
            self?.startAudio()
        }
    }

    // MARK: - 生命周期

    func didEnterBackground() {
        refreshState()
        scheduleBackgroundTasks()
        Store.shared.saveAllNow()
    }

    func willEnterForeground() {
        refreshState()
        Scheduler.shared.startDaemonsIfNeeded()
    }
}

extension KeepAliveManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 不需要坐标，只借定位这个后台模式续命
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[daidai] 定位保活报错: %@", error.localizedDescription)
    }
}
