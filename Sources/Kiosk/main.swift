import AppKit

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "--watchdog" {
    runWatchdog(leaseURL: URL(fileURLWithPath: arguments[2]), token: arguments[3])
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
