import AppKit
import MemBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SingleInstance.exitIfAlreadyRunning()
        NSApp.setActivationPolicy(.accessory)

        registerLoginItemOnFirstLaunch()

        let controller = StatusItemController()
        self.controller = controller
        controller.start()

        Log.info(
            "launched pid=\(getpid()) version=\(AppInfo.version)"
                + " bundle=\(Bundle.main.bundlePath) loginItem=\(LoginItem.statusDescription)"
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Menu-bar agents are registered as a login item on the first launch after installation.
    /// Only done from `/Applications`, otherwise `SMAppService` reports `.notFound`.
    private func registerLoginItemOnFirstLaunch() {
        guard !Prefs.loginItemAsked else { return }
        Prefs.loginItemAsked = true

        guard Bundle.main.bundleURL.path.hasPrefix("/Applications") else {
            Log.info("login item skipped: not installed in /Applications (\(Bundle.main.bundlePath))")
            return
        }

        LoginItem.apply(enabled: true)
        Log.info("first launch: login item registered=\(LoginItem.statusDescription)")
    }
}