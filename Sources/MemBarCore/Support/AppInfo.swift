import Foundation

/// Static identity of the product. Values mirror `Scripts/Info.plist`.
public enum AppInfo {
    public static let name = "MemBar"
    public static let bundleID = "com.jvz.membar"
    public static let version = "1.0.0"

    /// Absolute path of the running binary, needed to re-spawn ourselves as the balloon helper.
    public static var executablePath: String {
        if let path = Bundle.main.executablePath {
            return path
        }
        return CommandLine.arguments.first ?? "/Applications/MemBar.app/Contents/MacOS/MemBar"
    }

    public static var logFileURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return base.appendingPathComponent("\(name).log")
    }

    /// Resident set size of this process, used by `--diagnostics` and the README memory budget.
    public enum Process {
        public static var residentBytes: UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(
                MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
                }
            }
            return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        }
    }
}