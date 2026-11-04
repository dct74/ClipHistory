import AppKit

// One instance only: two copies would each own a menu bar item with the same
// bundle id, and the system tracks them separately — the visible icon would then
// belong to whichever process was launched first.
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
       .contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
