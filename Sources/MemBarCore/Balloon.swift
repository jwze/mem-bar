import Darwin
import Foundation

/// A throw-away process that allocates a large anonymous region, touches every page so the
/// kernel must reclaim/compress something else, then releases it and exits.
///
/// Running it as a child keeps the resident footprint of the menu-bar app flat: the balloon's
/// peak lives in a process that exists for a few hundred milliseconds.
public enum Balloon {
    /// Chunk size used to walk the mapping; between chunks we yield the CPU so the kernel can
    /// react (compressor / page-out) instead of us just hammering it.
    public static let segmentBytes = 8 * 1024 * 1024
    public static let segmentPauseMicroseconds: UInt32 = 20_000

    /// Entry point of the helper process (`MemBar --balloon <MB>`). Returns the exit code.
    public static func run(megabytes: Int) -> Int32 {
        let requested = max(0, megabytes)
        guard requested > 0 else { return 0 }

        let length = Int(requested) * 1024 * 1024
        let pointer = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard pointer != nil, pointer != UnsafeMutableRawPointer(bitPattern: -1) else {
            return 2
        }
        defer { munmap(pointer, length) }

        var offset = 0
        while offset < length {
            let chunk = min(segmentBytes, length - offset)
            memset(pointer!.advanced(by: offset), 0x5a, chunk)
            offset += chunk
            if offset < length { usleep(segmentPauseMicroseconds) }
        }
        return 0
    }
}