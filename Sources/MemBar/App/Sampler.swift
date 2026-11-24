import AppKit
import MemBarCore

@MainActor
final class Sampler {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue.main
    private(set) var interval: TimeInterval

    var onSample: ((MemorySnapshot) -> Void)?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func start() {
        restart()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    func setInterval(_ newValue: TimeInterval) {
        guard newValue > 0, newValue != interval else { return }
        interval = newValue
        restart()
    }

    /// One coalesced timer on the main queue; 1 s leeway keeps idle wake-ups negligible.
    private func restart() {
        stop()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(1000)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.onSample?(MemoryStats.sample())
        }
        source.resume()
        timer = source
    }
}