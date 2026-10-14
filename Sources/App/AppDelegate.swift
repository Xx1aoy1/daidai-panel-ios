import UIKit
import AVFoundation

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        // 脚本里用相对路径时，基准目录就是数据目录
        FileManager.default.changeCurrentDirectoryPath(Paths.root.path)

        // BGTask 必须在 didFinishLaunching 返回前注册
        KeepAliveManager.shared.registerBackgroundTasks()
        KeepAliveManager.shared.start()

        PanelServer.shared.start()
        Scheduler.shared.start()
        Scheduler.shared.startDaemonsIfNeeded()
        KeepAliveManager.shared.scheduleBackgroundTasks()

        LogStore.shared.purge(keepDays: Store.shared.settings.logKeepDays)
        Store.shared.addSystemLog("代代面板已启动")
        Store.shared.saveAllNow()

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        KeepAliveManager.shared.didEnterBackground()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        KeepAliveManager.shared.willEnterForeground()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        KeepAliveManager.shared.refreshState()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Scheduler.shared.stop()
        Store.shared.saveAllNow()
    }
}
