import AppKit
import MemBarCore

// Internal helper modes run before AppKit is brought up, so they cost almost nothing.
setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--balloon"),
   index + 1 < arguments.count,
   let megabytes = Int(arguments[index + 1]) {
    exit(Balloon.run(megabytes: megabytes))
}

if let index = arguments.firstIndex(of: "--clean") {
    var megabytes = Prefs.balloonMB
    if index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
        megabytes = value
    }
    print(Diagnostics.cleanReport(balloonMB: megabytes))
    exit(0)
}

if arguments.contains("--diagnostics") {
    Diagnostics.printReport()
    exit(0)
}

if arguments.contains("--selftest") {
    print("[selftest] starting")
    let testApplication = NSApplication.shared
    testApplication.setActivationPolicy(.accessory)
    let testController: StatusItemController = MainActor.assumeIsolated { StatusItemController() }
    // A timer (not a dispatch block) starts the test: main-queue completions cannot be drained
    // while a dispatch block is still on the stack.
    let kickoff = Timer(timeInterval: 0.3, repeats: false) { timer in
        print("[selftest] timer fired")
        MainActor.assumeIsolated {
            testController.start()
            testController.runSelfTest()
        }
    }
    RunLoop.main.add(kickoff, forMode: .common)
    testApplication.run()
    exit(0)
}

let application = NSApplication.shared
let delegate: AppDelegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()