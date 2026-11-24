import AppKit
import MemBarCore

enum SingleInstance {
    /// A second copy of a menu-bar agent is confusing (two icons, two samplers); activate the
    /// running one and exit.
    static func exitIfAlreadyRunning() {
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID == AppInfo.bundleID else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let other = running.first(where: { $0.processIdentifier != getpid() }) else { return }
        Log.info("second instance detected (pid \(other.processIdentifier)); exiting")
        other.activate()
        exit(0)
    }
}