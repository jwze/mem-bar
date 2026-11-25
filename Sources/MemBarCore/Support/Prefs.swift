import Foundation

/// User-tunable knobs. Everything lives in `UserDefaults` under `mb.*` keys; no stats are stored.
public enum Prefs {
    public static let refreshOptions = [2, 5, 10]

    public static let defaultRefreshSeconds = 5
    public static let defaultBalloonMB = 64

    private static let refreshKey = "mb.refreshSeconds"
    private static let loginItemAskedKey = "mb.loginItemAsked"

    public static var refreshSeconds: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: refreshKey)
            return refreshOptions.contains(stored) ? stored : defaultRefreshSeconds
        }
        set {
            UserDefaults.standard.set(clamp(newValue, to: refreshOptions), forKey: refreshKey)
        }
    }

    public static var refreshInterval: TimeInterval { TimeInterval(refreshSeconds) }

    /// The balloon is fixed on purpose: a bigger balloon measured no better net reclaim, so the
    /// old 「回收强度」selector is gone. `--clean <MB>` can still override it for experiments.
    public static var balloonMB: Int { defaultBalloonMB }

    /// Whether the one-time "register login item on first launch" logic has already run.
    public static var loginItemAsked: Bool {
        get { UserDefaults.standard.bool(forKey: loginItemAskedKey) }
        set { UserDefaults.standard.set(newValue, forKey: loginItemAskedKey) }
    }

    private static func clamp(_ value: Int, to options: [Int]) -> Int {
        options.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }
}